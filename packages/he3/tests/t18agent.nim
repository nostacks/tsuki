import std/[monotimes, sequtils, strutils, times, unicode]
import common
import he3
import he3/agent
import he3/protocols/[clipboard, hyperlink, image, syncoutput]

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
  check not bounded.post(statusUpdated(AgentViewStatus(
      directory: repeat("d", 2048)))),
    "directory payloads count toward the typed queue byte bound"
  check not bounded.post(selectorUpdated(@[SelectorEntry(
      reasoningEfforts: @[repeat("r", 2048)])])),
    "reasoning metadata counts toward the typed queue byte bound"

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

proc testTranscriptViewport =
  block straddlingTop:
    let chat = initAgentChat()
    chat.apply userMessage("t:user", "show me a long answer")
    var body = ""
    for index in 0 ..< 40:
      if index > 0: body.add "\n"
      body.add "line " & $index
    chat.apply messageDelta("t", body)
    var harness = initHeadlessTui(60, 10)
    var state: TranscriptState
    state.scroll.anchor = anchorEnd
    harness.draw proc (frame: var Frame) =
      frame.transcript(chat, state)
    var rows = harness.snapshot.split('\n')
    check rows[0].strip() == "line 31",
      "an item cut by the top edge shows its visible rows"
    check rows[8].strip() == "line 39",
      "the last body row precedes the trailing gap"
    discard state.transcriptEvent(chat, Event(kind: evKey,
      key: initKey(kcUp)))
    discard state.transcriptEvent(chat, Event(kind: evKey,
      key: initKey(kcUp)))
    harness.draw proc (frame: var Frame) =
      frame.transcript(chat, state)
    rows = harness.snapshot.split('\n')
    check rows[0].strip() == "line 29",
      "scrolling inside an item keeps the row offset exact"

  block scrolledToolOutput:
    let chat = initAgentChat()
    chat.apply toolStarted("t:tool", "Read", "big.txt")
    var output = ""
    for index in 0 ..< 30:
      output.add "out " & $index & "\n"
    chat.apply toolOutput("t:tool", output)
    var harness = initHeadlessTui(60, 10)
    var state: TranscriptState
    state.scroll.anchor = anchorEnd
    harness.draw proc (frame: var Frame) =
      frame.transcript(chat, state)
    let rows = harness.snapshot.split('\n')
    check rows[0].contains("out 21"),
      "tool output cut by the top edge starts at the right line"
    check rows[8].contains("out 29"),
      "the last tool output line precedes the trailing gap"

  block resetInvalidatesCache:
    let chat = initAgentChat()
    chat.apply userMessage("t1:user", "first prompt")
    var harness = initHeadlessTui(60, 8)
    var state: TranscriptState
    state.scroll.anchor = anchorEnd
    harness.draw proc (frame: var Frame) =
      frame.transcript(chat, state)
    check harness.snapshot.contains("first prompt"), "seed renders"
    chat.apply sessionReset("s-2", "Second")
    chat.apply userMessage("t1:user", "second prompt")
    harness.draw proc (frame: var Frame) =
      frame.transcript(chat, state)
    check harness.snapshot.contains("second prompt") and
      not harness.snapshot.contains("first prompt"),
      "a session reset never reuses a cached document"

  block incrementalEqualsOneShot:
    let source = "# Title\n\nSome **bold** and `code`.\n\n```nim\n" &
      "echo 1\necho 2\n```\n- one\n- two\n\n> quote line\n\n" &
      "A long paragraph that wraps across the viewport width several " &
      "times so that per-line measurement matters for the layout.\n" &
      "Tail without newline"
    let streamed = initAgentChat()
    streamed.apply userMessage("t:user", "go")
    var harness = initHeadlessTui(48, 14)
    var state: TranscriptState
    state.scroll.anchor = anchorEnd
    var offset = 0
    var step = 1
    while offset < source.len:
      let stop = min(source.len, offset + step)
      streamed.apply messageDelta("t", source[offset ..< stop])
      offset = stop
      step = step mod 7 + 1
      harness.draw proc (frame: var Frame) =
        frame.transcript(streamed, state)
    let incremental = harness.snapshot
    let oneShot = initAgentChat()
    oneShot.apply userMessage("t:user", "go")
    oneShot.apply messageDelta("t", source)
    var fresh = initHeadlessTui(48, 14)
    var freshState: TranscriptState
    freshState.scroll.anchor = anchorEnd
    fresh.draw proc (frame: var Frame) =
      frame.transcript(oneShot, freshState)
    check incremental == fresh.snapshot,
      "incremental streaming renders exactly like a one-shot message"
    discard state.transcriptEvent(streamed, Event(kind: evKey,
      key: initKey(kcHome)))
    discard freshState.transcriptEvent(oneShot, Event(kind: evKey,
      key: initKey(kcHome)))
    harness.draw proc (frame: var Frame) =
      frame.transcript(streamed, state)
    fresh.draw proc (frame: var Frame) =
      frame.transcript(oneShot, freshState)
    check harness.snapshot == fresh.snapshot,
      "the incremental document matches from the top as well"

