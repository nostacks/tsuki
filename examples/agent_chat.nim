## End-to-end agent shell using Tsuki's public mock adapter and controller.

import std/os
import std/typedthreads
import tsuki/agent
import he3/agent

type Shared = object
  controller: AgentController

var shared: ptr Shared

proc controllerMain() {.thread.} =
  shared[].controller.run()

let workspace = getCurrentDir()
let provider = newMockProvider(script = @[
  MockStep(kind: mockStart),
  mockSummary("I will answer through the real controller. "),
  mockText("## Mock response\n\nThe prompt streamed through Tsuki's " &
    "provider-neutral adapter, canonical session, and durable controller."),
  MockStep(kind: mockComplete)])
let model = provider.models[0]
let paths = platformPaths(dataOverride = getTempDir() /
  ("tsuki-agent-example-" & $getCurrentProcessId()))
let store = initSessionStore(paths)
let session = newSession(generateSessionId(), workspace, provider.id, model.id)
let chat = initAgentChat("Tsuki · agent chat", $session.id)
chat.apply notice("welcome", "月  tsuki\n    public mock adapter demo\n\n" &
  "Type a request. /help lists durable-session commands.", banner = true)

let controller = initAgentController(session, store, provider, model,
  chat.tuiEventSink())
shared = cast[ptr Shared](allocShared0(sizeof(Shared)))
shared[].controller = controller
var worker: Thread[void]
createThread(worker, controllerMain)

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
  of aaAttach:
    discard controller.post ControllerCommand(kind: commandAttach,
      text: parseAttachArgument("/attach " & action.argument))
  of aaDetach:
    discard controller.post ControllerCommand(kind: commandDetach,
      text: action.argument)
  of aaRenameSession:
    discard controller.post ControllerCommand(kind: commandRename,
      text: action.argument)
  of aaResumeSession:
    discard controller.post ControllerCommand(kind: commandSwitchSession,
      sessionId: SessionId(action.argument.safeId()))
  of aaArchiveSession:
    discard controller.post ControllerCommand(kind: commandArchive,
      sessionId: SessionId(action.argument.safeId()))
  of aaModelSelector, aaProviderSelector:
    discard controller.post ControllerCommand(kind: commandSelectModel,
      model: model)
  of aaApiKey:
    discard chat.post notice("api-key", "The public mock example does not " &
      "store provider keys. Use the tsuki executable for /provider.")
  of aaSessions:
    discard chat.post notice("sessions", "Use the tsuki executable to browse " &
      "persistent workspace sessions.")
  of aaLogin, aaLogout:
    discard chat.post notice("authentication", "The public mock example does " &
      "not connect to an account. Use the tsuki executable for /provider.")
  of aaSetMode:
    discard controller.post ControllerCommand(kind: commandSetMode,
      mode: if action.argument == "chat": modeChat else: modeAgent)
  of aaApproval, aaCopy:
    discard

let options = agentTuiOptions(status = AgentStatus(provider: "mock",
  directory: workspace,
  model: $model.id, mode: "agent", message: "offline demo"),
  selectorEntries = @[SelectorEntry(providerId: "mock", providerName: "Mock",
    modelId: $model.id, displayName: model.displayName,
    imageInput: selectorSupported, tools: selectorSupported,
    available: true)])
let result = runAgentTui(chat, handleAction, options)

controller.shutdown()
joinThread(worker)
controller.commands.close()
chat.close()
deallocShared(cast[pointer](shared))
shared = nil

if not result.ok:
  stderr.writeLine(result.error)
  quit(1)
