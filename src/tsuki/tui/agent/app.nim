## Ready-to-run, transport-neutral coding-agent shell.

import std/[math, monotimes, strutils, times]
import ../app
import ../[event, geometry, graphemes, reactor, render, scroll, style, text]
import ../widgets/[display, spinner]
import approval, model, planview, prompt, statusbar, theme, transcript

const agentCommands* = ["/help", "/clear", "/quit"]

type
  AgentActionKind* = enum
    aaSubmit
    aaCancel
    aaApproval
    aaCopy
    aaRetry

  AgentAction* = object
    kind*: AgentActionKind
    prompt*: string
    approvalId*: string
    decision*: ApprovalDecision
    approved*: bool
    always*: bool
    text*: string

  AgentActionProc* = proc (action: AgentAction) {.closure.}

  AgentFocus* = enum
    focusTranscript
    focusPrompt

  AgentActivity* = enum
    activityIdle
    activityThinking
    activityRunning
    activityWaiting

  AgentTuiOptions* = object
    tui*: TuiOptions
    colors*: AgentTheme
    promptHeight*: int
    showPlan*: bool
    reducedMotion*: bool
    status*: AgentStatus

  AgentUiState* = object
    transcript*: TranscriptState
    prompt*: PromptState
    approval*: ApprovalState
    focus*: AgentFocus
    spinner*: Spinner
    approvalFor*: string

func agentTuiOptions*(tui = tuiOptions(mouse = true), colors = agentTheme(),
    promptHeight = 3, showPlan = true, reducedMotion = false,
    status = AgentStatus()): AgentTuiOptions =
  ## Creates sensible agent-shell defaults without choosing a model transport.
  AgentTuiOptions(tui: tui, colors: colors,
    promptHeight: max(1, promptHeight), showPlan: showPlan,
    reducedMotion: reducedMotion, status: status)

proc initAgentUiState*(): AgentUiState =
  ## Shell state with the safe approval default selected and the built-in
  ## slash commands registered for completion.
  result = AgentUiState(focus: focusPrompt, approval: initApprovalState(),
    spinner: initSpinner(spBraille))
  result.prompt.setCompletions(agentCommands)

proc agentActivity*(chat: AgentChat): AgentActivity =
  ## Derives the visible activity state from durable chat state only.
  if chat.pendingApproval.id.len > 0:
    return activityWaiting
  if not chat.active:
    return activityIdle
  for index in countdown(chat.items.len - 1, 0):
    let item = chat.items[index]
    if item.kind == transcriptTool and item.status == toolRunning and
        not item.background:
      return activityRunning
  activityThinking

func activityLabel(activity: AgentActivity): string =
  case activity
  of activityIdle: ""
  of activityThinking: "thinking"
  of activityRunning: "running"
  of activityWaiting: "waiting for approval"

proc syncApproval(state: var AgentUiState, chat: AgentChat) =
  ## Resets approval state when the request ID changes so a stale armed choice
  ## can never confirm a different request.
  let id = chat.pendingApproval.id
  if id != state.approvalFor:
    state.approvalFor = id
    state.approval = initApprovalState()

type
  AgentShellLayout* = object
    ## Deterministic bottom-anchored shell rectangles shared by the live run
    ## and headless tests. The approval card lives inline at the bottom of the
    ## transcript flow; the composer is one row when the draft is short.
    transcript*: Rect
    approval*: Rect
    plan*: Rect
    activity*: Rect
    composer*: Rect
    divider*: Rect
    status*: Rect