proc testTranscriptScrollHint =
  let chat = initAgentChat()
  chat.apply userMessage("t:user", "go")
  var harness = initHeadlessTui(40, 6)
  var state: TranscriptState
  state.scroll.anchor = anchorEnd
  for index in 0 ..< 12:
    chat.apply messageDelta("t", "line " & $index & "\n")
  harness.draw proc (frame: var Frame) =
    frame.transcript(chat, state)
  check harness.buffer.scrollHint.rows == 0, "the first draw has no history"
  for index in 12 ..< 15:
    chat.apply messageDelta("t", "line " & $index & "\n")
  harness.draw proc (frame: var Frame) =
    frame.transcript(chat, state)
  check harness.buffer.scrollHint.rows == 3 and
    harness.buffer.scrollHint.region == rect(0, 0, 40, 6),
    "streaming at the end hints an upward scroll by the new rows"
  harness.draw proc (frame: var Frame) =
    frame.transcript(chat, state)
  check harness.buffer.scrollHint.rows == 0, "an unchanged view has no hint"
  discard state.transcriptEvent(chat, Event(kind: evKey, key: initKey(kcUp)))
  harness.draw proc (frame: var Frame) =
    frame.transcript(chat, state)
  check harness.buffer.scrollHint.rows == -1, "scrolling up hints downward"
  harness.resize(40, 8)
  harness.draw proc (frame: var Frame) =
    frame.transcript(chat, state)
  check harness.buffer.scrollHint.rows == 0, "a new viewport never hints"
  state.setSearch(chat, "LINE 3")
  check state.matches == @[1], "search is case-insensitive"
  state.setSearch(chat, "missing")
  check state.matches.len == 0, "search reports no false matches"

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
  check modern.clipboard,
    "OSC 52-capable terminals advertise the clipboard protocol"
  check monochromeCapabilities().clipboard == false,
    "the lowest-common-denominator profile never writes the clipboard"
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

  block scrollControls:
    let chat = initAgentChat()
    var body = ""
    for index in 0 ..< 60:
      body.add "line " & $index & "\n"
    chat.apply messageDelta("long", body)
    var harness = initHeadlessTui(80, 24)
    var state = initAgentUiState()
    state.transcript.scroll.anchor = anchorEnd
    let layout = agentShellLayout(80, 24, chat, options)
    let bottomY = layout.transcript.height - 1
    let centerX = layout.transcript.x + layout.transcript.width div 2
    let atBottom = harness.drawShell(chat, state, options).shellRows
    check atBottom[0].contains("↑ Scroll to top") and
      not atBottom[bottomY].contains("Scroll to bottom"),
      "only top overflow is indicated when following the end"
    check atBottom[1 ..< bottomY].join("\n").contains("line 59"),
      "the scroll control never covers the last content row"
    let topClick = Event(kind: evMouse, mouse: MouseEvent(action: maPress,
      button: 0, x: centerX, y: 0))
    check handleShellEvent(chat, state, topClick).changed and
      state.transcript.scroll.offsetY == 0 and
      state.transcript.scroll.anchor == anchorStart and
      not state.selection.dragging,
      "clicking the top button jumps to the beginning without selecting text"
    check handleShellEvent(chat, state, Event(kind: evMouse,
      mouse: MouseEvent(action: maRelease, button: 0,
        x: centerX, y: 0))).effect == seNone,
      "releasing a scroll button never requests clipboard access"
    let atTop = harness.drawShell(chat, state, options).shellRows
    check not atTop[0].contains("Scroll to top") and
      atTop[1].contains("line 0") and
      atTop[bottomY].contains("↓ Scroll to bottom"),
      "at the beginning only the bottom overflow button is visible"
    discard handleShellEvent(chat, state, Event(kind: evMouse,
      mouse: MouseEvent(action: maScroll, button: 1)))
    let middle = harness.drawShell(chat, state, options).shellRows
    check middle[0].contains("Scroll to top") and
      middle[bottomY].contains("Scroll to bottom") and
      middle[1].contains("line 3"),
      "both controls appear in the middle without shifting the content offset"
    chat.apply messageDelta("long", "new streamed line\n")
    discard harness.drawShell(chat, state, options)
    check state.transcript.scroll.offsetY == 3,
      "new output preserves the position while reading earlier content"
    let bottomClick = Event(kind: evMouse, mouse: MouseEvent(action: maPress,
      button: 0, x: centerX, y: bottomY))
    state.prompt.editor.content = "/"
    state.prompt.editor.cursor = 1
    discard harness.drawShell(chat, state, options)
    discard handleShellEvent(chat, state, bottomClick)
    check state.transcript.scroll.offsetY == 3,
      "a command popover blocks clicks on the scroll control beneath it"
    state.selection.clearSelection()
    state.prompt.editor.content = ""
    state.prompt.editor.cursor = 0
    discard harness.drawShell(chat, state, options)
    discard handleShellEvent(chat, state, bottomClick)
    check state.transcript.scroll.atEnd and
      state.transcript.scroll.anchor == anchorEnd,
      "clicking the bottom button restores following new output"
    chat.apply messageDelta("long", "latest line\n")
    check harness.drawShell(chat, state, options).contains("latest line") and
      state.transcript.scroll.atEnd,
      "the end jump follows subsequent streamed output"
    state.focus = focusTranscript
    discard handleShellEvent(chat, state,
      Event(kind: evKey, key: initKey(kcHome)))
    discard harness.drawShell(chat, state, options)
    check state.transcript.scroll.offsetY == 0,
      "Home remains the keyboard equivalent of the top button"
    discard handleShellEvent(chat, state,
      Event(kind: evKey, key: initKey(kcEnd)))
    discard harness.drawShell(chat, state, options)
    check state.transcript.scroll.atEnd,
      "End remains the keyboard equivalent of the bottom button"
    harness.resize(12, 10)
    check harness.drawShell(chat, state, options).contains("↑ Top"),
      "narrow controls use a short label"
    harness.resize(1, 10)
    check harness.drawShell(chat, state, options).contains("↑"),
      "a single-cell viewport keeps a directional control"
    harness.resize(80, 6)
    let tiny = harness.drawShell(chat, state, options)
    check not tiny.contains("Scroll to") and
      state.transcript.scroll.viewportHeight == 2,
      "very short viewports prioritize content over control rows"
    harness.resize(80, 24)
    chat.apply sessionReset("empty", "Empty")
    let empty = harness.drawShell(chat, state, options)
    check not empty.contains("Scroll to") and empty.contains("No messages yet"),
      "reset removes both overflow indicators"
    discard handleShellEvent(chat, state, topClick)
    check state.selection.dragging,
      "a removed control leaves no stale click target"
    state.selection.clearSelection()
    chat.apply messageDelta("short", "short reply")
    let short = harness.drawShell(chat, state, options).shellRows
    check short[0].contains("short reply") and
      not short.join("\n").contains("Scroll to"),
      "content that fits uses the entire transcript with no control rows"

  block layout80x24:
    let chat = seededShellChat()
    var harness = initHeadlessTui(80, 24)
    var state = initAgentUiState()
    state.transcript.scroll.anchor = anchorEnd
    let snap = harness.drawShell(chat, state, options)
    let rows = snap.shellRows
    check rows[19].startsWith("  esc cancel"),
      "the activity/help row sits in stable bottom chrome"
    check rows[20].len == 0,
      "a blank row separates the activity line from the composer"
    check rows[21].contains("▌") and not rows[22].contains("▌"),
      "the composer is a single quiet row for a short draft"
    check runeLen(rows[22]) == 80 and rows[22].startsWith(
        "────────────────"),
      "one subdued divider separates composer and status"
    check rows[23].startsWith(" ") and rows[23].contains("◇ mock-tsuki"),
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
    check rows[7].contains("esc cancel"),
      "cancel guidance survives narrow widths"
    check runeLen(rows[^2]) == 40 and rows[^1].contains("default"),
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
    let cleared = handleShellEvent(chat, state, enter)
    check cleared.effect == seHostAction and
      cleared.actionKind == aaNewSession and cleared.changed,
      "/clear asks the host to reset the conversation with a fresh session"
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

  block slashDialogs:
    let chat = initAgentChat()
    var state = initAgentUiState()
    let outcome = runShellCommand(chat, state, "/model")
    check outcome.effect == seHostAction and outcome.changed and
      outcome.actionKind == aaModelSelector,
      "/model requests the model dialog and reports the change so it renders"
    let providerOutcome = runShellCommand(chat, state, "/provider")
    check providerOutcome.effect == seHostAction and
      providerOutcome.changed and
      providerOutcome.actionKind == aaProviderSelector,
      "/provider requests the provider dialog and reports the change"
    let resumeOutcome = runShellCommand(chat, state, "/resume")
    check resumeOutcome.changed and
      resumeOutcome.actionKind == aaSessions,
      "/resume without an id opens the session picker"

  block multilineComposer:
    var state = initAgentUiState()
    let chat = initAgentChat()
    let shifted = state.prompt.promptEvent(
      Event(kind: evKey, key: initKey(kcEnter, mods = {modShift})))
    check shifted.kind == promptChanged and
      state.prompt.editor.content == "\n",
      "shift-enter inserts a newline instead of submitting"
    let alted = state.prompt.promptEvent(
      Event(kind: evKey, key: initKey(kcEnter, mods = {modAlt})))
    check alted.kind == promptChanged and
      state.prompt.editor.content == "\n\n",
      "alt-enter also inserts a newline for legacy terminals"
    state.prompt.editor.content = "hello"
    state.prompt.editor.cursor = 5
    let submitted = state.prompt.promptEvent(
      Event(kind: evKey, key: initKey(kcEnter)))
    check submitted.kind == promptSubmit and submitted.text == "hello",
      "plain enter still submits the draft"

    block readlineEditing:
      var editor = initAgentUiState()
      editor.prompt.editor.content = "hello"
      editor.prompt.editor.cursor = 5
      let cleared = editor.prompt.promptEvent(
        Event(kind: evKey, key: initKey(kcChar, Rune(ord('u')), {modCtrl})))
      check cleared.kind == promptChanged and
        editor.prompt.editor.content == "",
        "ctrl-u clears the draft"
      let restored = editor.prompt.promptEvent(
        Event(kind: evKey, key: initKey(kcChar, Rune(ord('z')), {modCtrl})))
      check restored.kind == promptChanged and
        editor.prompt.editor.content == "hello",
        "ctrl-u is undoable"
      editor.prompt.editor.content = "hello"
      editor.prompt.editor.cursor = 2
      discard editor.prompt.promptEvent(
        Event(kind: evKey, key: initKey(kcChar, Rune(ord('k')), {modCtrl})))
      check editor.prompt.editor.content == "he",
        "ctrl-k kills to the end of the draft"
      editor.prompt.editor.content = "one two"
      editor.prompt.editor.cursor = 7
      discard editor.prompt.promptEvent(
        Event(kind: evKey, key: initKey(kcChar, Rune(ord('w')), {modCtrl})))
      check editor.prompt.editor.content == "one ",
        "ctrl-w deletes the word before the cursor"

  block escapeCancellation:
    let chat = initAgentChat()
    var state = initAgentUiState()
    let escape = Event(kind: evKey, key: initKey(kcEscape))
    for focus in [focusPrompt, focusTranscript]:
      state.focus = focus
      check handleShellEvent(chat, state, escape).effect == seNone,
        "Escape while idle keeps the app open from either focus"
      chat.apply userMessage("active", "work")
      for press in 0 ..< 2:
        let cancelled = handleShellEvent(chat, state, escape)
        check cancelled.effect == seCancelTurn and cancelled.changed and
          not state.quitArmed,
          "Escape cancels an active turn without arming or triggering exit"
      chat.apply turnCancelled("active")
      check handleShellEvent(chat, state, escape).effect == seNone,
        "Escape after cancellation keeps the app open"

  block quitConfirmation:
    let chat = initAgentChat()
    var state = initAgentUiState()
    let ctrlC = Event(kind: evKey,
      key: initKey(kcChar, Rune(ord('c')), {modCtrl}))
    let first = handleShellEvent(chat, state, ctrlC)
    check first.effect == seNone and first.changed and state.quitArmed,
      "the first ctrl-c arms the exit confirmation"
    var harness = initHeadlessTui(80, 24)
    let armed = harness.drawShell(chat, state)
    check armed.contains("press ctrl-c again to exit"),
      "the armed confirmation is visible on the activity line"
    let second = handleShellEvent(chat, state, ctrlC)
    check second.effect == seQuit and not state.quitArmed,
      "the second ctrl-c inside the window exits"
    state.quitArmed = false
    chat.apply userMessage("t", "active turn")
    let cancel = handleShellEvent(chat, state, ctrlC)
    check cancel.effect == seCancelTurn and state.quitArmed,
      "ctrl-c during a turn cancels it and arms the exit confirmation"
    let exitNow = handleShellEvent(chat, state, ctrlC)
    check exitNow.effect == seQuit,
      "the next ctrl-c exits after cancelling the turn"

  block statusProjection:
    let chat = initAgentChat()
    chat.apply statusUpdated(AgentViewStatus(provider: "chatgpt",
      model: "gpt-5.1-codex", mode: "agent", message: "ready",
      contextUsed: 4_000, contextLimit: 128_000, offline: false))
    let stale = agentTuiOptions(status = AgentStatus(model: "old",
      mode: "agent", message: "offline", offline: true))
    var harness = initHeadlessTui(80, 24)
    var state = initAgentUiState()
    state.transcript.scroll.anchor = anchorEnd
    let snap = harness.drawShell(chat, state, stale)
    check snap.contains("gpt-5.1-codex") and not snap.contains("offline"),
      "a live status replaces the stale startup offline fallback"
    check snap.shellRows[^1].endsWith("3%") and snap.contains(
        "●───────"),
      "the context meter and percent stay on the right edge"
    let fallback = agentTuiOptions(status = AgentStatus(model: "old",
      mode: "agent", message: "offline", offline: true))
    var fallbackState = initAgentUiState()
    let quiet = initAgentChat()
    let fallbackSnap = harness.drawShell(quiet, fallbackState, fallback)
    check fallbackSnap.contains("offline"),
      "without a live status the startup projection still applies"

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

    state = initAgentUiState()
    state.prompt.editor.content = "/"
    state.prompt.editor.cursor = 1
    var commandHarness = initHeadlessTui(80, 24)
    let commandFrame = commandHarness.drawShell(chat, state, options)
    check commandFrame.contains("Recommended commands") and
      commandFrame.contains("Sign in, sign out, or add a provider key"),
      "a leading slash opens the concise recommended command popover"
    check commandFrame.contains("↑↓ move") and commandFrame.contains("›"),
      "the popover exposes keyboard help and a non-color selection marker"
    for width in [24, 32, 40, 80, 120]:
      commandHarness.resize(width, 24)
      let resized = commandHarness.drawShell(chat, state, options)
      check resized.contains("/sessions"),
        "command titles use all available space before descriptions"
    discard handleShellEvent(chat, state,
      Event(kind: evKey, key: initKey(kcDown)))
    check state.prompt.completionIndex == 1,
      "plain arrows move the popover selection"
    let chosen = handleShellEvent(chat, state,
      Event(kind: evKey, key: initKey(kcEnter)))
    check chosen.effect == seNone and chosen.changed and
      state.prompt.editor.content == "/sessions ",
      "Enter completes a partial selected command before it can run"
    state.prompt.editor.content = "/"
    state.prompt.editor.cursor = 1
    state.prompt.completionDismissed = false
    let closed = handleShellEvent(chat, state,
      Event(kind: evKey, key: initKey(kcEscape)))
    check closed.effect == seNone and closed.changed and
      state.prompt.completionDismissed,
      "Escape closes command suggestions without quitting the shell"
    state.prompt.editor.content = "/login"
    state.prompt.editor.cursor = 6
    state.prompt.completionDismissed = false
    let login = handleShellEvent(chat, state,
      Event(kind: evKey, key: initKey(kcEnter)))
    check login.effect == seNone and login.changed and
      chat.items[^1].content.contains("Unknown command: /login"),
      "sign-in has no dedicated command and is reached through /provider"

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
    state.shimmerTick = 7
    let colors = agentTheme()
    harness.draw proc (frame: var Frame) =
      frame.drawAgentShell(chat, state, options)
    # The activity row (18) must show a smooth gradient: several interpolated
    # colors between muted and white, not three hard steps.
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
    let muted = colors.base.muted.fg
    for tick in [0, 8 + 8]:
      state.shimmerTick = tick
      harness.draw proc (frame: var Frame) =
        frame.drawAgentShell(chat, state, options)
      var lit = false
      for x in 4 ..< 12:
        if harness.buffer.cellAt(x, 19).style.fg != muted: lit = true
      check not lit, "the shimmer wraps only while every character is unlit"

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
    let before = harness.drawShell(chat, state, options)
    let press = Event(kind: evMouse, mouse: MouseEvent(action: maPress,
      button: 0, x: 10, y: 1))
    let drag = Event(kind: evMouse, mouse: MouseEvent(action: maDrag,
      button: 0, x: 30, y: 4))
    check handleShellEvent(chat, state, press).changed,
      "a mouse press starts a selection"
    discard handleShellEvent(chat, state, drag)
    check state.selection.hasSelection, "dragging extends the selection"
    let release = handleShellEvent(chat, state,
      Event(kind: evMouse, mouse: MouseEvent(action: maRelease,
        button: 0, x: 30, y: 4)))
    check release.effect == seCopy,
      "releasing a selection asks the shell to copy it"
    check state.selection.hasSelection,
      "the copied highlight stays visible until the next press"
    discard harness.drawShell(chat, state, options)
    let copied = harness.buffer.selectionText(state.selection)
    let rows = before.shellRows
    func cells(row: string, first, last: int): string =
      let runes = row.toRunes
      if first > runes.high: return ""
      ($runes[first .. min(last, runes.high)]).strip(leading = false)
    check copied.split('\n').len == 4 and
      copied.split('\n')[0] == rows[1].cells(10, 79) and
      copied.split('\n')[1] == rows[2].cells(0, 79) and
      copied.split('\n')[3] == rows[4].cells(0, 30) and
      copied.strip.len > 0,
      "the copied text is exactly the screen cells under the selection"
    check harness.buffer.cellAt(10, 1).style ==
      options.colors.base.selection and
      harness.buffer.cellAt(9, 1).style != options.colors.base.selection and
      harness.buffer.cellAt(31, 4).style != options.colors.base.selection,
      "the highlight covers exactly the selected cells"
    let click = handleShellEvent(chat, state,
      Event(kind: evMouse, mouse: MouseEvent(action: maPress,
        button: 0, x: 3, y: 3)))
    discard handleShellEvent(chat, state,
      Event(kind: evMouse, mouse: MouseEvent(action: maRelease,
        button: 0, x: 3, y: 3)))
    check click.changed and not state.selection.hasSelection,
      "a plain click clears the highlight without copying"
    let armQuit = handleShellEvent(chat, state,
      Event(kind: evKey, key: initKey(kcChar, Rune(ord('c')), {modCtrl})))
    check armQuit.effect == seNone and state.quitArmed,
      "ctrl-c arms the exit confirmation instead of copying"

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
    check rows[29].contains("◇ mock-tsuki") and rows[27].contains("▌"),
      "resize preserves composer and status anchoring"

