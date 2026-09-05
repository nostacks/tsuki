## Versioned user configuration, platform paths, precedence, and redaction.

import std/[json, os, sets, strutils]
import boundedio, limits, types

const currentConfigSchemaVersion* = 1

type
  PlatformPaths* = object
    configFile*: string
    dataDir*: string
    sessionsDir*: string
    archivedDir*: string
    cacheDir*: string
    modelCacheFile*: string
    credentialsFile*: string

  ProviderConfig* = object
    id*: ProviderId
    kind*: string
    displayName*: string
    baseUrl*: string
    credentialEnv*: string
    models*: seq[ModelDescriptor]
    requestTimeoutMs*: int
    idleStreamTimeoutMs*: int
    toolsEnabled*: bool
    enabled*: bool

  TsukiConfig* = object
    schemaVersion*: int
    defaultProvider*: ProviderId
    defaultModel*: ModelId
    providers*: seq[ProviderConfig]
    dataDir*: string

  CliOverrides* = object
    configPath*: string
    dataDir*: string
    providerId*: ProviderId
    modelId*: ModelId
    baseUrl*: string
    credentialEnv*: string
    workspace*: string
    sessionId*: SessionId
    newSession*: bool
    mode*: string ## "agent", "chat", or empty to keep the session's mode.

  ConfigLoadResult* = object
    config*: TsukiConfig
    path*: string
    error*: string

when defined(windows):
  func envOr(value, name: string): string =
    if value.len > 0: value else: getEnv(name)

proc platformPaths*(home = "", configHome = "", dataHome = "",
    cacheHome = "", dataOverride = ""): PlatformPaths =
  ## Resolves config/data/cache paths without creating repository-local state.
  let resolvedHome = if home.len > 0: home else: getHomeDir()
  when defined(windows):
    let roaming = configHome.envOr("APPDATA")
    let local = dataHome.envOr("LOCALAPPDATA")
    let configBase = if roaming.len > 0: roaming else: resolvedHome
    let dataBase = if dataOverride.len > 0: dataOverride
      elif local.len > 0: local / "Tsuki" else: resolvedHome / "Tsuki"
    result.configFile = configBase / "Tsuki" / "config.json"
    result.dataDir = dataBase
    result.cacheDir = if cacheHome.len > 0: cacheHome else: dataBase / "cache"
  else:
    let configBase = if configHome.len > 0: configHome
      elif getEnv("XDG_CONFIG_HOME").len > 0: getEnv("XDG_CONFIG_HOME")
      else: resolvedHome / ".config"
    let dataBase = if dataOverride.len > 0: dataOverride
      elif dataHome.len > 0: dataHome
      elif getEnv("XDG_DATA_HOME").len > 0: getEnv("XDG_DATA_HOME")
      else: resolvedHome / ".local" / "share"
    let cacheBase = if cacheHome.len > 0: cacheHome
      elif getEnv("XDG_CACHE_HOME").len > 0: getEnv("XDG_CACHE_HOME")
      else: resolvedHome / ".cache"
    result.configFile = configBase / "tsuki" / "config.json"
    result.dataDir = if dataOverride.len > 0: dataBase else: dataBase / "tsuki"
    result.cacheDir = cacheBase / "tsuki"
  result.sessionsDir = result.dataDir / "sessions"
  result.archivedDir = result.dataDir / "archived"
  result.modelCacheFile = result.cacheDir / "models.json"
  result.credentialsFile = result.dataDir / "credentials.json"