proc agentShellLayout*(width, height: int, chat: AgentChat,
    options: AgentTuiOptions, draftRows = 1,
    approvalArmed = false): AgentShellLayout =
  ## Computes stable bottom chrome (plan, activity, composer, divider, status),
  ## the inline approval card, and a top transcript region. Narrow and short
  ## terminals degrade deliberately: content shrinks first, then optional rows.
  let w = max(1, width)
  let h = max(1, height)
  let inset = if w >= 12: 2 else: 0
  let rightInset = if w >= 12: 1 else: 0
  let statusHeight = if h >= 3: 1 else: 0
  let dividerHeight = if h >= 4: 1 else: 0
  let activityHeight = if h >= 5: 1 else: 0
  # The activity line is its own status group. At ordinary terminal heights it
  # gets breathing room on both sides, so streamed content and the composer do
  # not visually run into the loader.
  let activityTopGap = if activityHeight > 0 and h >= 9: 1 else: 0
  let composerGap = if h >= 7: 1 else: 0
  let planRows = if options.showPlan and chat.plan.len > 0 and h >= 6:
    1 else: 0
  let available = max(0, h - planRows - activityTopGap - activityHeight -
    composerGap - dividerHeight - statusHeight)
  let approvalRows = if chat.pendingApproval.id.len > 0:
    min(approvalRowCount(chat.pendingApproval, approvalArmed),
      max(0, available - 1))
  else:
    0
  # The composer grows with the draft (one row minimum) and shrinks under
  # pressure so the approval card always fits.
  let wanted = max(1, min(options.promptHeight, max(1, draftRows)))
  let promptHeight = min(wanted, max(0, available - approvalRows))
  let bodyHeight = max(0, available - approvalRows - promptHeight)
  # Long-form copy stays readable on very wide terminals; code and diffs may
  # use more width, so the cap is generous.
  let transcriptWidth = min(max(1, w - inset - rightInset), 100)
  result.transcript = rect(inset, 0, transcriptWidth, bodyHeight)
  var y = bodyHeight
  if approvalRows > 0:
    result.approval = rect(inset, y, max(1, w - inset - rightInset),
      approvalRows)
    inc y, approvalRows
  if planRows > 0:
    result.plan = rect(inset, y, max(1, w - inset - rightInset), 1)
    inc y
  inc y, activityTopGap
  if activityHeight > 0:
    result.activity = rect(inset, y, max(1, w - inset - rightInset), 1)
    inc y
  inc y, composerGap
  if promptHeight > 0:
    result.composer = rect(if w >= 4: 1 else: 0, y,
      max(1, w - (if w >= 4: 2 else: 0)), promptHeight)
    inc y, promptHeight
  if dividerHeight > 0:
    result.divider = rect(0, y, w, 1)
    inc y
  if statusHeight > 0:
    result.status = rect(1, h - 1, max(1, w - 2), 1)

proc draftRowCount(state: AgentUiState, options: AgentTuiOptions): int =
  ## The composer shows one row for a short draft and grows only when the
  ## draft itself contains newlines.
  var lines = 1
  for cluster in state.prompt.editor.content.graphemes:
    if cluster == "\n": inc lines
  clamp(lines, 1, max(1, options.promptHeight))

func lerpColor(a, b: Color, t: float): Color =
  ## Linear interpolation between two colors. Non-RGB pairs (monochrome and
  ## no-color themes) fall back to a stepped choice so their semantics hold.
  if a.kind != ckRgb or b.kind != ckRgb:
    return if t >= 0.5: b else: a
  func channel(x, y: range[0..255]): range[0..255] =
    byte(min(255.0, max(0.0,
      float(x) + (float(y) - float(x)) * t)))
  Color(kind: ckRgb, rgb: [channel(a.rgb[0], b.rgb[0]),
    channel(a.rgb[1], b.rgb[1]), channel(a.rgb[2], b.rgb[2])])

proc writeShimmer(frame: Frame, x, y: int, text: string, phase: float,
    colors: AgentTheme) =
  ## CSS-style shimmer: one smooth raised-cosine highlight travels through
  ## the label, interpolated per character between the muted and accent
  ## colors. Driven by the spinner frame, so it adds no extra wakeups.
  let base = colors.base.muted.fg
  let peak = colors.base.accent.fg
  var cx = x
  var index = 0
  for cluster in text.graphemes:
    let width = cluster.clusterWidth
    if cx + width > frame.rect.width: break
    let distance = abs(float(index) - phase)
    let t = if distance < 3.5: 0.5 * (1.0 + cos(PI * distance / 3.5)) else: 0.0
    frame.write(cx, y, cluster,
      Style(fg: lerpColor(base, peak, t), bg: Color(kind: ckDefault)))
    inc cx, width
    inc index

