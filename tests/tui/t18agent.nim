import std/[monotimes, sequtils, strutils, times, unicode]
import common
import tsuki/tui
import tsuki/tui/agent
import tsuki/tui/protocols/[clipboard, hyperlink, image, syncoutput]

proc testStreamingMarkdown =
  let source = "# Heading\n- [x] safe\n**bold** and `code` 😀\n```nim\necho 1\n```"
  let expected = parseMarkdown(source)
  var streamed = initMarkdownState()
  for byteIndex in 0 ..< source.len:
    streamed.feed(source[byteIndex .. byteIndex])
  let actual = streamed.finish()
  check actual.lines == expected.lines,
    "arbitrary markdown chunk boundaries equal one-shot parsing"
  var crlf = initMarkdownState()
  for chunk in ["one\r", "\ntwo\rthree"]: crlf.feed(chunk)
  check crlf.finish().lines == parseMarkdown("one\r\ntwo\rthree").lines,
    "streaming markdown normalizes split CRLF consistently"

proc testAgentModel =
  let chat = initAgentChat(maxQueued = 4, maxToolOutputBytes = 1024)
  check chat.post(messageDelta("turn", "hel")), "first delta posts"
  check chat.post(messageDelta("turn", "lo")), "adjacent delta coalesces"
  check chat.drain() == 1, "coalesced delta drains once"
  check chat.items.len == 1 and chat.items[0].content == "hello",
    "streaming content applies by stable id"
  chat.apply toolStarted("tool", "Shell")
  chat.apply toolOutput("tool", "\e]52;c;owned\a")
  check '\e' notin chat.items[^1].content and '\a' notin chat.items[^1].content,
    "tool output is sanitized before durable storage"
  chat.apply toolFinished("tool")
  check chat.items[^1].status == toolSuccess, "tool lifecycle completes"

  chat.apply toolStarted("t2", "Read", "src/tsuki.nim")
  check chat.items[^1].detail == "src/tsuki.nim" and
    chat.items[^1].content.len == 0,
    "tool detail is stored separately from streamed output"
  chat.apply toolOutput("t2", "proc greet*()")
  chat.apply toolOutput("t2", "  = \"hi\"")
  check chat.items[^1].content == "proc greet*()  = \"hi\"",
    "tool output chunks append without an inserted boundary"
  chat.apply toolStarted("t3", "Apply patch")
  chat.apply toolOutput("t3", "--- a/x", language = "diff")
  check chat.items[^1].language == "diff",
    "a language-tagged first chunk selects specialized rendering"
  chat.apply citationsUpdated("turn", @[
    Citation(id: "one", label: "Source", uri: "https://example.com"),
    Citation(id: "bad", label: "Unsafe", uri: "javascript:alert(1)")])
  check chat.items[0].citations.len == 1,
    "only safe citation schemes reach transcript metadata"
  chat.apply rateLimitUpdated(RateLimit(remaining: 4, limit: 10))
  check chat.rateLimit.remaining == 4, "rate-limit state remains transport neutral"

  let bounded = initAgentChat(maxQueued = 10, maxQueuedBytes = 1024)
  check not bounded.post(messageDelta("large", repeat("x", 2048))),
    "the typed event queue rejects a single payload beyond its byte bound"

  let wake = initReactor()
  let batched = initAgentChat(maxQueued = 10)
  batched.attach(wake)
  for index in 0 ..< 5:
    check batched.post(notice("n" & $index, "event")),
      "bounded batch fixture posts"
  var wakeEvent: Event
  check wake.popPosted(wakeEvent), "the first agent batch wakes the reactor"
  check batched.drain(2) == 2 and batched.pendingCount == 3,
    "a custom queue can drain a partial batch"
  check wake.popPosted(wakeEvent) and wakeEvent.name == "tsuki.agent",
    "a partial drain rearms the reactor for remaining agent events"
  batched.close()
  wake.close()

  let activity = initAgentChat()
  activity.apply userMessage("active", "go")
  check activity.active and not activity.cancelled,
    "a user turn becomes active before the first model delta"
  activity.apply turnFinished("active")
  activity.apply toolStarted("tool-only", "Read")
  check activity.active, "a tool-only turn still reports active work"

  let backgroundChat = initAgentChat()
  backgroundChat.apply toolStarted("bg:index", "Index workspace",
    background = true)
  check not backgroundChat.active and backgroundChat.items[^1].background,
    "a background tool is durable without taking foreground activity"
  backgroundChat.apply userMessage("foreground", "keep working")
  backgroundChat.apply toolStarted("foreground:read", "Read")
  backgroundChat.apply toolStarted("bg:refresh", "Refresh index",
    background = true)
  check backgroundChat.agentActivity == activityRunning,
    "a newer background task does not replace foreground activity"