func defaultConfig*(): TsukiConfig =
  let bounds = phase1Limits()
  let providerId = ProviderId("openai")
  TsukiConfig(schemaVersion: currentConfigSchemaVersion,
    defaultProvider: providerId, providers: @[
      ProviderConfig(id: providerId, kind: "openai_compatible",
        displayName: "OpenAI", baseUrl: "https://api.openai.com/v1",
        credentialEnv: "OPENAI_API_KEY",
        requestTimeoutMs: bounds.requestTimeoutMs,
        idleStreamTimeoutMs: bounds.idleStreamTimeoutMs,
        toolsEnabled: true, enabled: true),
      ProviderConfig(id: ProviderId("openrouter"), kind: "openrouter",
        displayName: "OpenRouter",
        baseUrl: "https://openrouter.ai/api/v1",
        credentialEnv: "OPENROUTER_API_KEY",
        requestTimeoutMs: bounds.requestTimeoutMs,
        idleStreamTimeoutMs: bounds.idleStreamTimeoutMs,
        toolsEnabled: true, enabled: true),
      ProviderConfig(id: ProviderId("chatgpt"), kind: "codex_app_server",
        displayName: "ChatGPT (Codex subscription)",
        requestTimeoutMs: bounds.requestTimeoutMs,
        idleStreamTimeoutMs: bounds.idleStreamTimeoutMs,
        toolsEnabled: false, enabled: true)])

func capability(node: JsonNode, key: string): CapabilityState =
  if not node.hasKey(key): return capabilityUnknown
  case node[key].kind
  of JBool:
    if node[key].getBool: capabilitySupported else: capabilityUnsupported
  of JString:
    case node[key].getStr.toLowerAscii
    of "supported", "true", "yes": capabilitySupported
    of "unsupported", "false", "no": capabilityUnsupported
    else: capabilityUnknown
  else:
    capabilityUnknown

func positiveInt(node: JsonNode, key: string, fallback: int): int =
  if node.hasKey(key) and node[key].kind == JInt:
    let value = node[key].getInt
    if value > 0 and value <= fallback: return int(value)
  fallback

proc unknownKeys(node: JsonNode, allowed: openArray[string]): string =
  if node.kind != JObject: return
  var accepted = initHashSet[string]()
  for key in allowed: accepted.incl key
  for key in node.keys:
    if key notin accepted:
      if result.len > 0: result.add ", "
      result.add key.safeDisplay(128)

