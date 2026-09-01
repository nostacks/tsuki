## End-to-end transport-neutral agent shell demo. The mock worker runs on its
## own thread like a real host, posts small typed bursts with staged delays,
## and pauses at the approval gate until the user decides. A second worker
## streams an independent background task while foreground prompts can queue.

import std/[monotimes, os, strutils, times]
import std/typedthreads
import tsuki/tui/agent

type
  CmdKind = enum
    ckSubmit
    ckApproval
    ckCancel
    ckQuit

  Cmd = object
    case kind: CmdKind
    of ckSubmit:
      prompt: string
    of ckApproval:
      decision: ApprovalDecision
    else:
      discard

  Shared = object
    ## All state crossing the thread boundary lives behind one pointer.
    chat: AgentChat
    cmds: Channel[Cmd]
    backgroundStop: Channel[bool]
    turnNumber: int
    activeTurn: string
    interrupted: bool
    quitRequested: bool
    waitingApproval: bool

var shared: ptr Shared

proc stage(ms: int): bool {.gcsafe.} =
  ## Sleeps in short slices so cancel and shutdown stay responsive. Returns
  ## false when the stage was interrupted.
  let deadline = getMonoTime() + initDuration(milliseconds = ms)
  result = true
  while getMonoTime() < deadline:
    sleep(min(30, ms))
    while true:
      let (available, cmd) = shared[].cmds.tryRecv()
      if not available: break
      case cmd.kind
      of ckCancel:
        shared[].interrupted = true
      of ckQuit:
        shared[].quitRequested = true
      of ckSubmit, ckApproval:
        discard
    if shared[].interrupted or shared[].quitRequested:
      return false

proc backgroundStage(ms: int): bool {.gcsafe.} =
  ## Waits without sharing mutable foreground flags. The dedicated stop
  ## channel makes shutdown deterministic even while the job is sleeping.
  let deadline = getMonoTime() + initDuration(milliseconds = ms)
  while getMonoTime() < deadline:
    let (available, stop) = shared[].backgroundStop.tryRecv()
    if available and stop: return false
    sleep(min(30, ms))
  true

func workflowPlan(stage: range[0..3]): seq[PlanItem] =
  @[
    PlanItem(id: "inspect", text: "Inspect the relevant code",
      state: if stage == 0: planActive else: planComplete),
    PlanItem(id: "edit", text: "Apply the requested change",
      state: if stage < 1: planPending
        elif stage == 1: planActive else: planComplete),
    PlanItem(id: "verify", text: "Run focused verification",
      state: if stage < 2: planPending
        elif stage == 2: planActive else: planComplete)]

func failedPlan: seq[PlanItem] =
  @[
    PlanItem(id: "inspect", text: "Inspect the relevant code",
      state: planComplete),
    PlanItem(id: "edit", text: "Apply the requested change",
      state: planFailed),
    PlanItem(id: "verify", text: "Run focused verification",
      state: planPending)]

proc cancelTurn(turn: string) {.gcsafe.} =
  discard shared[].chat.post turnCancelled(turn)
  discard shared[].chat.post planUpdated(failedPlan())
  discard shared[].chat.post notice(turn & ":cancelled",
    "The active turn was cancelled. Partial output remains visible.")
  discard shared[].chat.post turnFinished(turn)

proc streamThinking(turn, text: string, delayMs: int): bool {.gcsafe.} =
  var chunk = ""
  for word in text.split(' '):
    if shared[].quitRequested: return false
    chunk.add word & " "
    if chunk.len >= 18:
      discard shared[].chat.post thinkingDelta(turn, chunk)
      chunk.setLen 0
      if not stage(delayMs):
        return false
  if chunk.len > 0: discard shared[].chat.post thinkingDelta(turn, chunk)
  true