proc testPhase1Views =
  let models = @[
    SelectorEntry(providerId: "local", providerName: "Local",
      modelId: "text", displayName: "Text model",
      imageInput: selectorUnsupported, tools: selectorSupported,
      available: true),
    SelectorEntry(providerId: "local", providerName: "Local",
      modelId: "vision", displayName: "Vision model",
      imageInput: selectorUnknown, tools: selectorUnknown,
      reason: "Discovery is offline")]
  block reasoningSelection:
    let entries = @[
      SelectorEntry(providerId: "local", modelId: "reasoner",
        displayName: "Reasoner", available: true,
        reasoningEfforts: @["low", "medium", "high"],
        defaultReasoningEffort: "medium"),
      SelectorEntry(providerId: "local", modelId: "plain",
        displayName: "Plain", available: true)]
    let chat = initAgentChat()
    var state = initAgentUiState()
    state.overlay = overlayModels
    let options = agentTuiOptions(selectorEntries = entries)
    var harness = initHeadlessTui(40, 12)
    let enter = Event(kind: evKey, key: initKey(kcEnter))
    let down = Event(kind: evKey, key: initKey(kcDown))
    let up = Event(kind: evKey, key: initKey(kcUp))
    let escape = Event(kind: evKey, key: initKey(kcEscape))
    check not harness.drawShell(chat, state, options).contains(
        "default (medium)"),
      "the first step only selects a model"
    let next = handleOverlayEvent(chat, state, options, enter)
    check next.effect == seNone and state.overlay == overlayModels and
      state.selector.reasoningStep and not state.selector.confirmed,
      "choosing a model opens reasoning without applying a host action"
    check harness.drawShell(chat, state, options).contains(
        "› default (medium)"),
      "the second step explains the provider default at narrow widths"
    discard handleOverlayEvent(chat, state, options, down)
    check harness.drawShell(chat, state, options).contains("› low"),
      "arrow navigation selects reasoning in a separate list"
    discard handleOverlayEvent(chat, state, options, escape)
    check state.overlay == overlayModels and not state.selector.reasoningStep,
      "Escape returns to the selected model without applying changes"
    discard handleOverlayEvent(chat, state, options, enter)
    let chosen = handleOverlayEvent(chat, state, options, enter)
    check chosen.effect == seHostAction and chosen.actionKind ==
        aaModelSelector and
      chosen.argument == "local\nreasoner" and chosen.reasoningEffort ==
          "low" and
      state.overlay == overlayNone,
      "only the second confirmation sends model and reasoning to the host"
    state.overlay = overlayModels
    discard handleOverlayEvent(chat, state, options, down)
    discard handleOverlayEvent(chat, state, options, enter)
    check harness.drawShell(chat, state, options).contains("not configurable"),
      "models without metadata offer only the provider default"
    discard handleOverlayEvent(chat, state, options, down)
    let plain = handleOverlayEvent(chat, state, options, enter)
    check plain.reasoningEffort.len == 0 and plain.argument == "local\nplain",
      "a different model never inherits an incompatible reasoning level"
    state.overlay = overlayModels
    discard handleOverlayEvent(chat, state, options, up)
    discard handleOverlayEvent(chat, state, options, enter)
    discard handleOverlayEvent(chat, state, options, up)
    check handleOverlayEvent(chat, state, options, enter).reasoningEffort.len == 0,
      "the default can be restored from the reasoning list"
    state.overlay = overlayModels
    discard handleOverlayEvent(chat, state, options, enter)
    discard handleOverlayEvent(chat, state, options, escape)
    discard handleOverlayEvent(chat, state, options, escape)
    check state.overlay == overlayNone,
      "Escape from the first step dismisses the dialog"

    var remembered = SelectorState(selectedProviderId: "local",
      selectedModelId: "reasoner", reasoningProviderId: "local",
      reasoningModelId: "reasoner", reasoningEffort: "high")
    discard remembered.selectorEvent(entries, enter)
    harness.draw proc (frame: var Frame) = frame.modelSelector(entries, remembered)
    check harness.snapshot.contains("› high"),
      "opening reasoning restores the current model's saved effort"
    let reordered = @[entries[1], entries[0]]
    check remembered.selectorEvent(reordered, enter).entry.modelId ==
        "reasoner",
      "discovery reordering cannot change the pending model"
    discard remembered.selectorEvent(entries, enter)
    check remembered.selectorEvent(@[entries[1]], enter).kind ==
        selectorChanged and
      not remembered.reasoningStep,
      "removing the pending model returns to model selection without confirmation"
  block selectorWideAndNarrow:
    var state: SelectorState
    var harness = initHeadlessTui(80, 24)
    harness.draw proc (frame: var Frame) =
      frame.modelSelector(models, state)
    check harness.snapshot.contains("no image") and
      harness.snapshot.contains("tools"),
      "model capabilities have non-color text labels"
    harness.resize(40, 12)
    harness.draw proc (frame: var Frame) =
      frame.modelSelector(models, state)
    check harness.snapshot.contains("Select provider") and
      harness.snapshot.contains("enter next"),
      "the selector keeps identity and keyboard help at 40x12"
    let down = state.selectorEvent(models,
      Event(kind: evKey, key: initKey(kcDown)))
    check down.kind == selectorChanged and state.selected == 1,
      "arrow traversal is semantic"
    let unavailable = state.selectorEvent(models,
      Event(kind: evKey, key: initKey(kcEnter)))
    check unavailable.kind == selectorIgnored,
      "an unavailable model does not replace the prior selection"
    discard state.selectorEvent(models,
      Event(kind: evKey, key: initKey(kcChar, Rune(ord('v')))))
    check state.selectedProviderId == "local" and
      state.selectedModelId == "vision" and state.selected == 0,
      "filtering retains the selected model identity"
    discard state.selectorEvent(models,
      Event(kind: evKey, key: initKey(kcBackspace)))
    check state.selected == 1,
      "clearing the filter restores the selected model position"

  block selectorOverlay:
    let chat = initAgentChat()
    var state = initAgentUiState()
    state.overlay = overlayModels
    let options = agentTuiOptions(selectorEntries = models)
    var harness = initHeadlessTui(80, 24)
    let snapshot = harness.drawShell(chat, state, options)
    check snapshot.contains("Select provider and model") and
      not snapshot.contains("enter send"),
      "the modal selector owns the shell while open"

  block providerAuthDialog:
    let auth = @[
      ProviderAuthEntry(providerId: "chatgpt",
        providerName: "ChatGPT (Codex subscription)",
        kind: providerAuthDevice, status: providerAuthUnknown,
        detail: "Sign-in is managed by the Codex CLI"),
      ProviderAuthEntry(providerId: "openai", providerName: "OpenAI",
        kind: providerAuthApiKey, status: providerAuthMissing,
        credentialEnv: "OPENAI_API_KEY")]
    let chat = initAgentChat()
    var state = initAgentUiState()
    let options = agentTuiOptions(authEntries = auth)
    var harness = initHeadlessTui(80, 24)
    state.overlay = overlayProviders
    let opened = harness.drawShell(chat, state, options)
    check opened.contains("Providers") and
      opened.contains("enter to sign in · del to sign out") and
      opened.contains("enter to add API key"),
      "the provider dialog offers sign-in, sign-out, and key actions"
    check opened.contains("or set OPENAI_API_KEY"),
      "missing keys still name their environment variable"
    discard handleOverlayEvent(chat, state, options,
      Event(kind: evKey, key: initKey(kcDown)))
    discard handleOverlayEvent(chat, state, options,
      Event(kind: evKey, key: initKey(kcEnter)))
    check state.auth.keyEntry,
      "an API key provider opens the masked key editor"
    let keyFrame = harness.drawShell(chat, state, options)
    check keyFrame.contains("API key for OpenAI"),
      "the key editor names its provider"
    discard handleOverlayEvent(chat, state, options,
      Event(kind: evPaste, text: "sk-pasted-1234"))
    let pastedFrame = harness.drawShell(chat, state, options)
    check state.auth.keyEditor.content == "sk-pasted-1234" and
      pastedFrame.contains("••••••••••••••"),
      "paste feeds the masked key editor and renders bullets"
    let submitted = handleOverlayEvent(chat, state, options,
      Event(kind: evKey, key: initKey(kcEnter)))
    check submitted.effect == seHostAction and
      submitted.actionKind == aaApiKey and
      submitted.argument == "openai\nsk-pasted-1234",
      "saving returns the provider and pasted key to the host"
    check not state.auth.keyEntry and state.auth.pending and
      harness.drawShell(chat, state, options).contains("Checking the key"),
      "the dialog waits for the host verdict after saving"
    chat.apply toast("api-key", "provider credential is rejected",
      success = false)
    check state.syncToast(chat) and state.overlay == overlayProviders and
      state.auth.keyEntry and not state.auth.pending,
      "a failed check reopens the key editor"
    check harness.drawShell(chat, state, options)
      .contains("provider credential is rejected"),
      "the key editor shows the failure inline"
    discard handleOverlayEvent(chat, state, options,
      Event(kind: evPaste, text: "sk-second"))
    discard handleOverlayEvent(chat, state, options,
      Event(kind: evKey, key: initKey(kcEnter)))
    chat.apply toast("api-key", "API key saved for OpenAI")
    check state.syncToast(chat) and state.overlay == overlayNone and
      state.focus == focusPrompt,
      "a successful check closes the dialog and returns to the composer"
    let confirmed = harness.drawShell(chat, state, options)
    check confirmed.contains("✓ API key saved for OpenAI"),
      "the confirmation shows on the activity line"
    state.dismissToast()
    check not harness.drawShell(chat, state, options).contains("API key saved"),
      "a dismissed toast disappears"
    chat.apply thinkingDelta("t", "working")
    chat.apply toast("model-selected", "Model set to OpenAI / gpt")
    discard state.syncToast(chat)
    let busy = harness.drawShell(chat, state, options)
    check busy.contains("thinking · ✓ Model set to OpenAI / gpt"),
      "a toast during a turn follows the activity label"
    chat.active = false
    state.dismissToast()
    state.overlay = overlayProviders
    state.auth = ProviderAuthUi()
    let device = handleOverlayEvent(chat, state, options,
      Event(kind: evKey, key: initKey(kcEnter)))
    check device.effect == seHostAction and
      device.actionKind == aaLogin and device.argument == "chatgpt" and
      state.overlay == overlayNone,
      "enter on a device provider requests its sign-in and closes the dialog"
    state.overlay = overlayProviders
    state.auth = ProviderAuthUi()
    let signOut = handleOverlayEvent(chat, state, options,
      Event(kind: evKey, key: initKey(kcDelete)))
    check signOut.effect == seHostAction and
      signOut.actionKind == aaLogout and signOut.argument == "chatgpt" and
      state.overlay == overlayNone,
      "delete on a device provider requests its sign-out and closes the dialog"
    state.overlay = overlayProviders
    state.auth = ProviderAuthUi()
    discard handleOverlayEvent(chat, state, options,
      Event(kind: evKey, key: initKey(kcDown)))
    let keyDelete = handleOverlayEvent(chat, state, options,
      Event(kind: evKey, key: initKey(kcDelete)))
    check keyDelete.effect == seNone and not keyDelete.changed and
      state.overlay == overlayProviders,
      "delete does nothing on an API key provider"
    let cancelled = handleOverlayEvent(chat, state, options,
      Event(kind: evKey, key: initKey(kcEscape)))
    check cancelled.changed and state.overlay == overlayNone,
      "escape closes the provider dialog"

  block sessionStates:
    let sessions = @[
      SessionPickerEntry(id: "s-one", title: "Interrupted work",
        workspace: "/workspace", updatedLabel: "now",
        providerModel: "mock/model", interrupted: true),
      SessionPickerEntry(id: "bad", title: "Corrupt session",
        corrupt: true, diagnostic: "truncated JSON")]
    var state: SessionPickerState
    var harness = initHeadlessTui(80, 24)
    harness.draw proc (frame: var Frame) =
      frame.sessionPicker(sessions, state)
    check harness.snapshot.contains("interrupted") and
      harness.snapshot.contains("ctrl-a archive"),
      "session recovery and archive confirmation are explicit text"
    let arm = state.sessionPickerEvent(sessions,
      Event(kind: evKey, key: initKey(kcChar, Rune(ord('a')), {modCtrl})))
    check arm.kind == sessionChanged and state.archiveArmed,
      "archive needs an explicit first keypress"
    let confirm = state.sessionPickerEvent(sessions,
      Event(kind: evKey, key: initKey(kcChar, Rune(ord('a')), {modCtrl})))
    check confirm.kind == sessionArchiveRequested,
      "the repeated archive key confirms the exact selected session"
    discard state.sessionPickerEvent(sessions,
      Event(kind: evKey, key: initKey(kcChar, Rune(ord('r')), {modCtrl})))
    check state.renaming, "rename enters a focused title editor"
    discard state.sessionPickerEvent(sessions,
      Event(kind: evKey, key: initKey(kcChar, Rune(ord('N')))))
    let renamed = state.sessionPickerEvent(sessions,
      Event(kind: evKey, key: initKey(kcEnter)))
    check renamed.kind == sessionRename and renamed.title == "N",
      "rename returns the exact session and sanitized new title"
    discard state.sessionPickerEvent(sessions,
      Event(kind: evKey, key: initKey(kcDown)))
    let corruptArchive = state.sessionPickerEvent(sessions,
      Event(kind: evKey, key: initKey(kcChar, Rune(ord('a')), {modCtrl})))
    check corruptArchive.kind == sessionIgnored,
      "corrupt diagnostics cannot be archived as session identities"

  block attachmentFallback:
    var harness = initHeadlessTui(40, 3)
    harness.draw proc (frame: var Frame) =
      frame.attachmentCard(Attachment(id: "a", name: "safe.png",
        mediaType: "image/png", sizeBytes: 2048),
        state = cardPreviewUnsupported, dimensions = "20×10",
        altText = "diagram")
    check harness.snapshot.contains("Image") and
      harness.snapshot.contains("Alt: diagram"),
      "unsupported terminals retain a meaningful attachment card"

