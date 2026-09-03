import std/[json, os, strutils, unittest]
import tsuki/agent

proc reply(node: JsonNode) =
  stdout.writeLine($node)
  stdout.flushFile()

proc fakeAppServer() =
  var line: string
  while stdin.readLine(line):
    if line.strip.len == 0: continue
    let request = parseJson(line)
    let methodName = request{"method"}.getStr
    let id = request{"id"}.getInt(-1)
    case methodName
    of "initialize":
      reply(%*{"id": id, "result": {"serverInfo": {
        "name": "fake-codex", "version": "1"}}})
    of "initialized":
      discard
    of "account/read":
      reply(%*{"id": id, "result": {"account": {"type": "chatgpt",
        "email": "fixture@example.com", "planType": "plus"},
        "requiresOpenaiAuth": true}})
    of "model/list":
      if request{"params"}{"cursor"}.getStr.len == 0:
        reply(%*{"id": id, "result": {"data": [
          {"id": "codex-one", "displayName": "Codex One",
            "inputModalities": ["text", "image"], "isDefault": true},
          {"id": "codex-two", "displayName": "Codex Two",
            "inputModalities": ["text"]}], "nextCursor": "page-two"}})
      else:
        reply(%*{"id": id, "result": {"data": [
          {"id": "codex-three", "displayName": "Codex Three",
            "inputModalities": ["text"]}], "nextCursor": nil}})
    of "account/login/start":
      reply(%*{"id": id, "result": {"type": "chatgptDeviceCode",
        "loginId": "login-fixture",
        "verificationUrl": "https://auth.openai.com/codex/device",
        "userCode": "ABCD-1234"}})
      reply(%*{"method": "account/login/completed", "params": {
        "loginId": "login-fixture", "success": true, "error": nil}})
    of "account/login/cancel":
      reply(%*{"id": id, "result": {}})
    of "account/logout":
      reply(%*{"id": id, "result": {}})
    of "thread/start":
      let params = request{"params"}
      if params{"approvalPolicy"}.getStr != "never" or
          params{"sandbox"}.getStr != "read-only" or
          not params{"ephemeral"}.getBool(false) or
          params{"developerInstructions"}.getStr.len == 0 or
          params{"config"}{"web_search"}.getStr != "disabled" or
          params{"config"}{"features.plugins"}.getBool(true):
        reply(%*{"id": id, "error": {"code": -32602,
          "message": "unsafe thread settings"}})
      else:
        reply(%*{"id": id,
          "result": {"thread": {"id": "thr-fixture"}}})
    of "turn/start":
      let params = request{"params"}
      if params{"approvalPolicy"}.getStr != "never" or
          params{"sandboxPolicy"}{"type"}.getStr != "readOnly" or
          params{"sandboxPolicy"}{"networkAccess"}.getBool(true):
        reply(%*{"id": id, "error": {"code": -32602,
          "message": "unsafe turn settings"}})
        continue
      reply(%*{"id": id, "result": {"turn": {"id": "turn-fixture",
        "status": "inProgress", "items": []}}})
      reply(%*{"method": "item/reasoning/summaryTextDelta", "params": {
        "threadId": "thr-fixture", "turnId": "turn-fixture",
        "delta": "checking "}})
      reply(%*{"method": "item/agentMessage/delta", "params": {
        "threadId": "thr-fixture", "turnId": "turn-fixture",
        "delta": "hello from Codex"}})
      reply(%*{"method": "turn/completed", "params": {
        "threadId": "thr-fixture", "turn": {
          "id": "turn-fixture", "status": "completed", "error": nil}}})
    of "turn/interrupt":
      reply(%*{"id": id, "result": {}})
    else:
      if id >= 0:
        reply(%*{"id": id, "error": {"code": -32601,
          "message": "method not found"}})

proc runTests() =
  let adapter = newCodexAppServerProvider(executable = getAppFilename())

  suite "local Codex App Server adapter":
    test "discovers every paginated provider model":
      let discovered = adapter.refreshModels(initCancellationToken())
      check discovered.error.ok
      check discovered.models.len == 3
      if discovered.models.len == 3:
        check discovered.models[0].displayName == "Codex One"
        check discovered.models[0].capabilities.imageInput ==
          capabilitySupported
        check discovered.models[0].capabilities.tools ==
          capabilityUnsupported

    test "delegates ChatGPT device login without receiving credentials":
      var url, code: string
      var completed = false
      let failure = adapter.loginChatGpt(initCancellationToken(),
        proc (event: ProviderAuthEvent): bool {.gcsafe.} =
        case event.kind
        of providerAuthPrompt:
          url = event.verificationUrl
          code = event.userCode
        of providerAuthComplete:
          completed = true
        true)
      check failure.ok
      check url == "https://auth.openai.com/codex/device"
      check code == "ABCD-1234"
      check completed

    test "streams normalized deltas from an ephemeral read-only turn":
      let model = ModelDescriptor(providerId: adapter.id,
        id: ModelId("codex-one"), displayName: "Codex One",
        capabilities: supportedCapabilities(image = true), available: true,
        provenance: provenanceDiscovered)
      let request = ProviderRequest(providerId: adapter.id, model: model,
        workspaceRoot: getCurrentDir(),
        messages: @[Message(role: messageUser,
          parts: @[textPart("hello")], status: messageComplete)])
      var summary, answer: string
      var completed = false
      let failure = adapter.stream(request, initCancellationToken(),
        proc (event: ProviderEvent): bool {.gcsafe.} =
        case event.kind
        of providerVisibleSummaryDelta: summary.add event.text
        of providerTextDelta: answer.add event.text
        of providerCompleted: completed = true
        else: discard
        true)
      check failure.ok
      check summary == "checking "
      check answer == "hello from Codex"
      check completed

    test "logs out through the managed account endpoint":
      check adapter.logout(initCancellationToken()).ok

when isMainModule:
  if commandLineParams() == @["app-server"]:
    fakeAppServer()
  else:
    runTests()