proc streamMessage(turn, text: string, delayMs: int): bool {.gcsafe.} =
  var chunk = ""
  for word in text.split(' '):
    if shared[].quitRequested: return false
    chunk.add word & " "
    if chunk.len >= 28:
      discard shared[].chat.post messageDelta(turn, chunk)
      chunk.setLen 0
      if not stage(delayMs):
        return false
  if chunk.len > 0: discard shared[].chat.post messageDelta(turn, chunk)
  true

proc runTurn(prompt: string) {.gcsafe.} =
  inc shared[].turnNumber
  let turn = "turn-" & $shared[].turnNumber
  shared[].activeTurn = turn
  shared[].interrupted = false
  shared[].waitingApproval = false
  discard shared[].chat.post userMessage(turn & ":user", prompt)
  if not stage(300):
    if not shared[].quitRequested: cancelTurn(turn)
    return
  if not streamThinking(turn, "I'll inspect the greeting code, propose " &
      "one bounded edit, and verify it compiles.", 160):
    if not shared[].quitRequested: cancelTurn(turn)
    return
  discard shared[].chat.post planUpdated(workflowPlan(0))
  discard shared[].chat.post toolStarted(turn & ":read", "Read",
    "src/tsuki.nim", turn)
  # Chunks carry their own newlines: adjacent output events coalesce
  # losslessly, exactly like a real tool stream.
  for chunk in ["proc greet*(): string =\n", "  \"Hello, World!\"\n"]:
    if shared[].quitRequested: return
    discard shared[].chat.post toolOutput(turn & ":read", chunk)
    if not stage(220):
      if not shared[].quitRequested: cancelTurn(turn)
      return
  discard shared[].chat.post toolFinished(turn & ":read")
  discard shared[].chat.post planUpdated(workflowPlan(1))
  if not streamMessage(turn, "I found the function. The change is small " &
      "and isolated. Before writing, Tsuki asks the host for explicit " &
      "approval of the patch.", 90):
    if not shared[].quitRequested: cancelTurn(turn)
    return
  discard shared[].chat.post approvalRequested(turn & ":write",
    "apply a patch to src/tsuki.nim", risk = riskWrite,
    paths = @["src/tsuki.nim"],
    explanation = "Replace the greeting while preserving the public API.")
  shared[].waitingApproval = true
  # The worker pauses here; the reactor owns the next command.

proc finishApprovedTurn(decision: ApprovalDecision) {.gcsafe.} =
  let turn = shared[].activeTurn
  shared[].waitingApproval = false
  discard shared[].chat.post notice(turn & ":decision",
    if decision == approvalAlways: "Write approved for this policy scope."
    else: "Write approved once by the host.")
  discard shared[].chat.post toolStarted(turn & ":patch", "Apply patch",
    "src/tsuki.nim", turn)
  for chunk in ["--- a/src/tsuki.nim\n", "+++ b/src/tsuki.nim\n",
      "-  result = \"Hello, World!\"\n", "+  result = \"Hello from Tsuki!\"\n"]:
    if shared[].quitRequested: return
    discard shared[].chat.post toolOutput(turn & ":patch", chunk,
      language = "diff")
    discard stage(160)
  discard shared[].chat.post toolFinished(turn & ":patch")
  discard shared[].chat.post planUpdated(workflowPlan(2))
  discard shared[].chat.post toolStarted(turn & ":test", "Test",
    "nimble test", turn)
  for chunk in ["[OK] greet\n", "All focused checks passed.\n"]:
    if shared[].quitRequested: return
    discard shared[].chat.post toolOutput(turn & ":test", chunk)
    discard stage(200)
  discard shared[].chat.post toolFinished(turn & ":test")
  discard shared[].chat.post planUpdated(workflowPlan(3))
  # The final response is its own item so it appends after the tool work.
  discard streamMessage(turn & ":reply", "## Completed\n\nThe edit was " &
    "applied and verified. This demo used typed events for planning, " &
    "tools, approval, output, usage, and the final response, without " &
    "coupling the TUI to any model API.", 110)
  discard shared[].chat.post citationsUpdated(turn & ":reply", @[
    Citation(id: "nim", label: "Nim manual",
      uri: "https://nim-lang.org/docs/manual.html")])
  discard shared[].chat.post turnFinished(turn,
    Usage(inputTokens: 420, outputTokens: 180, cachedTokens: 96))

