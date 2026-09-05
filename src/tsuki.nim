## Tsuki coding-agent executable host.

import std/[algorithm, locks, os, osproc, streams, strutils, times]
import std/typedthreads
import tsuki/agent
import he3/agent as agentui
from he3/agent/model import agentError

const tsukiVersion* = "0.1.0"

type HostState = object
  controller: AgentController
  chat: AgentChat
  config: TsukiConfig
  adapters: seq[ProviderAdapter]
  sessionKeys: seq[tuple[providerId: ProviderId, key: string]]
  models: seq[ModelDescriptor]
  modelCacheFile: string
  credentialsFile: string
  discoveryToken: CancellationToken
  modelsLock: Lock
  cacheLock: Lock
  adaptersLock: Lock
  authLock: Lock
  refreshThreads: array[8, Thread[void]]
  refreshActive: array[8, bool]
  refreshAdapter: ProviderAdapter

var activeHost: ptr HostState

proc controllerMain() {.thread.} =
  activeHost[].controller.run()

func capability(value: CapabilityState): SelectorCapability =
  case value
  of capabilityUnknown: selectorUnknown
  of capabilityUnsupported: selectorUnsupported
  of capabilitySupported: selectorSupported

proc configuredModels(config: TsukiConfig): seq[ModelDescriptor] =
  for provider in config.providers:
    for model in provider.models:
      result.add model

proc findProvider(config: TsukiConfig, id: ProviderId): ProviderConfig =
  for provider in config.providers:
    if provider.id == id: return provider

proc findModel(models: openArray[ModelDescriptor], providerId: ProviderId,
    modelId: ModelId): ModelDescriptor =
  for model in models:
    if model.providerId == providerId and model.id == modelId:
      return model

proc findAdapter(adapters: openArray[ProviderAdapter],
    providerId: ProviderId): ProviderAdapter =
  for adapter in adapters:
    if not adapter.isNil and adapter.id == providerId:
      return adapter

proc findAdapterKind(adapters: openArray[ProviderAdapter],
    kind: string): ProviderAdapter =
  for adapter in adapters:
    if not adapter.isNil and adapter.kind == kind: return adapter

proc toolsEnabled(config: TsukiConfig, providerId: ProviderId): bool =
  let provider = config.findProvider(providerId)
  $provider.id != "" and provider.toolsEnabled

type KeyLookup = proc (providerId: ProviderId): string {.gcsafe.}

proc needsKey(provider: ProviderConfig, sessionKey: KeyLookup): bool =
  ## True for key-based providers with neither an environment variable nor
  ## a stored or session key.
  provider.credentialEnv.len > 0 and provider.resolvedCredential.len == 0 and
    sessionKey(provider.id).len == 0

proc selectorEntries(config: TsukiConfig, models: openArray[ModelDescriptor],
    sessionKey: KeyLookup): seq[SelectorEntry] =
  var emitted = 0
  for provider in config.providers:
    if not provider.enabled: continue
    var found = false
    for model in models:
      if model.providerId != provider.id: continue
      if emitted >= 10_000:
        result.add SelectorEntry(providerId: $provider.id,
          providerName: provider.displayName,
          displayName: "Additional models omitted", available: false,
          reason: "The selector reached its 10,000-model bound.")
        return
      found = true
      inc emitted
      result.add SelectorEntry(providerId: $provider.id,
        providerName: provider.displayName, modelId: $model.id,
        displayName: model.displayName,
        imageInput: capability(model.capabilities.imageInput),
        tools: capability(model.capabilities.tools),
        reasoningEfforts: model.reasoningEfforts,
        defaultReasoningEffort: model.defaultReasoningEffort,
        available: model.available, reason: model.unavailableReason)
    if not found:
      let reason = if provider.needsKey(sessionKey):
        "Use /provider to add a key, or set " & provider.credentialEnv & "."
      elif provider.kind == "codex_app_server":
        "Use /provider to sign in, or wait for ChatGPT model discovery."
      else:
        "Wait for model discovery, or configure a model ID."
      result.add SelectorEntry(providerId: $provider.id,
        providerName: provider.displayName, displayName: "Models not loaded",
        imageInput: selectorUnknown, tools: selectorUnknown,
        reason: reason)