proc drawAgentShell*(frame: var Frame, chat: AgentChat,
    state: var AgentUiState, options: AgentTuiOptions) =
  ## Draws the whole agent shell: inset transcript, inline approval card,
  ## compact plan, activity or help line, composer, divider, and status.
  syncApproval(state, chat)
  let colors = options.colors
  let layout = agentShellLayout(frame.rect.width, frame.rect.height, chat,
    options, draftRowCount(state, options), state.approval.armed)
  if layout.transcript.height > 0:
    frame.sub(layout.transcript).transcript(chat, state.transcript, colors)
  if layout.approval.height > 0:
    frame.sub(layout.approval).approvalInline(chat.pendingApproval,
      state.approval, colors)
  if layout.plan.height > 0:
    frame.sub(layout.plan).planSummary(chat.plan, colors)
  if layout.activity.height > 0:
    let activity = frame.sub(layout.activity)
    let current = chat.agentActivity
    if current != activityIdle:
      let glyph = state.spinner.current()
      let label = activityLabel(current)
      let labelX = glyph.cellWidth + 1
      activity.write(0, 0, glyph & " ", colors.base.accent)
      activity.writeShimmer(labelX, 0, label, float(state.spinner.frame),
        colors)
      let queued = state.prompt.pendingPromptCount
      if queued > 0:
        let queueLabel = if queued == 1: " · 1 prompt queued"
          else: " · " & $queued & " prompts queued"
        let queueX = labelX + label.cellWidth
        activity.write(queueX, 0, queueLabel.truncateCells(
          max(0, activity.rect.width - queueX), true), colors.base.muted)
    else:
      activity.write(0, 0, ("esc quit · wheel scroll · enter send")
        .truncateCells(activity.rect.width, true), colors.base.muted)
  if layout.composer.height > 0:
    frame.sub(layout.composer).prompt(state.prompt,
      state.focus == focusPrompt, colors = colors)
  if layout.divider.height > 0:
    frame.sub(layout.divider).rule(style = colors.base.border)
  if layout.status.height > 0:
    frame.sub(layout.status).statusBar(options.status, chat.usage, colors,
      chat.rateLimit)

type
  ShellEffect* = enum
    seNone
    seQuit
    seSuspend
    seCancelTurn
    seApproval
    seSubmit
    seCopy

  ShellOutcome* = object
    ## Deterministic result of one shell event; the live loop executes it.
    effect*: ShellEffect
    changed*: bool
    approvalId*: string
    decision*: ApprovalDecision
    approved*: bool
    always*: bool
    prompt*: string
    text*: string

proc runShellCommand(chat: AgentChat, state: var AgentUiState,
    command: string): ShellOutcome =
  ## Executes the built-in slash commands. Unknown commands report quietly
  ## instead of reaching the host as a prompt.
  let name = command.split(' ', 1)[0]
  case name
  of "/help":
    chat.apply notice("help",
      "/clear  clear the transcript\n/quit  exit the shell\n\n" &
      "esc quit · ctrl-c cancel turn · shift-enter newline")
    ShellOutcome(effect: seNone, changed: true)
  of "/clear":
    chat.items.setLen 0
    chat.pendingApproval = ApprovalRequest()
    state.transcript = TranscriptState()
    state.transcript.scroll.anchor = anchorEnd
    ShellOutcome(effect: seNone, changed: true)
  of "/quit", "/q", "/exit":
    ShellOutcome(effect: seQuit)
  else:
    chat.apply notice("unknown", "Unknown command: " & sanitizeText(name) &
      "\n/help lists commands")
    ShellOutcome(effect: seNone, changed: true)