proc testTranscriptAndApproval =
  let chat = initAgentChat()
  for index in 0 ..< 2000:
    chat.apply messageDelta("turn-" & $index, "message " & $index)
  var harness = initHeadlessTui(60, 12)
  var transcriptState: TranscriptState
  transcriptState.scroll.anchor = anchorEnd
  harness.draw proc (frame: var Frame) =
    frame.transcript(chat, transcriptState)
  let firstSnapshot = harness.snapshot
  let before = getMonoTime()
  harness.draw proc (frame: var Frame) =
    frame.transcript(chat, transcriptState)
  check harness.snapshot == firstSnapshot, "warm transcript render is stable"
  check (getMonoTime() - before).inMilliseconds < 100,
    "warm transcript render remains bounded"

  let request = ApprovalRequest(id: "a", command: "nimble test")
  var approvalState: ApprovalState
  let enter = Event(kind: evKey, key: initKey(kcEnter))
  check approvalState.approvalEvent(request, enter) == approvalNone,
    "first Enter only arms approval"
  check approvalState.approvalEvent(request, enter) == approvalReject,
    "second Enter confirms the deliberately selected safe default"

proc testExplicitProtocols =
  var caps = monochromeCapabilities()
  let link = encodeHyperlink(Hyperlink(uri: "https://example.com"), "site", caps)
  check not link.supported and link.fallback == "site",
    "unsupported hyperlinks use safe text fallback"
  caps.clipboard = true
  check not encodeClipboardWrite("secret", caps).accepted,
    "clipboard requires explicit opt-in"
  check encodeClipboardWrite("safe", caps, explicitlyAllowed = true).accepted,
    "explicit bounded clipboard request can be encoded"
  check imageRequest("preview", caps).protocol == imageCells,
    "image adapters retain a cell fallback"
  check beginSynchronizedOutput(caps).len == 0 and
    endSynchronizedOutput(caps).len == 0,
    "unsupported synchronized output emits no controls"

  let modern = detectCapabilities(TerminalIdentity(term: "xterm-256color",
    colorTerm: "truecolor", program: "ghostty"), noColor = false,
    unicodeLocale = true)
  check modern.colorDepth == colorTrue and modern.kittyGraphics and
    modern.synchronizedOutput,
    "terminal identity hints resolve a modern capability profile"
  check imageRequest("preview", modern).protocol == imageKitty,
    "advertised image capability selects its modular adapter"
  check beginSynchronizedOutput(modern) == "\e[?2026h" and
    endSynchronizedOutput(modern) == "\e[?2026l",
    "synchronized output markers remain exactly paired"

template drawShell(harness: var HeadlessTui, chat: AgentChat,
    state: var AgentUiState, options = agentTuiOptions()): string =
  harness.draw proc (frame: var Frame) =
    frame.drawAgentShell(chat, state, options)
  harness.snapshot()

func shellRows(snapshot: string): seq[string] =
  snapshot.split('\n')

template narrowApproval(harness: var HeadlessTui, chat: AgentChat,
    state: var AgentUiState, options: AgentTuiOptions) =
  chat.apply approvalRequested("t1:write", "apply a patch",
    risk = riskWrite, paths = @["src/tsuki.nim"])
  let snap = drawShell(harness, chat, state, options)
  check snap.contains("[Reject]"),
    "approval controls appear even on narrow terminals"

proc seededShellChat: AgentChat =
  result = initAgentChat()
  result.apply userMessage("t1:user", "update the greeting and verify it")
  result.apply thinkingDelta("t1",
    "I'll inspect the code, make one bounded edit, and verify it.")
  result.apply planUpdated(@[
    PlanItem(id: "inspect", text: "inspect", state: planComplete),
    PlanItem(id: "edit", text: "edit", state: planActive),
    PlanItem(id: "verify", text: "verify", state: planPending)])
  result.apply toolStarted("t1:read", "Read", "src/tsuki.nim", "t1")
  result.apply toolOutput("t1:read", "proc greet*(): string =")
  result.apply toolFinished("t1:read")
  result.apply messageDelta("t1", "I found the function.")
  result.apply turnFinished("t1")