proc authEntries(config: TsukiConfig,
    sessionKey: KeyLookup): seq[agentui.ProviderAuthEntry] =
  ## Projects provider auth state for the sign-in dialog. Stored and session
  ## keys count as present; Codex sign-in state is owned by the Codex CLI.
  for provider in config.providers:
    if not provider.enabled: continue
    if provider.kind == "codex_app_server":
      result.add agentui.ProviderAuthEntry(providerId: $provider.id,
        providerName: provider.displayName,
        kind: agentui.providerAuthDevice,
        status: agentui.providerAuthUnknown,
        detail: "Sign-in is managed by the Codex CLI")
    elif provider.kind in ["openai_compatible", "openrouter"]:
      let hasKey = provider.resolvedCredential.len > 0 or
        sessionKey(provider.id).len > 0
      result.add agentui.ProviderAuthEntry(providerId: $provider.id,
        providerName: provider.displayName,
        kind: agentui.providerAuthApiKey,
        status: if hasKey: agentui.providerAuthReady
          else: agentui.providerAuthMissing,
        credentialEnv: provider.credentialEnv,
        detail: if provider.credentialEnv.len > 0:
          "env " & provider.credentialEnv & " or a stored key" else: "")

proc mergeModels(models: var seq[ModelDescriptor],
    incoming: openArray[ModelDescriptor]) =
  for candidate in incoming:
    var matched = false
    for existing in models.mitems:
      if existing.providerId == candidate.providerId and
          existing.id == candidate.id:
        matched = true
        if existing.provenance != provenanceConfigured or
            candidate.provenance == provenanceConfigured:
          existing = candidate
        break
    if not matched:
      models.add candidate
  models.sort(proc (left, right: ModelDescriptor): int =
    result = cmp($left.providerId, $right.providerId)
    if result == 0: result = cmp($left.id, $right.id))

proc modelSnapshot(host: ptr HostState): seq[ModelDescriptor] =
  acquire(host[].modelsLock)
  result = host[].models
  release(host[].modelsLock)

proc replaceProviderModels(host: ptr HostState, providerId: ProviderId,
    incoming: openArray[ModelDescriptor]): seq[ModelDescriptor] =
  ## Atomically replaces remote/cache entries while preserving user config.
  acquire(host[].modelsLock)
  var retained: seq[ModelDescriptor]
  for model in host[].models:
    if model.providerId != providerId or
        model.provenance == provenanceConfigured:
      retained.add model
  retained.mergeModels(incoming)
  host[].models = retained
  result = host[].models
  release(host[].modelsLock)

proc saveCatalog(host: ptr HostState): string =
  acquire(host[].cacheLock)
  result = saveModelCache(host[].modelCacheFile, host.modelSnapshot)
  release(host[].cacheLock)

proc makeAdapter(provider: ProviderConfig, credential = ""): ProviderAdapter =
  ## Builds the transport adapter for one configured provider. An explicit
  ## credential overrides the provider's environment variable.
  var providerLimits = phase1Limits()
  providerLimits.requestTimeoutMs = provider.requestTimeoutMs
  providerLimits.idleStreamTimeoutMs = provider.idleStreamTimeoutMs
  let resolved = if credential.len > 0: credential
    else: provider.resolvedCredential
  case provider.kind
  of "openrouter":
    newOpenRouterProvider(provider.id, provider.displayName, resolved,
      provider.models, providerLimits,
      if provider.baseUrl.len > 0: provider.baseUrl else: openRouterBaseUrl)
  of "openai_compatible":
    newOpenAICompatProvider(provider.id, provider.displayName,
      provider.baseUrl, resolved, provider.models, providerLimits)
  of "codex_app_server":
    newCodexAppServerProvider(provider.id, provider.displayName,
      limits = providerLimits)
  else:
    nil

proc hostAdapters(host: ptr HostState): seq[ProviderAdapter] =
  acquire(host[].adaptersLock)
  result = host[].adapters
  release(host[].adaptersLock)

proc upsertAdapter(host: ptr HostState, adapter: ProviderAdapter) =
  acquire(host[].adaptersLock)
  var replaced = false
  for index in 0 ..< host[].adapters.len:
    if host[].adapters[index].id == adapter.id:
      host[].adapters[index] = adapter
      replaced = true
      break
  if not replaced: host[].adapters.add adapter
  release(host[].adaptersLock)