proc handleShellEvent*(chat: AgentChat, state: var AgentUiState,
    event: Event): ShellOutcome =
  ## Routes one event with the documented priority: unconditional quit,
  ## suspend, pending modal, active-turn cancel, then focus routing. Escape
  ## rejects an open approval and otherwise quits; it never approves.
  case event.kind
  of evUser:
    if event.name == "tsuki.agent":
      let drained = chat.drain(4096) > 0
      return ShellOutcome(effect: seNone, changed: drained)
    return ShellOutcome(effect: seNone, changed: false)
  of evResize:
    return ShellOutcome(effect: seNone, changed: true)
  of evTimer, evFocus, evNone:
    return ShellOutcome(effect: seNone, changed: false)
  of evMouse, evPaste, evKey:
    discard
  if event.kind == evKey and event.key.isChar('q', {modCtrl}):
    return ShellOutcome(effect: seQuit)
  if event.isSuspend:
    return ShellOutcome(effect: seSuspend)
  if chat.pendingApproval.id.len > 0:
    # Background interaction stays inert while the modal owns the keys.
    syncApproval(state, chat)
    let decision = state.approval.approvalEvent(chat.pendingApproval, event)
    if decision != approvalNone:
      return ShellOutcome(effect: seApproval, changed: true,
        approvalId: chat.pendingApproval.id, decision: decision,
        approved: decision in {approvalOnce, approvalAlways},
        always: decision == approvalAlways)
    return ShellOutcome(effect: seNone,
      changed: event.kind == evKey)
  if event.kind == evKey and event.key.isChar('c', {modCtrl}):
    if state.transcript.hasSelection:
      let text = state.transcript.selectionText(chat)
      state.transcript.clearSelection()
      return ShellOutcome(effect: seCopy, changed: true, text: text)
    return ShellOutcome(effect: seCancelTurn, changed: true)
  if event.kind == evKey and event.key.isKey(kcEscape):
    return ShellOutcome(effect: seQuit)
  if event.kind == evMouse:
    # Wheel scrolling and text selection reach the transcript from any focus.
    return ShellOutcome(effect: seNone,
      changed: state.transcript.transcriptEvent(chat, event))
  if event.kind == evKey and event.key.isKey(kcTab) and
      state.prompt.completions.len == 0:
    state.focus = if state.focus == focusPrompt: focusTranscript
      else: focusPrompt
    return ShellOutcome(effect: seNone, changed: true)
  if state.focus == focusPrompt:
    let promptResult = state.prompt.promptEvent(event)
    case promptResult.kind
    of promptSubmit:
      if promptResult.text.startsWith("/"):
        return runShellCommand(chat, state, promptResult.text)
      if chat.active:
        if not state.prompt.queuePrompt(promptResult.text):
          chat.apply notice("prompt-queue-full",
            "Prompt queue is full. Wait for the active turn to finish.")
        return ShellOutcome(effect: seNone, changed: true)
      return ShellOutcome(effect: seSubmit, changed: true,
        prompt: promptResult.text)
    of promptCopy:
      return ShellOutcome(effect: seCopy, text: promptResult.text)
    of promptCancel:
      state.focus = focusTranscript
      return ShellOutcome(effect: seNone, changed: true)
    of promptChanged:
      return ShellOutcome(effect: seNone, changed: true)
    of promptIgnored:
      return ShellOutcome(effect: seNone, changed: false)
  return ShellOutcome(effect: seNone,
    changed: state.transcript.transcriptEvent(chat, event))

proc scheduleSpinner(app: var TuiApp, chat: AgentChat,
    options: AgentTuiOptions, spinnerTimer: var TimerId) =
  ## Keeps at most one exact activity deadline alive and none while idle.
  let needed = chat.agentActivity != activityIdle and
    not options.reducedMotion
  if needed and uint64(spinnerTimer) == 0:
    spinnerTimer = app.setTimer(initDuration(milliseconds = 80))
  elif not needed and uint64(spinnerTimer) != 0:
    discard app.cancelTimer(spinnerTimer)
    spinnerTimer = TimerId(0)