proc testAgentShell =
  let options = agentTuiOptions(status = AgentStatus(
    model: "mock-tsuki", mode: "agent", contextUsed: 600,
    contextLimit: 16_000))

  block layout80x24:
    let chat = seededShellChat()
    var harness = initHeadlessTui(80, 24)
    var state = initAgentUiState()
    state.transcript.scroll.anchor = anchorEnd
    let snap = harness.drawShell(chat, state, options)
    let rows = snap.shellRows
    check rows[19].startsWith("  esc quit"),
      "the activity/help row sits in stable bottom chrome"
    check rows[20].len == 0,
      "a blank row separates the activity line from the composer"
    check rows[21].contains("▌") and not rows[22].contains("▌"),
      "the composer is a single quiet row for a short draft"
    check runeLen(rows[22]) == 80 and rows[22].startsWith(
        "────────────────"),
      "one subdued divider separates composer and status"
    check rows[23].startsWith(" ") and rows[23].contains("agent"),
      "the status line is compact and inset"
    check rows[17].contains("plan") and rows[17].contains("inspect") and
      rows[17].contains("verify"),
      "a three-step plan remains visible at 80 columns"
    check rows[18].len == 0,
      "a blank row separates the activity line from content above"
    var userCueColumn = -1
    for row in rows[0 ..< 17]:
      let column = row.find("›")
      if column >= 0: userCueColumn = column
    check userCueColumn == 2,
      "the transcript is inset two cells from the leading edge"
    let grown = agentShellLayout(80, 24, chat, options, draftRows = 3)
    check grown.composer.height == 3 and grown.composer.y == 19,
      "the composer grows for multiline drafts and the divider stays put"

  block narrow40x12:
    let chat = seededShellChat()
    var harness = initHeadlessTui(40, 12)
    var state = initAgentUiState()
    state.transcript.scroll.anchor = anchorEnd
    let snap = harness.drawShell(chat, state, options)
    let rows = snap.shellRows
    check rows.len == 12, "the narrow shell fills exactly its rows"
    check rows[7].contains("esc quit"),
      "quit guidance survives narrow widths"
    check runeLen(rows[^2]) == 40 and rows[^1].contains("agent"),
      "divider and status stay in stable bottom rows"
    narrowApproval(harness, chat, state, options)

  block slashCommands:
    let chat = initAgentChat()
    var state = initAgentUiState()
    let enter = Event(kind: evKey, key: initKey(kcEnter))
    state.prompt.editor.content = "/help"
    state.prompt.editor.cursor = 5
    let helped = handleShellEvent(chat, state, enter)
    check helped.effect == seNone and helped.changed,
      "slash commands are handled without reaching the host"
    check chat.items[^1].content.contains("/clear"),
      "/help lists the built-in commands"
    chat.apply userMessage("t:user", "draft work")
    state.prompt.editor.content = "/clear"
    state.prompt.editor.cursor = 6
    discard handleShellEvent(chat, state, enter)
    check chat.items.len == 0, "/clear empties the transcript"
    state.prompt.editor.content = "/quit"
    state.prompt.editor.cursor = 5
    check handleShellEvent(chat, state, enter).effect == seQuit,
      "/quit exits the shell"
    state.prompt.editor.content = "/frobnicate"
    state.prompt.editor.cursor = 11
    discard handleShellEvent(chat, state, enter)
    check chat.items[^1].content.contains("Unknown command"),
      "unknown commands report instead of submitting"
    chat.active = false
    state.prompt.editor.content = "just a prompt"
    state.prompt.editor.cursor = 13
    check handleShellEvent(chat, state, enter).effect == seSubmit,
      "plain prompts still submit to the host"

    chat.active = true
    state.prompt.editor.content = "follow-up"
    state.prompt.editor.cursor = 9
    check handleShellEvent(chat, state, enter).effect == seNone,
      "prompts entered during an active turn are queued locally"
    check state.prompt.pendingPromptCount == 1,
      "the pending prompt count is visible to shell presentation"
    var queueHarness = initHeadlessTui(80, 24)
    let queuedFrame = queueHarness.drawShell(chat, state, options)
    check queuedFrame.contains("1 prompt queued"),
      "the activity line acknowledges a queued prompt"
    var queued: string
    check state.prompt.popQueued(queued) and queued == "follow-up",
      "queued prompts preserve their text for the next turn"
    check state.prompt.pendingPromptCount == 0,
      "dispatch removes the prompt from the visible queue count"

  block slashCompletion:
    var state = initAgentUiState()
    let chat = initAgentChat()
    state.prompt.editor.content = "/c"
    state.prompt.editor.cursor = 2
    check state.prompt.nextCompletion == "/clear",
      "typing filters completion candidates"
    discard handleShellEvent(chat, state,
      Event(kind: evKey, key: initKey(kcTab)))
    check state.prompt.editor.content == "/clear " and
      state.prompt.editor.cursor == 7,
      "Tab completes the slash command in place"

  block wide120x32:
    let chat = seededShellChat()
    var harness = initHeadlessTui(120, 32)
    var state = initAgentUiState()
    state.transcript.scroll.anchor = anchorEnd
    discard harness.drawShell(chat, state, options)
    let layout = agentShellLayout(120, 32, chat, options)
    check layout.transcript.width <= 100,
      "long-form prose is not stretched across very wide terminals"
    check layout.status.y == 31 and layout.divider.y == 30,
      "bottom chrome stays anchored after a wide resize"

  block streamingProgression:
    let chat = initAgentChat()
    chat.apply userMessage("t:user", "hi")
    var harness = initHeadlessTui(80, 24)
    var state = initAgentUiState()
    state.transcript.scroll.anchor = anchorEnd
    discard harness.drawShell(chat, state, options)
    chat.apply messageDelta("t", "streamed ")
    let second = harness.drawShell(chat, state, options)
    chat.apply messageDelta("t", "answer")
    let third = harness.drawShell(chat, state, options)
    func streamedRow(snapshot: string): int =
      for row in snapshot.split('\n'):
        if row.contains("streamed"):
          return row.len
      0
    check second.streamedRow > 0,
      "streamed text appears in its own wake cycle"
    check third.streamedRow > second.streamedRow,
      "separate wake cycles produce progressively longer semantic frames"
    check third.contains("streamed answer"),
      "coalesced deltas keep text order and content"

  block thinkingVisible:
    let chat = initAgentChat()
    chat.apply thinkingDelta("t", "reasoning appears while it streams")
    var harness = initHeadlessTui(80, 24)
    var state = initAgentUiState()
    state.transcript.scroll.anchor = anchorEnd
    check harness.drawShell(chat, state, options)
      .contains("reasoning appears while it streams"),
      "thinking content is visible while it streams"

  block shimmerAndBanner:
    let chat = initAgentChat()
    chat.apply thinkingDelta("t", "working")
    var harness = initHeadlessTui(80, 24)
    var state = initAgentUiState()
    state.transcript.scroll.anchor = anchorEnd
    let colors = agentTheme()
    harness.draw proc (frame: var Frame) =
      frame.drawAgentShell(chat, state, options)
    # The activity row (18) must show a smooth gradient: several interpolated
    # colors between muted and accent, not three hard steps.
    var distinctColors: seq[Color]
    for x in 4 ..< 12:
      let fg = harness.buffer.cellAt(x, 19).style.fg
      if fg notin distinctColors: distinctColors.add fg
    check distinctColors.len >= 5,
      "the shimmer is a smooth multi-step gradient"
    for color in distinctColors:
      check color.kind == ckRgb,
        "the shimmer interpolates in true color"
    chat.apply notice("welcome", "月  tsuki\n    tagline", banner = true)
    harness.draw proc (frame: var Frame) =
      frame.drawAgentShell(chat, state, options)
    var bannerAccent = false
    for x in 0 ..< 80:
      if harness.buffer.glyphString(harness.buffer.cellAt(x, 2)).len > 0 and
          harness.buffer.cellAt(x, 2).style.fg == colors.base.accent.fg:
        bannerAccent = true
    check bannerAccent, "the banner welcome renders its wordmark in violet"

  block activity:
    let chat = initAgentChat()
    check chat.agentActivity == activityIdle, "an idle shell has no activity"
    chat.apply thinkingDelta("t", "...")
    check chat.agentActivity == activityThinking,
      "streamed thinking activates the run indicator"
    chat.apply toolStarted("t:tool", "Read")
    check chat.agentActivity == activityRunning,
      "a running tool reports running activity"
    chat.apply approvalRequested("t:approve", "do a thing")
    check chat.agentActivity == activityWaiting,
      "a pending approval pauses activity as waiting"
    chat.pendingApproval = ApprovalRequest()
    chat.apply turnFinished("t")
    check chat.agentActivity == activityIdle,
      "turn completion returns the shell to idle with no timer need"

  block backgroundToolPresentation:
    let chat = initAgentChat()
    chat.apply toolStarted("bg:index", "Index workspace",
      "scanning source files", background = true)
    chat.apply toolOutput("bg:index", "Found 18 Nim modules\n")
    var harness = initHeadlessTui(80, 24)
    var state = initAgentUiState()
    state.transcript.scroll.anchor = anchorEnd
    let snap = harness.drawShell(chat, state, options)
    check snap.contains("background · Index workspace"),
      "background work has an explicit non-color transcript label"
    check snap.contains("Found 18 Nim modules"),
      "background output streams through the regular tool presentation"

  block approvalPresentation:
    let chat = seededShellChat()
    chat.apply approvalRequested("t1:write", "apply a patch to src/tsuki.nim",
      risk = riskWrite, paths = @["src/tsuki.nim"],
      explanation = "Replace the greeting.")
    var harness = initHeadlessTui(80, 24)
    var state = initAgentUiState()
    state.transcript.scroll.anchor = anchorEnd
    let firstFrame = harness.drawShell(chat, state, options)
    check firstFrame.count("[Reject]") == 1,
      "approval appears exactly once and selects Reject before any input"
    check firstFrame.count("Approval required") == 1,
      "the approval is presented only through the inline card"
    check "apply a patch to src/tsuki.nim" in firstFrame,
      "the inline card shows command, explanation, and paths"
    let armed = handleShellEvent(chat, state,
      Event(kind: evKey, key: initKey(kcEnter)))
    check armed.effect == seNone,
      "the first Enter only arms the safe selected action"
    let armedFrame = harness.drawShell(chat, state, options)
    check armedFrame.contains("Press Enter again to confirm: Reject"),
      "the armed confirmation cue becomes visible before any decision"
    let confirmed = handleShellEvent(chat, state,
      Event(kind: evKey, key: initKey(kcEnter)))
    check confirmed.effect == seApproval and confirmed.decision ==
        approvalReject and not confirmed.approved,
      "the second Enter confirms the armed Reject"
    chat.pendingApproval = ApprovalRequest(id: "again", command: "rm -rf /")
    let escaped = handleShellEvent(chat, state,
      Event(kind: evKey, key: initKey(kcEscape)))
    check escaped.effect == seApproval and escaped.decision == approvalReject,
      "Escape rejects the approval without granting authority"
    let ctrlQ = handleShellEvent(chat, state,
      Event(kind: evKey, key: initKey(kcChar, Rune(ord('q')), {modCtrl})))
    check ctrlQ.effect == seQuit,
      "Ctrl-Q exits even while approval is pending"

  block textSelection:
    let chat = seededShellChat()
    var harness = initHeadlessTui(80, 24)
    var state = initAgentUiState()
    state.transcript.scroll.anchor = anchorEnd
    discard harness.drawShell(chat, state, options)
    let press = Event(kind: evMouse, mouse: MouseEvent(action: maPress,
      button: 0, x: 10, y: 1))
    let drag = Event(kind: evMouse, mouse: MouseEvent(action: maDrag,
      button: 0, x: 30, y: 4))
    let release = Event(kind: evMouse, mouse: MouseEvent(action: maRelease,
      button: 0, x: 30, y: 4))
    check handleShellEvent(chat, state, press).changed,
      "a mouse press starts a selection"
    discard handleShellEvent(chat, state, drag)
    discard handleShellEvent(chat, state, release)
    check state.transcript.hasSelection, "dragging extends the selection"
    let copied = handleShellEvent(chat, state,
      Event(kind: evKey, key: initKey(kcChar, Rune(ord('c')), {modCtrl})))
    check copied.effect == seCopy and copied.text.len > 0,
      "ctrl-c copies the selected transcript rows"
    check not state.transcript.hasSelection,
      "copying clears the selection"
    let cancel = handleShellEvent(chat, state,
      Event(kind: evKey, key: initKey(kcChar, Rune(ord('c')), {modCtrl})))
    check cancel.effect == seCancelTurn,
      "ctrl-c without a selection still cancels the active turn"

  block resizeAnchoring:
    let chat = seededShellChat()
    var harness = initHeadlessTui(80, 24)
    var state = initAgentUiState()
    state.transcript.scroll.anchor = anchorEnd
    discard harness.drawShell(chat, state, options)
    harness.resize(80, 30)
    let resized = harness.drawShell(chat, state, options)
    let rows = resized.shellRows
    check runeLen(rows[28]) == 80 and rows[28].startsWith(
        "────────────────"),
      "resize preserves the divider in stable bottom chrome"
    check rows[29].contains("agent") and rows[27].contains("▌"),
      "resize preserves composer and status anchoring"

testStreamingMarkdown()
testAgentModel()
testTranscriptAndApproval()
testAgentShell()
testExplicitProtocols()
echo "agent ok"