proc sessionKey(host: ptr HostState, providerId: ProviderId): string =
  if host.isNil: return ""
  acquire(host[].authLock)
  for entry in host[].sessionKeys:
    if entry.providerId == providerId:
      result = entry.key
      break
  release(host[].authLock)

proc setSessionKey(host: ptr HostState, providerId: ProviderId, key: string) =
  acquire(host[].authLock)
  var replaced = false
  for index in 0 ..< host[].sessionKeys.len:
    if host[].sessionKeys[index].providerId == providerId:
      host[].sessionKeys[index].key = key
      replaced = true
      break
  if not replaced: host[].sessionKeys.add (providerId, key)
  release(host[].authLock)

proc keyLookup(host: ptr HostState): KeyLookup =
  result = proc (providerId: ProviderId): string {.gcsafe.} =
    host.sessionKey(providerId)

proc hostSelectorEntries(host: ptr HostState,
    models: openArray[ModelDescriptor]): seq[SelectorEntry] =
  host[].config.selectorEntries(models, host.keyLookup)

proc publishAuthEntries(host: ptr HostState) =
  discard host[].chat.post agentui.authUpdated(
    host[].config.authEntries(host.keyLookup))

proc persistKeys(host: ptr HostState): string =
  ## Writes every session key to the owner-only credentials file.
  var entries: seq[StoredCredential]
  acquire(host[].authLock)
  for entry in host[].sessionKeys:
    entries.add StoredCredential(providerId: entry.providerId,
      apiKey: entry.key)
  release(host[].authLock)
  saveCredentials(host[].credentialsFile, entries)

proc copyToSystemClipboard(text: string): string =
  ## Pipes text to the platform clipboard tool. Returns "" on success or a
  ## short reason when no tool accepted it.
  var candidates: seq[tuple[command: string, args: seq[string]]]
  when defined(macosx):
    candidates.add ("pbcopy", @[])
  elif defined(windows):
    candidates.add ("clip", @[])
  else:
    if getEnv("WAYLAND_DISPLAY").len > 0:
      candidates.add ("wl-copy", @[])
    candidates.add ("xclip", @["-selection", "clipboard"])
    candidates.add ("xsel", @["--clipboard", "--input"])
  for candidate in candidates:
    if findExe(candidate.command).len == 0: continue
    try:
      let process = startProcess(candidate.command, args = candidate.args,
        options = {poUsePath, poStdErrToStdOut})
      try:
        process.inputStream.write(text)
        process.inputStream.close()
        let code = process.waitForExit(2_000)
        if code == 0: return ""
        result = candidate.command & " exited with status " & $code
      finally:
        process.close()
    except CatchableError as failure:
      result = failure.msg.safeDisplay(256)
  if result.len == 0: result = "no clipboard tool was found"

proc refreshAdapterMain() {.thread.} =
  ## Refreshes one adapter's models after its credential changed. The target
  ## travels through the shared host slot under the adapters lock; no GC'd
  ## value crosses the thread boundary as a thread argument.
  acquire(activeHost[].adaptersLock)
  let adapter = activeHost[].refreshAdapter
  activeHost[].refreshAdapter = nil
  release(activeHost[].adaptersLock)
  if adapter.isNil: return
  let discovered = adapter.refreshModels(activeHost[].discoveryToken)
  if discovered.error.ok:
    discard activeHost.replaceProviderModels(adapter.id, discovered.models)
    var entries = activeHost.hostSelectorEntries(activeHost.modelSnapshot)
    discard activeHost[].chat.post selectorUpdated(entries)
    let cacheError = activeHost.saveCatalog()
    if cacheError.len > 0:
      discard activeHost[].chat.post notice("model-cache-error", cacheError)
  elif discovered.error.kind != providerCancelled:
    discard activeHost[].chat.post notice("model-discovery-error",
      "Models for " & adapter.displayName &
      " could not be refreshed: " & discovered.error.message)