proc testContextStatus =
  var status = AgentStatus(directory: "/work/日本/tsuki", model: "reasoner",
    reasoningEffort: "high", mode: "agent", contextUsed: 64_000,
    contextLimit: 128_000)
  for width in [0, 1, 4, 12, 24, 32, 40, 64, 80, 120]:
    var harness = initHeadlessTui(width, 1)
    harness.draw proc (frame: var Frame) = frame.statusBar(status)
    let snapshot = harness.snapshot
    check snapshot.cellWidth <= width, "status stays bounded at every width"
    if width >= 4:
      check snapshot.endsWith("50%"), "context percent is right aligned"
    if width >= 40:
      check snapshot.contains("tsuki"), "directory survives narrow layouts"
    if width >= 100:
      check snapshot.contains("64k/128k") and snapshot.contains("high"),
        "wide status shows counts and the selected reasoning level"
  var harness = initHeadlessTui(80, 1)
  let shortModel = status.model
  status.model = repeat("long-model-", 10)
  harness.draw proc (frame: var Frame) = frame.statusBar(status)
  check harness.snapshot.contains("✦ high") and
    harness.snapshot.contains("tsuki") and harness.snapshot.endsWith("50%"),
    "a long model name cannot push reasoning or context out of the status bar"
  status.reasoningEffort = ""
  harness.draw proc (frame: var Frame) = frame.statusBar(status)
  check harness.snapshot.contains("✦ default"),
    "the provider default remains visible when no explicit effort is selected"
  status.model = shortModel
  status.reasoningEffort = "high"
  status.provider = "chatgpt"
  status.message = "ready"
  harness.draw proc (frame: var Frame) = frame.statusBar(status)
  check harness.snapshot.contains("⌂ tsuki  ◇ reasoner  ✦ high") and
    not harness.snapshot.contains("/work") and
    not harness.snapshot.contains("chatgpt") and
    not harness.snapshot.contains("agent") and
    not harness.snapshot.contains("ready"),
    "the compact status groups directory, model, and reasoning without routine labels"
  for base in [darkTheme(), lightTheme(), noColorTheme(), highContrastTheme()]:
    let colors = agentTheme(base)
    harness.draw proc (frame: var Frame) = frame.statusBar(status,
        colors = colors)
    check harness.buffer.cellAt(0, 0).style == colors.base.muted and
      harness.buffer.cellAt(9, 0).style == colors.base.text.bold and
      harness.buffer.cellAt(21, 0).style == colors.base.accent,
      "directory, model, and reasoning use distinct theme roles and icons"
  status.offline = true
  harness.draw proc (frame: var Frame) = frame.statusBar(status)
  check harness.snapshot.contains("! offline") and
    harness.snapshot.contains("✦ high"),
    "exceptional connection state remains visible beside reasoning"
  status.offline = false
  status.saving = true
  harness.draw proc (frame: var Frame) = frame.statusBar(status)
  check harness.snapshot.contains("↻ saving"), "saving remains explicit"
  status.saving = false
  for message in ["saved", "idle", "streaming",
      "streaming · context estimate"]:
    status.message = message
    harness.draw proc (frame: var Frame) = frame.statusBar(status)
    check not harness.snapshot.contains(message),
      "routine lifecycle messages keep the compact bar quiet"
  status.message = "save failed"
  harness.draw proc (frame: var Frame) = frame.statusBar(status)
  check harness.snapshot.contains("! save failed"),
    "a save failure stays explicit when routine save messages are hidden"
  status.message = "ready"
  harness.draw proc (frame: var Frame) =
    frame.statusBar(status, rateLimit = RateLimit(limit: 10, remaining: 0))
  check harness.snapshot.contains("! rate limit"),
    "an exhausted request limit remains visible"
  for used in [0'i64, 64_000, 128_000, high(int64)]:
    status.contextUsed = used
    harness.draw proc (frame: var Frame) = frame.statusBar(status)
    let cells = harness.cells
    let expected = if used == 0: agentTheme().base.success.fg
      elif used == 64_000: agentTheme().base.warning.fg
      else: agentTheme().base.error.fg
    check cells[^1].style.fg == expected,
      "usage moves from green through amber to red without integer overflow"
    if used >= 128_000:
      check harness.snapshot.endsWith("100%") and
        harness.snapshot.contains("━━━━━━━●"),
        "full and over-limit usage fill the meter and clamp the percentage"
      var first, last: Color
      for cell in cells:
        if cell.glyph == "━" and first.kind ==
            ckDefault: first = cell.style.fg
        if cell.glyph == "●": last = cell.style.fg
      check first == agentTheme().base.success.fg and
        last == agentTheme().base.error.fg, "the filled meter has a green-red gradient"
  harness.draw proc (frame: var Frame) =
    frame.statusBar(status, colors = agentTheme(noColorTheme()))
  for cell in harness.cells:
    check cell.style.fg.kind == ckDefault, "no-color themes remain color free"
  status.contextLimit = 0
  status.contextUsed = 0
  status.directory = "/work/unsafe\e]52;c;owned\a/name"
  harness.draw proc (frame: var Frame) = frame.statusBar(status)
  check harness.snapshot.endsWith("ctx ?") and '\e' notin harness.snapshot,
    "unknown capacity stays explicit and directory controls are sanitized"

proc spanTexts(line: Line): seq[string] =
  for span in line.spans: result.add span.text

proc testRichMarkdown =
  let doc = parseMarkdown("""# Title
## Sub *heading*
Text with **bold**, *italic*, ***both***, ~~gone~~, `code`, a [link](https://example.com), and https://nim-lang.org.
1. first
2. second
   - nested bullet
   - [x] done task
> quoted **strong**
> > deeper
| Name | Value |
|:-----|------:|
| pi | 3.14 |
$$
\int_a^b f(x) dx
$$
Inline $a^2 + b^2 = c^2$ here, price $5 and $10.
![A plot](memory:plot)
```nim
proc greet*(name: string): string =
  result = "hi " & name  # trailing
```
----
""")
  let colors = agentTheme()
  check doc.lines[0].spans[0].style == colors.base.accent.bold.underlined,
    "a level one heading is accented, bold, and underlined"
  check doc.lines[1].spanTexts == @["Sub ", "heading"] and
    doc.lines[1].spans[1].style == colors.base.accent.bold.italic,
    "inline emphasis nests inside headings and keeps the plain prefix"
  let mixed = doc.lines[2]
  check mixed.spanTexts[0] == "Text with " and
    mixed.spans[1].style == colors.base.text.bold and
    mixed.spans[3].style == colors.base.text.italic and
    mixed.spans[5].style == colors.base.text.bold.italic and
    attrStrikethrough in mixed.spans[7].style.attrs,
    "bold, italic, bold italic, and strikethrough each get their style"
  var links: seq[string]
  for span in mixed.spans:
    if span.hyperlink.uri.len > 0: links.add span.hyperlink.uri
  check links == @["https://example.com", "https://nim-lang.org"],
    "explicit links and bare URLs both carry their URI"
  check doc.lines[3].spanTexts == @["1. ", "first"] and
    doc.lines[5].spanTexts == @["  ", "◦ ", "nested bullet"] and
    doc.lines[6].spanTexts == @["  ", "☑ ", "done task"],
    "ordered, nested, and task list items keep their cues and depth"
  check doc.lines[7].spanTexts == @["│ ", "quoted ", "strong"] and
    doc.lines[8].spanTexts[0] == "│ │ ",
    "block quotes nest with one bar per level"
  check doc.lines[9].spans[0].style == colors.tableHeader and
    doc.lines[10].spanTexts == @["─────┼──────"] and
    doc.lines[11].spanTexts == @["pi  ", " │ ", " 3.14"],
    "the first table row is the header, the separator becomes a rule, " &
    "and body cells pad to the column width with its alignment"
  let wide = parseMarkdown("| a | b |\n|:-:|--:|\n| **longer** | 1 |\n| x | 12 |")
  check wide.lines[0].spanTexts.join == "  a    │  b" and
    wide.lines[1].spanTexts.join == "───────┼───" and
    wide.lines[2].spanTexts.join == "longer │  1" and
    wide.lines[3].spanTexts.join == "  x    │ 12",
    "columns take the widest rendered cell and honor center and right"
  check doc.lines[12].spanTexts == @["  ∫ₐᵇ f(x) dx"] and
    doc.lines[12].spans[0].style == colors.math,
    "display math renders on its own indented line"
  check doc.lines[13].spanTexts == @["Inline ", "a² + b² = c²",
    " here, price $5 and $10."],
    "inline math renders and lone dollar amounts stay text"
  check doc.lines[14].image == ImageRef(source: "memory:plot",
    alt: "A plot") and doc.lines[14].spanTexts == @["▣ A plot"],
    "an image paragraph records its source with a text fallback"
  check doc.lines[15].spanTexts == @["Code · nim"], "fences keep the label"
  let code = doc.lines[16]
  check code.spans[0].text == "proc" and
    code.spans[0].style == colors.syntax.keyword and
    code.spans[2].text == "greet" and
    code.spans[2].style == colors.syntax.function,
    "fenced Nim highlights keywords and calls"
  var sawString, sawComment: bool
  for span in doc.lines[17].spans:
    if span.text == "\"hi \"" and span.style == colors.syntax.literal:
      sawString = true
    if span.text == "# trailing" and span.style == colors.syntax.comment:
      sawComment = true
  check sawString and sawComment, "strings and comments are highlighted"
  check doc.lines[18].spans[0].style == colors.base.border,
    "a four dash rule still draws a rule"
  check parseMarkdown("no *emph* \\*literal\\* and snake_case_name").lines[0]
    .spanTexts == @["no ", "emph", " *literal* and snake_case_name"],
    "escapes and intraword underscores never open emphasis"

proc testMathRendering =
  check renderMath("E = mc^2") == "E = mc²", "superscripts map to Unicode"
  check renderMath("\\sum_{i=1}^{n} x_i^2") == "∑ᵢ₌₁ⁿ xᵢ²",
    "sums carry mapped sub and superscripts"
  check renderMath("\\frac{1}{2} + \\frac{a+b}{c}") == "½ + (a+b)/c",
    "fractions use vulgar forms or parenthesised slashes"
  check renderMath("\\int_0^\\infty e^{-x^2} dx") == "∫₀^∞ e^(-x²) dx",
    "a command as a script argument consumes only itself"
  check renderMath("\\sqrt{x^2 + y^2}") == "√(x² + y²)" and
    renderMath("\\sqrt{2}") == "√2̅", "radicals overline simple content"
  check renderMath("\\mathbb{R}^n \\subseteq \\mathcal{H}") == "ℝⁿ ⊆ ℋ",
    "blackboard and script alphabets map letter by letter"
  check renderMath("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}") ==
    "(a   b; c   d)", "matrices render row by row inside their brackets"
  check renderMath("\\hat{x} + \\vec{v}") == "x̂ + v⃗",
    "accents become combining marks"
  check '\e' notin renderMath("\\alpha\e]52;c;owned\a") and
    "owned" in renderMath("\\alpha\e]52;c;owned\a"),
    "control bytes never survive math rendering"
  check renderMath(repeat("{", 100) & "x" & repeat("}", 100)) == "x",
    "deep nesting stays bounded"

proc testHighlighting =
  let colors = agentTheme()
  var state: HighlightState
  let first = highlightLine("let x = 42; /* open", "c", state, colors)
  check first.spans[^1].text == "/* open" and
    first.spans[^1].style == colors.syntax.comment,
    "an unterminated block comment colors the rest of the line"
  let second = highlightLine("still */ return x;", "c", state, colors)
  check second.spans[0].text == "still */" and
    second.spans[0].style == colors.syntax.comment and
    second.spans[2].text == "return" and
    second.spans[2].style == colors.syntax.keyword,
    "the comment state carries to the next line and then closes"
  let py = highlightLine("def area(r): return 3.14 * r ** 2  # pi", "python",
    state, colors)
  var kinds: seq[string]
  for span in py.spans:
    if span.style == colors.syntax.keyword: kinds.add "kw:" & span.text
    elif span.style == colors.syntax.number: kinds.add "num:" & span.text
    elif span.style == colors.syntax.function: kinds.add "fn:" & span.text
    elif span.style == colors.syntax.comment: kinds.add "cm:" & span.text
  check kinds == @["kw:def", "fn:area", "kw:return", "num:3.14", "num:2",
    "cm:# pi"], "python keywords, calls, numbers, and comments are found"
  check not knownLanguage("brainfuck") and knownLanguage("TypeScript"),
    "language lookup is case insensitive and honest about unknowns"
  let plain = highlightLine("anything at all", "brainfuck", state, colors)
  check plain.spans.len == 1 and plain.spans[0].style == colors.base.code,
    "unknown languages stay in the plain code style"

proc testTranscriptImagesAndLinks =
  let chat = initAgentChat()
  chat.apply userMessage("u1", "see the plot", @[Attachment(id: "a1",
    name: "plot.png", mediaType: "image/png", sizeBytes: 2048, width: 400,
    height: 200, state: attachmentViewReady, source: "/tmp/plot.png")])
  chat.apply messageDelta("t1", "Docs: [guide](https://example.com/guide)\n" &
    "![Sine](memory:sine)\nAfter the image.")
  var harness = initHeadlessTui(60, 40)
  var state: TranscriptState
  var requested: seq[string]
  state.imageResolver = proc (source: string): ImageInfo =
    requested.add source
    if source == "memory:sine":
      ImageInfo(id: 7, widthPx: 320, heightPx: 160)
    elif source == "/tmp/plot.png":
      ImageInfo(id: 9, widthPx: 400, heightPx: 200)
    else:
      ImageInfo()
  harness.draw proc (frame: var Frame) =
    frame.transcript(chat, state)
  state.scroll.anchor = anchorStart
  state.scroll.offsetY = 0
  harness.draw proc (frame: var Frame) =
    frame.transcript(chat, state)
  let rows = harness.snapshot.split('\n')
  check requested.contains("memory:sine") and
    requested.contains("/tmp/plot.png"),
    "the resolver is asked for markdown images and attachments"
  check harness.buffer.images.len == 2, "both images are placed"
  var attachment, markdown: ImagePlacement
  for placement in harness.buffer.images:
    if placement.imageId == 9: attachment = placement
    if placement.imageId == 7: markdown = placement
  check attachment.cols == 40 and attachment.rows == 10 and
    attachment.rect.x == 2 and attachment.rect.y == 1,
    "an attachment preview sits below the user text at the body inset"
  check markdown.cols == 32 and markdown.rows == 8,
    "a markdown image box follows the ten pixel per column rule"
  check rows[attachment.rect.y + attachment.rows].contains(
    "Attachment: plot.png"),
    "the attachment caption sits directly under its image"
  check rows[markdown.rect.y + markdown.rows].contains("▣ Sine") and
    rows[markdown.rect.y + markdown.rows + 1].contains("After the image."),
    "the markdown caption and the following paragraph keep their order"
  var linked = 0
  for y in 0 ..< harness.buffer.height:
    for x in 0 ..< harness.buffer.width:
      let cell = harness.buffer.cellAt(x, y)
      if cell.link != 0 and harness.buffer.linkUri(cell.link) ==
          "https://example.com/guide":
        inc linked
  check linked == 5, "exactly the link label cells carry the URI"
  harness.resize(60, 12)
  harness.draw proc (frame: var Frame) =
    frame.transcript(chat, state)
  state.scroll.scrollBy(0, -(state.scroll.maxOffsetY - (attachment.rect.y + 3)))
  harness.draw proc (frame: var Frame) =
    frame.transcript(chat, state)
  var cut: ImagePlacement
  for placement in harness.buffer.images:
    if placement.imageId == 9: cut = placement
  check cut.rect.y == 0 and cut.offsetY == 3 and cut.rect.height == 7,
    "an image scrolled past the top keeps its cropped placement"
  var plain: TranscriptState
  harness.draw proc (frame: var Frame) =
    frame.transcript(chat, plain)
  plain.scroll.anchor = anchorStart
  plain.scroll.offsetY = 0
  harness.draw proc (frame: var Frame) =
    frame.transcript(chat, plain)
  check harness.buffer.images.len == 0 and
    harness.snapshot.contains("▣ Sine") and
    harness.snapshot.contains("Attachment: plot.png"),
    "without a resolver images fall back to their captions"

proc testStreamingRichMarkdown =
  let source = "Intro with **bold *nested*** and $x^2$\n| a | b |\n|---|---|\n" &
    "| 1 | 2 |\n1. one\n  - two\n```python\nx = \"\"\"open\nstill\"\"\"\n```\n" &
    "![alt](img)\n$$\n\\frac{1}{2}\n$$\ntail"
  let expected = parseMarkdown(source)
  var streamed = initMarkdownState()
  for byteIndex in 0 ..< source.len:
    streamed.feed(source[byteIndex .. byteIndex])
  check streamed.finish().lines == expected.lines,
    "rich markdown streams byte by byte to the one-shot result"

testContextStatus()
testStreamingMarkdown()
testRichMarkdown()
testMathRendering()
testHighlighting()
testTranscriptImagesAndLinks()
testStreamingRichMarkdown()
testAgentModel()
testTranscriptAndApproval()
testTranscriptViewport()
testTranscriptScrollHint()
testAgentShell()
testExplicitProtocols()
testPhase1Views()
echo "agent ok"
