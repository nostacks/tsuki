import std/[json, os, strutils, unicode, unittest]
import tsuki/agent
import he3/agent as agentui
import he3/terminal
import he3/protocols/image

proc temporaryRoot(label: string): string =
  getTempDir() / ("tsuki-phase1-" & label & "-" & $generateSessionId())

suite "phase 1 product core":
  test "reasoning metadata survives configuration and caching":
    let configured = parseConfig("""{"schemaVersion":1,"providers":[{
      "id":"fixture","kind":"openai_compatible","displayName":"Fixture",
      "baseUrl":"https://example.com/v1","models":[{"id":"reasoner",
      "reasoningEfforts":["low","high"],"defaultReasoningEffort":"low"}]}]}""")
    check configured.error.len == 0
    if configured.error.len == 0:
      let model = configured.config.providers[0].models[0]
      check model.reasoningEfforts == @["low", "high"]
      let cached = decodeModelCache(encodeModelCache(@[model]))
      check cached.error.len == 0
      check cached.models[0].reasoningEfforts == model.reasoningEfforts
      check cached.models[0].defaultReasoningEffort == "low"

  test "reasoning selection persists and reaches requests without leaking across models":
    let root = temporaryRoot("reasoning")
    defer:
      if dirExists(root): removeDir(root)
    createDir(root)
    let store = initSessionStore(platformPaths(home = root,
        dataOverride = root / "data"))
    let provider = newMockProvider(script = @[mockText("answer"),
      mockDone(NormalizedUsage(inputTokens: 100, outputTokens: 20,
          totalTokens: 120)),
      MockStep(kind: mockComplete)])
    var model = provider.models[0]
    model.reasoningEfforts = @["low", "high"]
    let session = newSession(SessionId("s-reasoning"), root, provider.id, model.id)
    let chat = agentui.initAgentChat()
    defer: chat.close()
    let controller = initAgentController(session, store, provider, model,
      chat.tuiEventSink())
    defer: controller.commands.close()
    check controller.post ControllerCommand(kind: commandSelectModel,
      model: model,
      reasoningEffort: "high")
    check controller.post ControllerCommand(kind: commandSubmit, text: "reason")
    check controller.post ControllerCommand(kind: commandSelectModel,
      model: model,
      reasoningEffort: "unsupported")
    check controller.post ControllerCommand(kind: commandSave)
    check controller.post ControllerCommand(kind: commandShutdown)
    controller.run()
    discard chat.drain()
    check provider.requests.len == 1
    if provider.requests.len == 1: check provider.requests[0].reasoningEffort == "high"
    let saved = store.load(session.id)
    check saved.error.len == 0 and saved.session.reasoningEffort == "high"
    check chat.status.directory == root and chat.status.reasoningEffort == "high"
    check chat.status.contextUsed == 120
    check parseJson(encodeSession(saved.session)){"reasoningEffort"}.getStr == "high"
    let resumed = initAgentController(saved.session, store, provider, model,
      chat.tuiEventSink())
    defer: resumed.commands.close()
    var plain = model
    plain.id = ModelId("plain")
    plain.reasoningEfforts = @[]
    check resumed.post ControllerCommand(kind: commandSelectModel, model: plain)
    check resumed.post ControllerCommand(kind: commandSubmit, text: "plain")
    check resumed.post ControllerCommand(kind: commandShutdown)
    resumed.run()
    check provider.requests.len == 2
    if provider.requests.len == 2: check provider.requests[
        1].reasoningEffort.len == 0

  test "capabilities, identifiers, and display values stay explicit":
    let caps = unknownCapabilities()
    check caps.imageInput == capabilityUnknown
    check supportedCapabilities(tools = true).tools == capabilitySupported
    check safeId("../../bad\e[31m") == "bad_31m"
    let cleaned = safeDisplay("safe\e]52;owned\a")
    check '\e' notin cleaned
    check '\a' notin cleaned

  test "safe display strips bidi, C1, and controls on the fast path":
    let mixed = "ok‮hidden⁦xy\x01z\x7Ftab\tnl\n日本"
    let shown = safeDisplay(mixed, 4096)
    check "‮" notin shown and "⁦" notin shown
    check "" notin shown and '\x01' notin shown and '\x7F' notin shown
    check shown.count("�") == 5
    check shown.endsWith("tab\tnl\n日本")
    check safeDisplay("日本語", 4) == "日"
    check safeDisplay("plain", 0) == ""
    let repaired = safeDisplay("bad\xffbyte", 64)
    check validateUtf8(repaired) < 0 and '\xff' notin repaired

  test "session headers decode without materializing messages":
    var session = newSession(SessionId("s-header"), "/workspace",
      ProviderId("mock"), ModelId("model"), 10)
    session.title = "Header only"
    session.updatedAtMs = 77
    session.lastTurnState = turnStreaming
    for index in 0 ..< 50:
      session.messages.add Message(id: MessageId("m-" & $index),
        turnId: TurnId("t"), role: messageAssistant,
        parts: @[textPart(repeat("{[\"]}", 40))], status: messageComplete)
    let encoded = session.encodeSession
    let header = decodeSessionHeader(encoded)
    check header.error.len == 0
    check header.header.id == session.id
    check header.header.title == "Header only"
    check header.header.updatedAtMs == 77
    check header.header.providerId == ProviderId("mock")
    check header.header.modelId == ModelId("model")
    check header.header.interrupted
    check not header.header.archived
    check decodeSession(encoded).error.len == 0
    check decodeSessionHeader("""{"schemaVersion":9,"id":"x"}""")
      .futureVersion
    check decodeSessionHeader("{").error.len > 0
    check decodeSessionHeader("""{"schemaVersion":1,"id":"s"}""")
      .error.len > 0
    check decodeSessionHeader("""{"schemaVersion":1,"id":"s",
      "title":"t","workspaceRoot":"relative","messages":[]}""")
      .error.len > 0

  test "cancellation tokens wake bounded waits":
    let token = initCancellationToken()
    check not token.waitCancel(20)
    token.cancel()
    check token.waitCancel(5_000)
    check token.isCancelled

  test "dynamic picker data and staged cards stay sanitized":
    let chat = agentui.initAgentChat()
    chat.apply agentui.selectorUpdated(@[agentui.SelectorEntry(
      providerId: "provider\e", providerName: "Provider\e]52",
      modelId: "model", displayName: "Model", available: true)])
    check chat.selectorLoaded
    check chat.selectorEntries.len == 1
    check '\e' notin chat.selectorEntries[0].providerName
    chat.apply agentui.attachmentStaged(agentui.Attachment(id: "a-one",
      name: "image.png", mediaType: "image/png", sizeBytes: 24,
      width: 1, height: 1, state: agentui.attachmentViewReady))
    check chat.stagedAttachments.len == 1
    chat.apply agentui.attachmentDetached("a-one")
    check chat.stagedAttachments.len == 0

  test "provider registry and HTTP errors remain normalized":
    var registry = initProviderRegistry()
    let mock = newMockProvider()
    check registry.register(mock).ok
    check registry.find(mock.id).id == mock.id
    check registry.register(mock).kind == providerConfiguration
    check classifyHttpError(401, "owned").kind == providerAuthentication
    check classifyHttpError(429).retryable

  test "configuration is versioned and diagnostics redact credentials":
    let defaults = defaultConfig()
    check defaults.providers.len == 3
    check defaults.providers[1].kind == "openrouter"
    check defaults.providers[1].credentialEnv == "OPENROUTER_API_KEY"
    check defaults.providers[2].kind == "codex_app_server"
    check defaults.providers[2].credentialEnv.len == 0
    let loaded = parseConfig("""{
      "schemaVersion": 1,
      "defaultProvider": "local",
      "defaultModel": "vision",
      "providers": [{
        "id": "local",
        "kind": "openai_compatible",
        "displayName": "Local",
        "baseUrl": "http://127.0.0.1:8080/v1",
        "credentialEnv": "LOCAL_KEY",
        "models": [{"id":"vision","textInput":true,
          "imageInput":true,"streaming":true,"tools":false}]
      }]
    }""")
    check loaded.error.len == 0
    check loaded.config.providers.len == 1
    check loaded.config.providers[0].models[0].capabilities.imageInput ==
      capabilitySupported
    let diagnostic = redact("Authorization: Bearer sk-secretsecretsecret",
      ["sk-secretsecretsecret"])
    check "secretsecret" notin diagnostic
    check "[REDACTED]" in diagnostic
    check parseConfig("""{"schemaVersion":2,"providers":[]}""")
      .error.contains("newer")
    check parseConfig("""{"schemaVersion":1}""").error.len > 0
    check parseConfig("""{"schemaVersion":1,"providers":[{"id":"x",
      "kind":"openai_compatible","models":[{"id":"m","mystery":1}]}]}""")
      .error.contains("unknown model fields")

  test "platform paths never point into a workspace implicitly":
    let paths = platformPaths(home = "/home/test",
      configHome = "/cfg", dataHome = "/data", cacheHome = "/cache")
    when defined(windows):
      check paths.configFile.contains("Tsuki")
    else:
      check paths.configFile == "/cfg/tsuki/config.json"
      check paths.sessionsDir == "/data/tsuki/sessions"
      check paths.modelCacheFile == "/cache/tsuki/models.json"
      check paths.credentialsFile == "/data/tsuki/credentials.json"

  test "stored credentials round trip with owner-only permissions":
    let root = getTempDir() / ("tsuki-credentials-" & $generateSessionId())
    defer:
      if dirExists(root): removeDir(root)
    let path = root / "nested" / "credentials.json"
    check loadCredentials(path).entries.len == 0 and
      loadCredentials(path).error.len == 0
    let entries = @[
      StoredCredential(providerId: ProviderId("openrouter"),
        apiKey: "sk-or-1234"),
      StoredCredential(providerId: ProviderId(""), apiKey: "dropped"),
      StoredCredential(providerId: ProviderId("openai"), apiKey: "")]
    check saveCredentials(path, entries) == ""
    when defined(posix):
      check getFilePermissions(path) * {fpGroupRead, fpGroupWrite,
        fpOthersRead, fpOthersWrite} == {}
    let loaded = loadCredentials(path)
    check loaded.error.len == 0 and loaded.entries.len == 1 and
      $loaded.entries[0].providerId == "openrouter" and
      loaded.entries[0].apiKey == "sk-or-1234"
    check decodeCredentials("{\"schemaVersion\":2}").error.len > 0
    check decodeCredentials("{\"schemaVersion\":1,\"providers\":[]}")
      .error.len > 0
    check decodeCredentials("not json").error.len > 0

  test "SSE parsing survives every network chunk boundary":
    let source = ": keepalive\r\ndata: {\"x\":\"😀\"}\r\n\r\n" &
      "data: one\ndata: two\n\n"
    var expectedParser = initSseParser()
    var expected: seq[string]
    check expectedParser.feed(source, expected).len == 0
    check expectedParser.finish(expected).len == 0
    check expected == @["{\"x\":\"😀\"}", "one\ntwo"]
    for boundary in 0 .. source.len:
      var parser = initSseParser()
      var actual: seq[string]
      check parser.feed(source[0 ..< boundary], actual).len == 0
      check parser.feed(source[boundary .. ^1], actual).len == 0
      check parser.finish(actual).len == 0
      check actual == expected

  test "session schema round trips and interrupted work is not reissued":
    var session = newSession(SessionId("s-test"), "/workspace",
      ProviderId("mock"), ModelId("model"), 10)
    session.title = "Round trip"
    session.lastTurnState = turnStreaming
    session.stagedAttachments = @[ImageReference(id: AttachmentId("a-one"),
      path: "missing.png", location: attachmentWorkspaceRelative,
      displayName: "missing.png", mediaType: "image/png", sizeBytes: 10,
      width: 1, height: 1, state: attachmentReady)]
    session.messages = @[Message(id: MessageId("m-one"),
      turnId: TurnId("t-one"), role: messageAssistant,
      parts: @[textPart("partial")], status: messagePartial)]
    let decoded = decodeSession(session.encodeSession)
    check decoded.error.len == 0
    check decoded.session.title == "Round trip"
    check decoded.session.stagedAttachments.len == 1
    check decoded.session.stagedAttachments[0].path == "missing.png"
    check decoded.session.lastTurnState == turnInterrupted
    check decoded.session.messages[0].status == messageInterrupted
    let future = decodeSession("""{"schemaVersion":999}""")
    check future.futureVersion
    check decodeSession("""{"schemaVersion":1}""").error.len > 0
    var resumed = decoded.session
    check resumed.refreshAttachmentReferences()
    check resumed.stagedAttachments[0].state == attachmentMissing

  test "session store isolates corruption, orders, renames, and archives":
    let root = temporaryRoot("store")
    defer:
      if dirExists(root): removeDir(root)
    let paths = platformPaths(home = root, dataOverride = root / "data")
    let store = initSessionStore(paths)
    var older = newSession(SessionId("s-older"), root,
      timestampMs = 10)
    older.title = "Older"
    older.updatedAtMs = 10
    var newer = newSession(SessionId("s-newer"), root,
      timestampMs = 20)
    newer.title = "Newer"
    newer.updatedAtMs = 20
    check store.save(older).len == 0
    check store.save(newer).len == 0
    writeFile(paths.sessionsDir / "s-corrupt.json", "{")
    writeFile(paths.sessionsDir / "s-wrong-name.json",
      newSession(SessionId("s-other"), root).encodeSession)
    let listed = store.list(root)
    check listed.sessions.len == 2
    check listed.sessions[0].id == newer.id
    check listed.diagnostics.len == 2
    check store.rename(newer.id, "Renamed\e").len == 0
    check store.load(newer.id).session.title.startsWith("Renamed")
    check store.archive(older.id).len == 0
    check not fileExists(paths.sessionsDir / "s-older.json")
    check fileExists(paths.archivedDir / "s-older.json")

  test "request projection retains complete turn groups without mutation":
    var session = newSession(SessionId("s-context"), "/workspace")
    for index in 0 ..< 4:
      let turn = TurnId("t-" & $index)
      session.messages.add Message(id: MessageId("u-" & $index),
        turnId: turn, role: messageUser,
        parts: @[textPart(repeat("x", 300))], status: messageComplete)
      session.messages.add Message(id: MessageId("a-" & $index),
        turnId: turn, role: messageAssistant,
        parts: @[textPart(repeat("y", 300))], status: messageComplete)
    let before = session.encodeSession
    let model = ModelDescriptor(id: ModelId("small"), available: true,
      contextWindow: 700, capabilities: supportedCapabilities())
    let projected = projectRequest(session, model, reserveOutputTokens = 64,
      reserveToolBytes = 0)
    check projected.error.len == 0
    check projected.omittedTurns > 0
    check projected.notice.len > 0
    check session.encodeSession == before

  test "workspace tools are bounded and reject traversal and secrets":
    let root = temporaryRoot("tools")
    let outside = root & "-outside"
    defer:
      if dirExists(root): removeDir(root)
      if dirExists(outside): removeDir(outside)
    createDir(root)
    createDir(outside)
    createDir(root / "src")
    writeFile(root / "src" / "one.nim", "line one\nneedle here\n")
    writeFile(root / ".env", "TOKEN=owned")
    let policy = defaultToolPolicy(root)
    let listed = policy.execute(ToolRequest(id: ToolCallId("c-list"),
      name: "list_directory", argumentsJson: """{"path":"src"}"""))
    check listed.success
    check "one.nim" in listed.content
    let searched = policy.execute(ToolRequest(id: ToolCallId("c-search"),
      name: "search_text", argumentsJson: """{"query":"needle"}"""))
    check searched.success
    check "src/one.nim:2" in searched.content
    let read = policy.execute(ToolRequest(id: ToolCallId("c-read"),
      name: "read_file", argumentsJson: """{"path":"src/one.nim"}"""))
    check read.success
    check "2\tneedle here" in read.content
    let escaped = policy.execute(ToolRequest(id: ToolCallId("c-escape"),
      name: "read_file", argumentsJson: """{"path":"../outside"}"""))
    check not escaped.success
    check escaped.errorCode == toolPathDenied
    let secret = policy.execute(ToolRequest(id: ToolCallId("c-secret"),
      name: "read_file", argumentsJson: """{"path":".env"}"""))
    check not secret.success
    let extra = policy.execute(ToolRequest(id: ToolCallId("c-extra"),
      name: "read_file",
      argumentsJson: """{"path":"src/one.nim","extra":true}"""))
    check not extra.success
    check extra.errorCode == toolInvalidArguments
    let ranged = policy.execute(ToolRequest(id: ToolCallId("c-range"),
      name: "read_file",
      argumentsJson: """{"path":"src/one.nim","startLine":1,"endLine":1}"""))
    check ranged.success and not ranged.truncated
    check ranged.content == "1\tline one"
    var tight = policy
    tight.limits.maxReadLines = 1
    let capped = tight.execute(ToolRequest(id: ToolCallId("c-cap"),
      name: "read_file", argumentsJson: """{"path":"src/one.nim"}"""))
    check capped.success and capped.truncated
    when not defined(windows):
      writeFile(outside / "outside.txt", "not workspace data")
      createSymlink(outside, root / "linked")
      let symlinked = policy.execute(ToolRequest(id: ToolCallId("c-link"),
        name: "read_file",
        argumentsJson: """{"path":"linked/outside.txt"}"""))
      check not symlinked.success
      check symlinked.errorCode == toolPathDenied
      removeFile(root / "linked")

  test "image inspection trusts signatures and dimensions, not extensions":
    let root = temporaryRoot("image")
    defer:
      if dirExists(root): removeDir(root)
    createDir(root)
    var png = "\x89PNG\r\n\x1a\n" & repeat("\0", 16)
    png[16] = '\0'; png[17] = '\0'; png[18] = '\0'; png[19] = '\x02'
    png[20] = '\0'; png[21] = '\0'; png[22] = '\0'; png[23] = '\x03'
    writeFile(root / "not-really.txt", png)
    let inspected = inspectAttachment(root, "not-really.txt")
    check inspected.error.len == 0
    check inspected.attachment.mediaType == "image/png"
    check inspected.attachment.width == 2
    check inspected.attachment.height == 3
    let absolute = inspectAttachment(root, root / "not-really.txt")
    check absolute.error.len == 0
    check absolute.attachment.location == attachmentWorkspaceRelative
    check absolute.attachment.path == "not-really.txt"
    writeFile(root / "fake.png", "not an image")
    check inspectAttachment(root, "fake.png").error.len > 0

  test "missing historical images are omitted after session revalidation":
    let root = temporaryRoot("historical-image")
    defer:
      if dirExists(root): removeDir(root)
    createDir(root)
    var session = newSession(SessionId("s-historical-image"), root)
    session.messages = @[Message(id: MessageId("m-image"),
      turnId: TurnId("t-image"), role: messageUser,
      parts: @[imagePart(ImageReference(id: AttachmentId("a-missing"),
        path: "gone.png", location: attachmentWorkspaceRelative,
        displayName: "gone.png", mediaType: "image/png", sizeBytes: 24,
        width: 1, height: 1, state: attachmentSent))],
      status: messageComplete)]
    check session.refreshAttachmentReferences()
    check session.messages[0].parts[0].image.state == attachmentMissing
    let projected = projectRequest(session, ModelDescriptor(
      id: ModelId("vision"), available: true, contextWindow: 16_000,
      capabilities: supportedCapabilities(image = true)))
    check projected.error.len == 0
    check projected.notice.contains("historical image")

  test "Kitty image controls are bounded and contain no untrusted metadata":
    var capabilities = monochromeCapabilities()
    capabilities.kittyGraphics = true
    let request = imageRequest("owned\e]52", capabilities,
      mediaType = "image/png", widthCells = 10, heightCells = 4,
      maxBytes = 1024)
    let encoded = encodeKittyImage("png bytes", request, capabilities,
      7, 9, explicit = true, chunkBytes = 8)
    check encoded.accepted
    check encoded.controls.len > 1
    check "owned" notin encoded.controls.join("")
    check encoded.clearControl.contains("i=7")
    var placement: ImagePlacementState
    placement.place(7, 9, 10, 4)
    check placement.needsRedraw(0)
    placement.invalidate()
    check not placement.visible

  test "mock controller persists one complete streamed attempt":
    let root = temporaryRoot("controller")
    defer:
      if dirExists(root): removeDir(root)
    createDir(root)
    let paths = platformPaths(home = root, dataOverride = root / "data")
    let store = initSessionStore(paths)
    let provider = newMockProvider(script = @[
      MockStep(kind: mockStart), mockText("hello "), mockText("world"),
      MockStep(kind: mockComplete)])
    let session = newSession(SessionId("s-controller"), root,
      provider.id, provider.models[0].id, 1)
    let controller = initAgentController(session, store, provider,
      provider.models[0], proc (event: ControllerEvent) {.gcsafe.} =
      discard event)
    check controller.post ControllerCommand(kind: commandSubmit, text: "go")
    check controller.post ControllerCommand(kind: commandShutdown)
    controller.run()
    let loaded = store.load(SessionId("s-controller"))
    check loaded.error.len == 0
    check loaded.session.messages.len == 2
    if loaded.session.messages.len == 2:
      check loaded.session.messages[1].messageText == "hello world"
      check loaded.session.messages[1].status == messageComplete

  test "clear resets the transcript and context while preserving saved history":
    let root = temporaryRoot("clear")
    defer:
      if dirExists(root): removeDir(root)
    createDir(root)
    let store = initSessionStore(platformPaths(home = root,
      dataOverride = root / "data"))
    let provider = newMockProvider()
    let session = newSession(SessionId("s-clear"), root,
      provider.id, provider.models[0].id, 1)
    let chat = agentui.initAgentChat(sessionId = $session.id)
    defer: chat.close()
    var state = agentui.initAgentUiState()
    let controller = initAgentController(session, store, provider,
      provider.models[0], chat.tuiEventSink())
    defer: controller.commands.close()
    check controller.post ControllerCommand(kind: commandSubmit,
      text: "old conversation")
    let cleared = agentui.runShellCommand(chat, state, "/clear")
    check cleared.effect == agentui.seHostAction
    check cleared.actionKind == agentui.aaNewSession
    if cleared.effect == agentui.seHostAction and
        cleared.actionKind == agentui.aaNewSession:
      check controller.post ControllerCommand(kind: commandNewSession)
    check controller.post ControllerCommand(kind: commandSubmit,
      text: "fresh conversation")
    check controller.post ControllerCommand(kind: commandShutdown)
    controller.run()
    discard chat.drain()
    check chat.sessionId != $session.id
    check chat.items.len == 2
    for item in chat.items:
      check "old conversation" notin item.content
    check provider.requests.len == 2
    if provider.requests.len == 2:
      check provider.requests[1].messages.len == 1
      check provider.requests[1].messages[0].messageText == "fresh conversation"
    let previous = store.load(session.id)
    check previous.error.len == 0
    check previous.session.messages.len == 2
    let fresh = store.load(SessionId(chat.sessionId))
    check fresh.error.len == 0
    check fresh.session.messages.len == 2

  test "cancellation posted before worker start prevents provider I/O":
    let root = temporaryRoot("early-cancel")
    defer:
      if dirExists(root): removeDir(root)
    createDir(root)
    let store = initSessionStore(platformPaths(home = root,
      dataOverride = root / "data"))
    let provider = newMockProvider()
    let session = newSession(SessionId("s-cancel"), root,
      provider.id, provider.models[0].id, 1)
    let controller = initAgentController(session, store, provider,
      provider.models[0], proc (event: ControllerEvent) {.gcsafe.} =
      discard event)
    check controller.post ControllerCommand(kind: commandSubmit, text: "go")
    check controller.post ControllerCommand(kind: commandCancel)
    check controller.post ControllerCommand(kind: commandShutdown)
    controller.run()
    check provider.requests.len == 0
    let loaded = store.load(session.id)
    check loaded.error.len == 0
    check loaded.session.lastTurnState == turnIdle
    check loaded.session.messages.len == 1

  test "controller switches the provider adapter with the selected model":
    let root = temporaryRoot("provider-switch")
    defer:
      if dirExists(root): removeDir(root)
    createDir(root)
    let store = initSessionStore(platformPaths(home = root,
      dataOverride = root / "data"))
    let first = newMockProvider()
    let second = newMockProvider(script = @[mockText("from second"),
      MockStep(kind: mockComplete)])
    second.id = ProviderId("second")
    second.models[0].providerId = second.id
    second.models[0].id = ModelId("second-model")
    let session = newSession(SessionId("s-switch"), root,
      first.id, first.models[0].id, 1)
    let controller = initAgentController(session, store, first,
      first.models[0], proc (event: ControllerEvent) {.gcsafe.} =
      discard event)
    check controller.post ControllerCommand(kind: commandSelectModel,
      model: second.models[0], adapter: second, toolsEnabled: true,
      toolsConfigured: true)
    check controller.post ControllerCommand(kind: commandSubmit, text: "go")
    check controller.post ControllerCommand(kind: commandShutdown)
    controller.run()
    check first.requests.len == 0
    check second.requests.len == 1
    check store.load(session.id).session.modelId == ModelId("second-model")

  test "staged attachments survive a controller restart":
    let root = temporaryRoot("staged")
    defer:
      if dirExists(root): removeDir(root)
    createDir(root)
    var png = "\x89PNG\r\n\x1a\n" & repeat("\0", 16)
    png[19] = '\x01'
    png[23] = '\x01'
    writeFile(root / "image.png", png)
    let store = initSessionStore(platformPaths(home = root,
      dataOverride = root / "data"))
    let provider = newMockProvider()
    let session = newSession(SessionId("s-staged"), root,
      provider.id, provider.models[0].id, 1)
    let controller = initAgentController(session, store, provider,
      provider.models[0], proc (event: ControllerEvent) {.gcsafe.} =
      discard event)
    check controller.post ControllerCommand(kind: commandAttach,
      text: "image.png")
    check controller.post ControllerCommand(kind: commandShutdown)
    controller.run()
    let loaded = store.load(session.id)
    check loaded.error.len == 0
    check loaded.session.stagedAttachments.len == 1
    check loaded.session.stagedAttachments[0].state == attachmentReady

  test "archiving the active session does not recreate its active file":
    let root = temporaryRoot("archive-controller")
    defer:
      if dirExists(root): removeDir(root)
    createDir(root)
    let store = initSessionStore(platformPaths(home = root,
      dataOverride = root / "data"))
    let provider = newMockProvider()
    let session = newSession(SessionId("s-archive"), root,
      provider.id, provider.models[0].id, 1)
    check store.save(session).len == 0
    let controller = initAgentController(session, store, provider,
      provider.models[0], proc (event: ControllerEvent) {.gcsafe.} =
      discard event)
    check controller.post ControllerCommand(kind: commandArchive,
      sessionId: session.id)
    check controller.post ControllerCommand(kind: commandShutdown)
    controller.run()
    check store.load(session.id).error.len > 0
    check store.load(session.id, archived = true).error.len == 0
    let active = store.list(root)
    check active.sessions.len == 1
    check active.sessions[0].id != session.id

  test "mock tool loop lists, persists the result, and answers":
    let root = temporaryRoot("tool-controller")
    defer:
      if dirExists(root): removeDir(root)
    createDir(root)
    writeFile(root / "answer.txt", "the answer is 42\n")
    let store = initSessionStore(platformPaths(home = root,
      dataOverride = root / "data"))
    let provider = newMockProvider(scripts = @[
      @[MockStep(kind: mockStart),
        mockCall("call-list", "list_directory", """{"path":"."}"""),
        MockStep(kind: mockComplete)],
      @[MockStep(kind: mockStart), mockText("I found answer.txt."),
        MockStep(kind: mockComplete)]])
    let session = newSession(SessionId("s-tools"), root,
      provider.id, provider.models[0].id, 1)
    let controller = initAgentController(session, store, provider,
      provider.models[0], proc (event: ControllerEvent) {.gcsafe.} =
      discard event)
    check controller.post ControllerCommand(kind: commandSubmit,
      text: "What files are here?")
    check controller.post ControllerCommand(kind: commandShutdown)
    controller.run()
    let loaded = store.load(SessionId("s-tools"))
    check loaded.error.len == 0
    check loaded.session.messages.len == 4
    if loaded.session.messages.len == 4:
      check loaded.session.messages[1].parts[0].kind == contentToolCall
      check loaded.session.messages[2].role == messageTool
      check loaded.session.messages[2].messageText.len == 0
      check loaded.session.messages[2].parts[0].toolResult.content
        .contains("answer.txt")
      check loaded.session.messages[3].messageText == "I found answer.txt."

echo "phase1 agent ok"