proc freeRefreshSlot(host: ptr HostState): int =
  ## Spawn, reap, and join all happen on the UI thread, so no lock is needed.
  for index in 0 ..< host[].refreshThreads.len:
    if host[].refreshActive[index] and not running(
        host[].refreshThreads[index]):
      joinThread(host[].refreshThreads[index])
      host[].refreshActive[index] = false
    if not host[].refreshActive[index]: return index
  -1

proc spawnRefresh(host: ptr HostState, adapter: ProviderAdapter) =
  ## Starts one bounded model refresh without blocking the UI thread. The
  ## thread handle must live at a stable address, so the thread is created
  ## directly into its shared-host slot; slots are joined at exit.
  let slot = host.freeRefreshSlot()
  if slot < 0:
    discard host[].chat.post notice("model-refresh-busy",
      "Too many model refreshes are already running.")
    return
  acquire(host[].adaptersLock)
  host[].refreshAdapter = adapter
  release(host[].adaptersLock)
  try:
    createThread(host[].refreshThreads[slot], refreshAdapterMain)
  except CatchableError as failure:
    acquire(host[].adaptersLock)
    host[].refreshAdapter = nil
    release(host[].adaptersLock)
    discard host[].chat.post notice("model-refresh-error", failure.msg)
    return
  host[].refreshActive[slot] = true

proc joinRefreshes(host: ptr HostState) =
  for index in 0 ..< host[].refreshThreads.len:
    if host[].refreshActive[index]:
      joinThread(host[].refreshThreads[index])
      host[].refreshActive[index] = false

proc discoveryMain() {.thread.} =
  var refreshed = false
  var failures: seq[SelectorEntry]
  let adapters = activeHost.hostAdapters()
  for adapter in adapters:
    if activeHost[].discoveryToken.isCancelled: break
    let discovered = adapter.refreshModels(activeHost[].discoveryToken)
    if discovered.error.ok:
      discard activeHost.replaceProviderModels(adapter.id,
        discovered.models)
      refreshed = true
      var entries = activeHost.hostSelectorEntries(activeHost.modelSnapshot)
      entries.add failures
      discard activeHost[].chat.post selectorUpdated(entries)
    elif discovered.error.kind notin {providerCancelled,
        providerConfiguration}:
      failures.add SelectorEntry(providerId: $adapter.id,
        providerName: adapter.displayName, displayName: "Discovery unavailable",
        imageInput: selectorUnknown, tools: selectorUnknown, available: false,
        reason: discovered.error.message)
      var entries = activeHost.hostSelectorEntries(activeHost.modelSnapshot)
      entries.add failures
      discard activeHost[].chat.post selectorUpdated(entries)
  if refreshed and not activeHost[].discoveryToken.isCancelled:
    let cacheError = activeHost.saveCatalog()
    if cacheError.len > 0:
      discard activeHost[].chat.post notice("model-cache-error", cacheError)

proc updatedLabel(updatedAtMs: int64): string =
  if updatedAtMs <= 0: return ""
  try:
    fromUnix(updatedAtMs div 1_000).local.format("yyyy-MM-dd HH:mm")
  except CatchableError:
    ""

proc sessionEntries(listed: SessionListResult): seq[SessionPickerEntry] =
  for session in listed.sessions:
    result.add SessionPickerEntry(id: $session.id, title: session.title,
      workspace: session.workspaceRoot,
      updatedLabel: session.updatedAtMs.updatedLabel,
      providerModel: $session.providerId & "/" & $session.modelId &
        (if session.mode == modeChat: " · chat" else: ""),
      interrupted: session.interrupted)
  for diagnostic in listed.diagnostics:
    result.add SessionPickerEntry(id: diagnostic.path,
      title: "Corrupt session", corrupt: true,
      diagnostic: diagnostic.message)