proc rejectTurn(decision: ApprovalDecision) {.gcsafe.} =
  let turn = shared[].activeTurn
  shared[].waitingApproval = false
  discard shared[].chat.post notice(turn & ":decision",
    if decision == approvalEdit:
      "The host chose to edit the request. No write was performed."
    else:
      "The host rejected the write. No files were changed.")
  discard shared[].chat.post planUpdated(failedPlan())
  discard shared[].chat.post messageDelta(turn,
    if decision == approvalEdit: "\n\nThe request needs a narrower scope. " &
      "Edit it and submit again."
    else: "\n\nNo files were changed. Submit a different request anytime.")
  discard shared[].chat.post turnFinished(turn)

proc workerMain() {.thread.} =
  while true:
    if shared[].quitRequested: return
    let cmd = shared[].cmds.recv()
    case cmd.kind
    of ckQuit:
      return
    of ckSubmit:
      runTurn(cmd.prompt)
    of ckApproval:
      if cmd.decision in {approvalOnce, approvalAlways}:
        finishApprovedTurn(cmd.decision)
      else:
        rejectTurn(cmd.decision)
    of ckCancel:
      if shared[].waitingApproval:
        rejectTurn(approvalReject)
      elif shared[].activeTurn.len > 0:
        cancelTurn(shared[].activeTurn)

proc backgroundMain() {.thread.} =
  ## A real concurrent producer: it never changes foreground activity, but its
  ## typed tool lifecycle and streamed output appear in the same transcript.
  const task = "background:index"
  discard shared[].chat.post toolStarted(task, "Index workspace",
    "scanning source files", background = true)
  for chunk in ["Found 18 Nim modules\n", "Indexed 3 public examples\n",
      "Workspace index ready\n"]:
    if not backgroundStage(650):
      return
    discard shared[].chat.post toolOutput(task, chunk)
  discard shared[].chat.post toolFinished(task)

proc handleAction(action: AgentAction) =
  case action.kind
  of aaSubmit:
    discard shared[].cmds.trySend Cmd(kind: ckSubmit, prompt: action.prompt)
  of aaApproval:
    discard shared[].cmds.trySend Cmd(kind: ckApproval,
      decision: action.decision)
  of aaCancel:
    discard shared[].cmds.trySend Cmd(kind: ckCancel)
  of aaCopy, aaRetry:
    discard

var
  worker: Thread[void]
  backgroundWorker: Thread[void]

shared = cast[ptr Shared](allocShared0(sizeof(Shared)))
shared[].chat = initAgentChat("Tsuki · agent chat",
  sessionId = "example")
shared[].cmds.open(16)
shared[].backgroundStop.open(1)
createThread(worker, workerMain)

discard shared[].chat.post notice("welcome",
  "月  tsuki\n" &
  "   a fast, tiny coding agent\n\n" &
  "Type a request. Send another while it runs to queue it.\n" &
  "Workspace indexing runs in the background. /help lists commands.",
  banner = true)
discard shared[].chat.post rateLimitUpdated(RateLimit(remaining: 19,
  limit: 20))
createThread(backgroundWorker, backgroundMain)

let options = agentTuiOptions(status = AgentStatus(
  model: "mock-tsuki", mode: "agent", message: "local demo",
  contextUsed: 600, contextLimit: 16_000))

let stats = runAgentTui(shared[].chat, handleAction, options)

# Deterministic shutdown: stop the worker before releasing shared state so no
# burst is ever posted into a destroyed session.
shared[].cmds.send Cmd(kind: ckQuit)
shared[].backgroundStop.send true
joinThreads(worker, backgroundWorker)
shared[].cmds.close()
shared[].backgroundStop.close()
deallocShared(cast[pointer](shared))
shared = nil

if not stats.ok:
  quit(1)