proc parseConfig*(source: string): ConfigLoadResult =
  ## Parses a bounded version-1 document and rejects ambiguous critical data.
  if source.len > 4 * 1024 * 1024:
    result.error = "configuration exceeds the 4 MiB limit"
    return
  try:
    let root = parseJson(source)
    if root.kind != JObject:
      result.error = "configuration root must be an object"
      return
    let unknown = root.unknownKeys(["schemaVersion", "defaultProvider",
      "defaultModel", "dataDir", "providers"])
    if unknown.len > 0:
      result.error = "unknown configuration fields: " & unknown
      return
    let version = root{"schemaVersion"}.getInt(0)
    if version != currentConfigSchemaVersion:
      result.error = if version > currentConfigSchemaVersion:
        "configuration schema is newer than this Tsuki build"
      else:
        "configuration schemaVersion must be 1"
      return
    result.config = TsukiConfig(schemaVersion: version,
      defaultProvider: ProviderId(root{"defaultProvider"}.getStr),
      defaultModel: ModelId(root{"defaultModel"}.getStr),
      dataDir: root{"dataDir"}.getStr)
    let providers = root{"providers"}
    if providers.isNil or providers.kind != JArray:
      result.error = "configuration providers must be an array"
      return
    if providers.len > 1_000:
      result.error = "configuration contains too many providers"
      return
    var ids = initHashSet[string]()
    var totalModels = 0
    let bounds = phase1Limits()
    for providerNode in providers:
      if providerNode.kind != JObject:
        result.error = "each provider must be an object"
        return
      let providerUnknown = providerNode.unknownKeys(["id", "kind",
        "displayName", "baseUrl", "credentialEnv", "models",
        "requestTimeoutMs", "idleStreamTimeoutMs", "toolsEnabled",
        "enabled"])
      if providerUnknown.len > 0:
        result.error = "unknown provider fields: " & providerUnknown
        return
      let id = providerNode{"id"}.getStr.safeId()
      if id.len == 0:
        result.error = "provider ID must not be empty"
        return
      if id in ids:
        result.error = "duplicate provider ID: " & id
        return
      ids.incl id
      var providerConfig = ProviderConfig(id: ProviderId(id),
        kind: providerNode{"kind"}.getStr,
        displayName: providerNode{"displayName"}.getStr.safeDisplay(256),
        baseUrl: providerNode{"baseUrl"}.getStr,
        credentialEnv: providerNode{"credentialEnv"}.getStr.safeId(),
        requestTimeoutMs: providerNode.positiveInt("requestTimeoutMs",
          bounds.requestTimeoutMs),
        idleStreamTimeoutMs: providerNode.positiveInt("idleStreamTimeoutMs",
          bounds.idleStreamTimeoutMs),
        toolsEnabled: providerNode{"toolsEnabled"}.getBool(true),
        enabled: providerNode{"enabled"}.getBool(true))
      if providerConfig.kind.len == 0:
        result.error = "provider kind must not be empty"
        return
      let models = providerNode{"models"}
      if not models.isNil and models.kind == JArray:
        if totalModels > 10_000 - min(10_000, models.len):
          result.error = "configuration contains too many models"
          return
        totalModels += models.len
        var modelIds = initHashSet[string]()
        for modelNode in models:
          if modelNode.kind == JString:
            let id = modelNode.getStr.safeDisplay(512)
            if id.len == 0:
              result.error = "model ID must not be empty"
              return
            if id in modelIds:
              result.error = "duplicate model ID for " & $providerConfig.id &
                ": " & id
              return
            modelIds.incl id
            providerConfig.models.add ModelDescriptor(
              providerId: providerConfig.id, id: ModelId(id),
              displayName: id, capabilities: unknownCapabilities(),
              available: true, provenance: provenanceConfigured)
          elif modelNode.kind == JObject:
            let modelUnknown = modelNode.unknownKeys(["id", "displayName",
              "textInput", "imageInput", "streaming", "tools",
              "contextWindow", "maxOutputTokens", "available",
              "unavailableReason", "reasoningEfforts",
              "defaultReasoningEffort"])
            if modelUnknown.len > 0:
              result.error = "unknown model fields: " & modelUnknown
              return
            let id = modelNode{"id"}.getStr.safeDisplay(512)
            if id.len == 0:
              result.error = "model ID must not be empty"
              return
            if id in modelIds:
              result.error = "duplicate model ID for " & $providerConfig.id &
                ": " & id
              return
            modelIds.incl id
            let contextWindow = modelNode{"contextWindow"}.getInt(0)
            let maxOutputTokens = modelNode{"maxOutputTokens"}.getInt(0)
            if contextWindow < 0 or maxOutputTokens < 0:
              result.error = "model token limits must not be negative"
              return
            providerConfig.models.add ModelDescriptor(
              providerId: providerConfig.id, id: ModelId(id),
              displayName: modelNode{"displayName"}.getStr(id).safeDisplay(512),
              capabilities: ModelCapabilities(
                textInput: modelNode.capability("textInput"),
                imageInput: modelNode.capability("imageInput"),
                streaming: modelNode.capability("streaming"),
                tools: modelNode.capability("tools")),
              contextWindow: contextWindow,
              maxOutputTokens: maxOutputTokens,
              available: modelNode{"available"}.getBool(true),
              unavailableReason: modelNode{"unavailableReason"}.getStr
              .safeDisplay(1024), provenance: provenanceConfigured)
            let efforts = modelNode{"reasoningEfforts"}
            if not efforts.isNil:
              if efforts.kind != JArray or efforts.len > 16:
                result.error = "reasoningEfforts must be an array of at most 16 levels"
                return
              for effort in efforts:
                let value = effort.getStr
                if effort.kind != JString or value.len == 0 or
                    value.len > 64 or value.safeId(64) != value:
                  result.error = "reasoningEfforts must contain valid level identifiers"
                  return
                providerConfig.models[^1].addReasoningEffort(value)
            let defaultEffort = modelNode{"defaultReasoningEffort"}.getStr
            if defaultEffort.len > 0 and
                defaultEffort notin providerConfig.models[^1].reasoningEfforts:
              result.error = "defaultReasoningEffort must be a supported level"
              return
            providerConfig.models[^1].defaultReasoningEffort = defaultEffort
          else:
            result.error = "models must be strings or objects"
            return
      elif not models.isNil:
        result.error = "provider models must be an array"
        return
      result.config.providers.add providerConfig
  except JsonParsingError as failure:
    result.error = "invalid configuration JSON: " & failure.msg.safeDisplay()
  except CatchableError as failure:
    result.error = "invalid configuration: " & failure.msg.safeDisplay()