proc runTsuki*(arguments: seq[string]): int =
  let parsed = parseCli(arguments)
  if parsed.error.len > 0:
    stderr.writeLine("tsuki: " & parsed.error)
    stderr.writeLine("Run 'tsuki --help' for usage.")
    return 2
  if parsed.help:
    stdout.write(cliHelp)
    return 0
  if parsed.version:
    stdout.writeLine("tsuki " & tsukiVersion)
    return 0

  var cli = parsed.options
  if cli.configPath.len == 0 and getEnv("TSUKI_CONFIG").len > 0:
    cli.configPath = getEnv("TSUKI_CONFIG")
  let workspaceInput = if cli.workspace.len > 0: cli.workspace
    else: getCurrentDir()
  var workspace: string
  try:
    workspace = normalizedPath(absolutePath(workspaceInput))
    if not dirExists(workspace):
      stderr.writeLine("tsuki: workspace is not a directory: " &
        workspace.safeDisplay(4096))
      return 2
  except CatchableError as failure:
    stderr.writeLine("tsuki: could not resolve workspace: " &
      failure.msg.safeDisplay(4096))
    return 2

  let loadedConfig = loadConfig(cli.configPath)
  var config = if loadedConfig.error.len > 0: defaultConfig()
    else: loadedConfig.config
  config = config.applyOverrides(cli)
  let defaults = platformPaths(dataOverride = if cli.dataDir.len > 0:
    cli.dataDir elif config.dataDir.len > 0: config.dataDir else: "")
  let store = initSessionStore(defaults)
  let listed = store.list(workspace)
  var session: Session
  var startupError = ""
  if not cli.newSession and $cli.sessionId != "":
    let loaded = store.load(cli.sessionId)
    if loaded.error.len > 0: startupError = loaded.error
    else: session = loaded.session
  elif not cli.newSession and listed.sessions.len > 0:
    let loaded = store.load(listed.sessions[0].id)
    if loaded.error.len == 0: session = loaded.session
    else: startupError = loaded.error
  if $session.id == "":
    session = newSession(generateSessionId(), workspace,
      config.defaultProvider, config.defaultModel)

  if $cli.providerId != "":
    session.providerId = cli.providerId
  elif $session.providerId == "":
    session.providerId = config.defaultProvider
  if $cli.modelId != "":
    session.modelId = cli.modelId
  elif $session.modelId == "":
    session.modelId = config.defaultModel
  if cli.mode == "chat": session.mode = modeChat
  elif cli.mode == "agent": session.mode = modeAgent

  var models = config.configuredModels
  let cached = loadModelCache(defaults.modelCacheFile)
  for cachedModel in cached.models:
    if $models.findModel(cachedModel.providerId, cachedModel.id).id == "":
      models.add cachedModel
  let providerConfig = config.findProvider(session.providerId)
  let storedCredentials = loadCredentials(defaults.credentialsFile)
  let storedKey: KeyLookup = proc (providerId: ProviderId): string {.gcsafe.} =
    for entry in storedCredentials.entries:
      if entry.providerId == providerId: return entry.apiKey
  var adapters: seq[ProviderAdapter]
  for configured in config.providers:
    if not configured.enabled: continue
    let built = makeAdapter(configured, storedKey(configured.id))
    if not built.isNil: adapters.add built
  var adapter = adapters.findAdapter(session.providerId)
  let configuredAdapter = not adapter.isNil
  if adapter.isNil:
    adapter = newMockProvider(script = @[mockFail(ProviderError(
      kind: providerConfiguration,
      message: "The selected provider is not configured. Use /provider " &
        "to sign in or add a key."))])
  let adapterValidation = if not configuredAdapter:
    ProviderError(kind: providerConfiguration,
      message: "The selected provider kind is not available.")
  else: adapter.validate()
  var selected = models.findModel(session.providerId, session.modelId)
  if $selected.id == "" and $session.modelId != "":
    selected = ModelDescriptor(providerId: session.providerId,
      id: session.modelId, displayName: $session.modelId,
      capabilities: unknownCapabilities(), available: true,
      provenance: provenanceConfigured)
    models.add selected
  if $selected.id == "":
    selected = ModelDescriptor(providerId: session.providerId,
      displayName: "No model selected", available: false,
      unavailableReason: "Choose a configured model with /model.")

  discard session.refreshAttachmentReferences()
  let initialSaveError = store.save(session)
  let currentListed = store.list(workspace)
  let chat = initAgentChat(session.title, $session.id)
  chat.projectSession(session)
  if session.messages.len == 0:
    chat.apply notice("welcome", if session.mode == modeChat:
      "月  tsuki\n    chat mode\n\n" &
        "Ask anything or plan something. The workspace is not read.\n" &
        "/agent returns to the workspace. /help lists commands."
      else:
        "月  tsuki\n    a fast, tiny coding agent\n\n" &
        "Type a request, or use /help for commands.\n" &
        "/chat talks or plans without reading the workspace.",
      banner = true)
  if loadedConfig.error.len > 0:
    chat.apply agentError("config-error", loadedConfig.error &
      "\nConfiguration: " & loadedConfig.path)
  if startupError.len > 0:
    chat.apply agentError("session-error", startupError)
  if initialSaveError.len > 0:
    chat.apply agentError("session-save-error", initialSaveError)
  if storedCredentials.error.len > 0:
    chat.apply agentError("credentials-error", storedCredentials.error &
      "\nCredentials: " & defaults.credentialsFile)
  for diagnostic in listed.diagnostics:
    chat.apply notice("session-corrupt:" & diagnostic.path,
      "Skipped a corrupt session: " & diagnostic.path & "\n" &
      diagnostic.message)
  if $providerConfig.id == "":
    chat.apply notice("first-run-provider",
      "No configured provider matches '" & $session.providerId & "'.\n" &
      "Configuration: " & loadedConfig.path)
  elif providerConfig.needsKey(storedKey):
    chat.apply notice("first-run-credential",
      "Use /provider to add a key for " & providerConfig.displayName &
      ", or set " & providerConfig.credentialEnv & ".\n" &
      "Configuration: " & loadedConfig.path)
  elif not adapterValidation.ok:
    chat.apply agentError("provider-config", adapterValidation.message)
  if $selected.id == "":
    chat.apply notice("first-run-model",
      "No model is selected. Use /model or " &
      "start with --model <id>.")

  let uiSink = chat.tuiEventSink(workspace)
  proc controllerSink(event: ControllerEvent) {.gcsafe.} =
    uiSink(event)
    if event.kind == controllerSessionsChanged:
      discard chat.post agentui.sessionsUpdated(
        store.list(event.text).sessionEntries)
    elif event.kind == controllerModelsChanged and not activeHost.isNil:
      let current = activeHost.replaceProviderModels(event.providerId,
        event.models)
      discard chat.post agentui.selectorUpdated(
        activeHost.hostSelectorEntries(current))
      let cacheError = activeHost.saveCatalog()
      if cacheError.len > 0:
        discard chat.post notice("model-cache-error", cacheError)
  let controller = initAgentController(session, store, adapter, selected,
    controllerSink,
    toolsEnabled = config.toolsEnabled(session.providerId))
  let offline = providerConfig.needsKey(storedKey) or
    not adapterValidation.ok
  let startupAuth = config.authEntries(storedKey)
  var availableSelectors = config.selectorEntries(models, storedKey)
  let statusDirectory = if session.mode == modeChat: "" else: workspace
  chat.apply agentui.selectorUpdated(availableSelectors)
  chat.apply agentui.authUpdated(startupAuth)
  chat.apply agentui.sessionsUpdated(currentListed.sessionEntries)
  chat.apply agentui.statusUpdated(agentui.AgentViewStatus(
    provider: $session.providerId, model: $session.modelId,
    mode: $session.mode,
    message: if offline: "offline" else: "ready", offline: offline,
    contextLimit: selected.contextWindow, directory: statusDirectory,
    reasoningEffort: session.reasoningEffort))
  let options = agentTuiOptions(status = AgentStatus(
    provider: $session.providerId, model: $session.modelId,
    mode: $session.mode,
    message: if offline: "offline" else: "ready", offline: offline,
    directory: statusDirectory, reasoningEffort: session.reasoningEffort),
    selectorEntries = availableSelectors,
    authEntries = startupAuth,
    sessionEntries = currentListed.sessionEntries,
    imageLoader = if getEnv("TSUKI_IMAGES").toLowerAscii in ["0", "off",
        "false"]: nil
      else: previewLoader(workspace))

  activeHost = cast[ptr HostState](allocShared0(sizeof(HostState)))
  activeHost[].controller = controller
  activeHost[].chat = chat
  activeHost[].config = config
  activeHost[].adapters = adapters
  activeHost[].models = models
  activeHost[].modelCacheFile = defaults.modelCacheFile
  activeHost[].credentialsFile = defaults.credentialsFile
  for entry in storedCredentials.entries:
    activeHost[].sessionKeys.add (entry.providerId, entry.apiKey)
  activeHost[].discoveryToken = initCancellationToken()
  initLock(activeHost[].modelsLock)
  initLock(activeHost[].cacheLock)
  initLock(activeHost[].adaptersLock)
  initLock(activeHost[].authLock)
  var worker: Thread[void]
  createThread(worker, controllerMain)
  var discovery: Thread[void]
  var discoveryStarted = false
  for candidate in hostAdapters(activeHost):
    if candidate.validate.ok:
      discoveryStarted = true
      break
  if discoveryStarted:
    createThread(discovery, discoveryMain)

  proc handleAction(action: AgentAction) =
    case action.kind
    of aaSubmit:
      discard controller.post ControllerCommand(kind: commandSubmit,
        text: action.prompt)
    of aaCancel:
      discard controller.post ControllerCommand(kind: commandCancel)
    of aaRetry:
      discard controller.post ControllerCommand(kind: commandRetry)
    of aaNewSession:
      discard controller.post ControllerCommand(kind: commandNewSession)
    of aaResumeSession:
      let targetId = SessionId(action.argument.safeId())
      let target = store.loadHeader(targetId)
      var targetModel: ModelDescriptor
      var targetAdapter: ProviderAdapter
      var targetTools = false
      if target.error.len == 0:
        targetAdapter = activeHost.hostAdapters.findAdapter(
          target.header.providerId)
        targetModel = activeHost.modelSnapshot.findModel(
          target.header.providerId,
          target.header.modelId)
        if $targetModel.id == "" and not targetAdapter.isNil:
          targetModel = ModelDescriptor(providerId: target.header.providerId,
            id: target.header.modelId, displayName: $target.header.modelId,
            capabilities: unknownCapabilities(), available: true,
            provenance: provenanceCached)
        targetTools = config.toolsEnabled(target.header.providerId)
      discard controller.post ControllerCommand(kind: commandSwitchSession,
        sessionId: targetId, model: targetModel, adapter: targetAdapter,
        toolsEnabled: targetTools, toolsConfigured: target.error.len == 0)
    of aaRenameSession:
      let renameParts = action.argument.split('\n', 1)
      if renameParts.len == 2:
        discard controller.post ControllerCommand(kind: commandRename,
          sessionId: SessionId(renameParts[0].safeId()), text: renameParts[1])
      else:
        discard controller.post ControllerCommand(kind: commandRename,
          text: action.argument)
    of aaModelSelector, aaProviderSelector:
      let identity = action.argument.split('\n')
      if identity.len == 2:
        let providerId = ProviderId(identity[0].safeId())
        let modelId = ModelId(identity[1].safeDisplay(1024))
        var model = activeHost.modelSnapshot.findModel(providerId, modelId)
        let selectedAdapter = activeHost.hostAdapters.findAdapter(providerId)
        if $model.id == "" and not selectedAdapter.isNil:
          model = ModelDescriptor(providerId: providerId, id: modelId,
            displayName: $modelId, capabilities: unknownCapabilities(),
            available: true, provenance: provenanceDiscovered)
        if $model.id != "" and not selectedAdapter.isNil:
          discard controller.post ControllerCommand(kind: commandSelectModel,
            model: model, adapter: selectedAdapter,
            reasoningEffort: action.reasoningEffort,
            toolsEnabled: config.toolsEnabled(providerId),
            toolsConfigured: true)
    of aaApiKey:
      let parts = action.argument.split('\n', 1)
      if parts.len != 2: discard
      else:
        let providerId = ProviderId(parts[0].safeId())
        let key = parts[1].strip()
        let provider = activeHost[].config.findProvider(providerId)
        if $provider.id == "":
          discard chat.post toast("api-key",
            "No configured provider matches that ID.", success = false)
        elif key.len == 0:
          discard chat.post toast("api-key",
            "The API key was empty. Nothing was stored.", success = false)
        elif provider.kind notin ["openai_compatible", "openrouter"]:
          discard chat.post toast("api-key",
            provider.displayName & " signs in through its own flow instead " &
            "of an API key.", success = false)
        else:
          let keyed = makeAdapter(provider, key)
          let validation = keyed.validate()
          if not validation.ok:
            discard chat.post toast("api-key", validation.message,
              success = false)
          else:
            activeHost.upsertAdapter(keyed)
            activeHost.setSessionKey(providerId, key)
            let saveError = activeHost.persistKeys()
            activeHost.publishAuthEntries()
            activeHost.spawnRefresh(keyed)
            var confirmation = if saveError.len == 0:
              "API key saved for " & provider.displayName
            else:
              "API key added for " & provider.displayName &
                " for this session only"
            if saveError.len > 0:
              discard chat.post agentError("credentials-save", saveError &
                "\nCredentials: " & activeHost[].credentialsFile)
            if $session.providerId == $providerId and $session.modelId != "":
              var model = activeHost.modelSnapshot.findModel(providerId,
                session.modelId)
              if $model.id == "":
                model = ModelDescriptor(providerId: providerId,
                  id: session.modelId, displayName: $session.modelId,
                  capabilities: unknownCapabilities(), available: true,
                  provenance: provenanceConfigured)
              discard controller.post ControllerCommand(
                kind: commandSelectModel, model: model, adapter: keyed,
                toolsEnabled: config.toolsEnabled(providerId),
                toolsConfigured: true)
            else:
              confirmation.add ". Choose a model with /model."
            discard chat.post toast("api-key", confirmation)
    of aaAttach:
      discard controller.post ControllerCommand(kind: commandAttach,
        text: parseAttachArgument("/attach " & action.argument))
    of aaDetach:
      discard controller.post ControllerCommand(kind: commandDetach,
        text: action.argument)
    of aaArchiveSession:
      discard controller.post ControllerCommand(kind: commandArchive,
        sessionId: SessionId(action.argument.safeId()))
    of aaSessions:
      discard chat.post notice("sessions-empty",
        "No stored sessions are available in this workspace.")
    of aaLogin, aaLogout:
      var authAdapter: ProviderAdapter
      if action.argument.len > 0:
        let requested = activeHost.hostAdapters.findAdapter(
          ProviderId(action.argument.safeId()))
        if not requested.isNil and requested.kind == "codex_app_server":
          authAdapter = requested
      if authAdapter.isNil:
        authAdapter = activeHost.hostAdapters.findAdapterKind(
          "codex_app_server")
      if authAdapter.isNil:
        let label = if action.kind == aaLogin: "signing in" else: "signing out"
        discard chat.post notice("chatgpt-provider-missing",
          "Add an enabled ChatGPT Codex provider before " & label & ".")
      else:
        let commandKind = if action.kind == aaLogin: commandLogin
          else: commandLogout
        discard controller.post ControllerCommand(kind: commandKind,
          adapter: authAdapter)
    of aaSetMode:
      case action.argument
      of "chat":
        discard controller.post ControllerCommand(kind: commandSetMode,
          mode: modeChat)
      of "agent":
        discard controller.post ControllerCommand(kind: commandSetMode,
          mode: modeAgent)
      else:
        discard chat.post notice("mode-usage", "Use /chat or /agent.")
    of aaApproval:
      discard
    of aaCopy:
      let failure = copyToSystemClipboard(action.text)
      if failure.len == 0 or action.terminalCopied:
        let lines = action.text.count('\n') + 1
        discard chat.post toast("copy", "Copied " & $lines &
          (if lines == 1: " line" else: " lines"))
      else:
        discard chat.post toast("copy", "Copy failed: " & failure,
          success = false)

  let tuiResult = runAgentTui(chat, handleAction, options)
  activeHost[].discoveryToken.cancel()
  controller.shutdown()
  joinThread(worker)
  if discoveryStarted:
    joinThread(discovery)
  activeHost.joinRefreshes()
  controller.commands.close()
  chat.close()
  deinitLock(activeHost[].modelsLock)
  deinitLock(activeHost[].cacheLock)
  deinitLock(activeHost[].adaptersLock)
  deinitLock(activeHost[].authLock)
  activeHost[] = HostState()
  deallocShared(cast[pointer](activeHost))
  activeHost = nil
  if not tuiResult.ok:
    stderr.writeLine(tuiResult.error.safeDisplay(4096))
    return 1

when isMainModule:
  quit(runTsuki(commandLineParams()))