proc runAgentTui*(chat: AgentChat, onAction: AgentActionProc,
    options = agentTuiOptions()): TuiResult[RunStats] =
  ## Runs transcript, prompt, status, plan, and approval UI. Worker posts wake
  ## the same blocking reactor; streamed bursts coalesce into one frame. The
  ## spinner uses one exact one-shot timer, never a polling loop.
  if chat.isNil:
    return TuiResult[RunStats](ok: false, error: "agent chat is nil")
  var opened = openTui(options.tui)
  if not opened.ok:
    return TuiResult[RunStats](ok: false, error: opened.error)
  var app = move(opened.value)
  var state = initAgentUiState()
  state.transcript.scroll.anchor = anchorEnd
  chat.attach(app.ui.reactor)
  var spinnerTimer = TimerId(0)
  var redrawTimer = TimerId(0)
  var lastDraw = MonoTime()

  proc drawShell(frame: var Frame) =
    frame.drawAgentShell(chat, state, options)

  proc drawNow() =
    if uint64(redrawTimer) != 0:
      discard app.cancelTimer(redrawTimer)
      redrawTimer = TimerId(0)
    app.draw(drawShell)
    lastDraw = getMonoTime()

  proc requestDraw() =
    ## Coalesces streaming bursts against the configured frame ceiling while
    ## retaining an exact one-shot deadline and no idle timer.
    let interval = initDuration(nanoseconds =
      1_000_000_000 div max(1, app.options.maxFramesPerSecond))
    let earliest = lastDraw + interval
    if getMonoTime() >= earliest:
      drawNow()
    elif uint64(redrawTimer) == 0:
      redrawTimer = app.ui.reactor.setTimerAt(earliest)

  try:
    drawNow()
    scheduleSpinner(app, chat, options, spinnerTimer)
    while app.running:
      # A failed/coalesced reactor notification cannot strand a partial custom
      # AgentChat batch: pending model work is consumed before blocking again.
      let event = if chat.pendingCount > 0: userEvent("tsuki.agent")
        else: app.wait()
      if event.kind == evNone: continue
      if event.kind == evTimer and uint64(redrawTimer) != 0 and
          event.timerId == uint64(redrawTimer):
        redrawTimer = TimerId(0)
        app.draw(drawShell)
        lastDraw = getMonoTime()
        scheduleSpinner(app, chat, options, spinnerTimer)
        continue
      if event.kind == evTimer and uint64(spinnerTimer) != 0 and
          event.timerId == uint64(spinnerTimer):
        spinnerTimer = TimerId(0)
        discard state.spinner.next()
        if app.running:
          requestDraw()
          scheduleSpinner(app, chat, options, spinnerTimer)
        continue
      let outcome = handleShellEvent(chat, state, event)
      case outcome.effect
      of seQuit:
        app.running = false
      of seSuspend:
        let suspended = app.suspend()
        # Timer IDs belong to the terminal/reactor session that was closed.
        spinnerTimer = TimerId(0)
        redrawTimer = TimerId(0)
        if not suspended.ok:
          raise newException(IOError, suspended.error)
        if suspended.value:
          chat.attach(app.ui.reactor)
          drawNow()
      of seApproval:
        chat.pendingApproval = ApprovalRequest()
        onAction AgentAction(kind: aaApproval, approvalId: outcome.approvalId,
          decision: outcome.decision, approved: outcome.approved,
          always: outcome.always)
      of seSubmit:
        chat.active = true
        chat.cancelled = false
        onAction AgentAction(kind: aaSubmit, prompt: outcome.prompt)
      of seCopy:
        onAction AgentAction(kind: aaCopy, text: outcome.text)
      of seCancelTurn:
        onAction AgentAction(kind: aaCancel)
      of seNone:
        discard
      if outcome.changed and app.running:
        requestDraw()
      if not chat.active and chat.pendingApproval.id.len == 0:
        var queuedPrompt: string
        if state.prompt.popQueued(queuedPrompt):
          chat.active = true
          chat.cancelled = false
          onAction AgentAction(kind: aaSubmit, prompt: queuedPrompt)
          requestDraw()
      scheduleSpinner(app, chat, options, spinnerTimer)
    app.close()
    chat.attach(nil)
    TuiResult[RunStats](ok: true, value: app.stats)
  except CatchableError as failure:
    chat.attach(nil)
    try: app.close()
    except CatchableError: discard
    TuiResult[RunStats](ok: false,
      error: "agent TUI failed: " & failure.msg)