proc loadConfig*(path = ""): ConfigLoadResult =
  let resolved = if path.len > 0: path else: platformPaths().configFile
  result.path = resolved
  if not fileExists(resolved):
    result.config = defaultConfig()
    return
  try:
    let source = readBoundedRegularFile(resolved, 4 * 1024 * 1024)
    if source.error.len > 0:
      result.error = "could not read configuration: " & source.error
      return
    result = parseConfig(source.data)
    result.path = resolved
  except CatchableError as failure:
    result.error = "could not read configuration: " &
      failure.msg.safeDisplay(1024)

proc applyOverrides*(config: TsukiConfig, cli: CliOverrides): TsukiConfig =
  ## Applies environment then explicit CLI identity/transport overrides.
  result = config
  let envProvider = getEnv("TSUKI_PROVIDER")
  let envModel = getEnv("TSUKI_MODEL")
  let envData = getEnv("TSUKI_DATA_DIR")
  if envProvider.len > 0: result.defaultProvider = ProviderId(
      envProvider.safeId())
  if envModel.len > 0: result.defaultModel = ModelId(envModel.safeDisplay(512))
  if envData.len > 0: result.dataDir = envData
  if $cli.providerId != "": result.defaultProvider = cli.providerId
  if $cli.modelId != "": result.defaultModel = cli.modelId
  if cli.dataDir.len > 0: result.dataDir = cli.dataDir
  for provider in result.providers.mitems:
    if provider.id == result.defaultProvider:
      if cli.baseUrl.len > 0: provider.baseUrl = cli.baseUrl
      if cli.credentialEnv.len > 0:
        provider.credentialEnv = cli.credentialEnv.safeId()

proc resolvedCredential*(provider: ProviderConfig): string =
  ## Resolves a credential only at the adapter boundary; callers must not save it.
  if provider.credentialEnv.len == 0: return
  getEnv(provider.credentialEnv)

proc redact*(message: string, secrets: openArray[string] = []): string =
  ## Redacts supplied values, bearer headers, and common token-shaped strings.
  result = message.safeDisplay(64 * 1024)
  for secret in secrets:
    if secret.len > 0: result = result.replace(secret, "[REDACTED]")
  for marker in ["Bearer ", "bearer ", "Authorization: ", "authorization: "]:
    var start = result.find(marker)
    while start >= 0:
      let valueStart = start + marker.len
      var valueEnd = valueStart
      while valueEnd < result.len and result[valueEnd] notin {' ', '\t',
          '\r', '\n', ',', '"'}:
        inc valueEnd
      result = result[0 ..< valueStart] & "[REDACTED]" &
        result[valueEnd .. ^1]
      start = result.find(marker, valueStart + 10)
  for prefix in ["sk-", "key-", "token-"]:
    var start = result.find(prefix)
    while start >= 0:
      var stop = start + prefix.len
      while stop < result.len and result[stop] in
          {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}:
        inc stop
      if stop - start >= 12:
        result = result[0 ..< start] & "[REDACTED]" & result[stop .. ^1]
      else:
        inc start, prefix.len
      start = result.find(prefix, start)
