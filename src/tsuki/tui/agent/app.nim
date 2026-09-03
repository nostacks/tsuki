## Ready-to-run, transport-neutral coding-agent shell.

import std/[math, monotimes, strutils, times]
import ../app
import ../[event, geometry, graphemes, reactor, render, scroll, style, terminal,
  text]
import ../widgets/[display, spinner, textarea]
import ../private/writer
import approval, attachment, model, planview, prompt, selector, sessionpicker,
  statusbar, theme, transcript
import ../protocols/clipboard

const agentCommands* = [
  SlashCommand(name: "/model", usage: "/model",
    description: "Choose a provider and model", recommended: true),
  SlashCommand(name: "/sessions", usage: "/sessions",
    description: "Browse saved sessions", recommended: true),
  SlashCommand(name: "/new", usage: "/new",
    description: "Start a durable session", recommended: true),
  SlashCommand(name: "/attach", usage: "/attach <path>",
    description: "Stage an image", recommended: true),
  SlashCommand(name: "/login", usage: "/login",
    description: "Sign in with ChatGPT", recommended: true),
  SlashCommand(name: "/help", usage: "/help",
    description: "Show commands and shortcuts", recommended: true),
  SlashCommand(name: "/retry", usage: "/retry",
    description: "Retry the last turn"),
  SlashCommand(name: "/resume", usage: "/resume [id]",
    description: "Resume an exact session"),
  SlashCommand(name: "/rename", usage: "/rename <title>",
    description: "Rename this session"),
  SlashCommand(name: "/provider", usage: "/provider",
    description: "Sign in or add a provider key"),
  SlashCommand(name: "/detach", usage: "/detach [name]",
    description: "Remove a staged image"),
  SlashCommand(name: "/logout", usage: "/logout",
    description: "Sign out of ChatGPT"),
  SlashCommand(name: "/clear", usage: "/clear",
    description: "Explain durable history"),
  SlashCommand(name: "/quit", usage: "/quit",
    description: "Save and exit")]

type
  AgentActionKind* = enum
    aaSubmit
    aaCancel
    aaApproval
    aaCopy
    aaRetry
    aaNewSession
    aaSessions
    aaResumeSession
    aaRenameSession
    aaProviderSelector
    aaModelSelector
    aaApiKey
    aaAttach
    aaDetach
    aaArchiveSession
    aaLogin
    aaLogout

  AgentAction* = object
    kind*: AgentActionKind
    prompt*: string
    approvalId*: string
    decision*: ApprovalDecision
    approved*: bool
    always*: bool
    text*: string
    argument*: string

  AgentActionProc* = proc (action: AgentAction) {.closure.}

  AgentFocus* = enum
    focusTranscript
    focusPrompt

  AgentActivity* = enum
    activityIdle
    activityThinking
    activityRunning
    activityWaiting

  AgentOverlay* = enum
    overlayNone
    overlayProviders
    overlayModels
    overlaySessions

  AgentTuiOptions* = object
    tui*: TuiOptions
    colors*: AgentTheme
    promptHeight*: int
    showPlan*: bool
    reducedMotion*: bool
    status*: AgentStatus
    selectorEntries*: seq[SelectorEntry]
    authEntries*: seq[ProviderAuthEntry]
    sessionEntries*: seq[SessionPickerEntry]

  AgentUiState* = object
    transcript*: TranscriptState
    prompt*: PromptState
    approval*: ApprovalState
    focus*: AgentFocus
    spinner*: Spinner
    approvalFor*: string
    overlay*: AgentOverlay
    selector*: SelectorState
    auth*: ProviderAuthUi
    sessions*: SessionPickerState
    quitArmed*: bool
    quitArmedAt*: MonoTime

const quitConfirmWindow* = initDuration(seconds = 2)

func quitConfirmActive*(state: AgentUiState, now: MonoTime): bool =
  ## True while the double-ctrl-c exit confirmation is still pending.
  state.quitArmed and now - state.quitArmedAt <= quitConfirmWindow

func agentTuiOptions*(tui = tuiOptions(mouse = true), colors = agentTheme(),
    promptHeight = 3, showPlan = true, reducedMotion = false,
    status = AgentStatus(), selectorEntries: seq[SelectorEntry] = @[],
    authEntries: seq[ProviderAuthEntry] = @[],
    sessionEntries: seq[SessionPickerEntry] = @[]): AgentTuiOptions =
  ## Creates sensible agent-shell defaults without choosing a model transport.
  AgentTuiOptions(tui: tui, colors: colors,
    promptHeight: max(1, promptHeight), showPlan: showPlan,
    reducedMotion: reducedMotion, status: status,
    selectorEntries: selectorEntries, authEntries: authEntries,
    sessionEntries: sessionEntries)

proc initAgentUiState*(): AgentUiState =
  ## Shell state with the safe approval default selected and the built-in
  ## slash commands registered for completion. The composer editor starts
  ## from `initTextareaState` so its selection anchor is explicitly cleared.
  result = AgentUiState(focus: focusPrompt, approval: initApprovalState(),
    spinner: initSpinner(spBraille))
  result.prompt.editor = initTextareaState()
  result.prompt.setCommands(agentCommands)

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
    attachments*: Rect
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
  let attachmentRows = min(min(2, chat.stagedAttachments.len),
    max(0, available - approvalRows - 1))
  # The composer grows with the draft (one row minimum) and shrinks under
  # pressure so the approval card always fits.
  let wanted = max(1, min(options.promptHeight, max(1, draftRows)))
  let promptHeight = min(wanted,
    max(0, available - approvalRows - attachmentRows))
  let bodyHeight = max(0,
    available - approvalRows - attachmentRows - promptHeight)
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
  if attachmentRows > 0:
    result.attachments = rect(inset, y,
      max(1, w - inset - rightInset), attachmentRows)
    inc y, attachmentRows
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

proc drawCommandPopover(frame: Frame, state: PromptState,
    composer: Rect, colors: AgentTheme) =
  ## Draws a compact overlay above the composer without changing shell layout.
  let suggestions = state.slashSuggestions
  if suggestions.len == 0 or composer.y < 4 or frame.rect.width < 24: return
  let rowCount = min(suggestions.len, min(6, max(1, composer.y - 3)))
  let height = rowCount + 3
  let width = min(72, max(24, frame.rect.width - 4))
  let x = clamp(composer.x + 1, 0, max(0, frame.rect.width - width))
  let y = max(0, composer.y - height)
  let title = if state.slashWord.word == "/": "Recommended commands"
    else: "Commands"
  let layer = frame.sub(rect(x, y, width, height))
  layer.clear(rect(0, 0, width, height), colors.base.background)
  let inner = layer.block(title, colors.base.border, rounded = true)
  let selectedIndex = clamp(state.completionIndex, 0, suggestions.high)
  let first = max(0, selectedIndex - rowCount + 1)
  for row in 0 ..< rowCount:
    let index = first + row
    let command = suggestions[index]
    let selected = index == selectedIndex
    let style = if selected: colors.base.selection else: colors.base.text
    if selected:
      inner.clear(rect(0, row, inner.rect.width, 1), style)
    let marker = if selected: "› " else: "  "
    let usageWidth = min(22, max(8, command.usage.cellWidth + 1))
    inner.write(0, row, (marker & command.usage).truncateCells(
      min(inner.rect.width, usageWidth), true), style)
    let detailX = min(inner.rect.width, usageWidth + 1)
    if detailX < inner.rect.width:
      inner.write(detailX, row, command.description.truncateCells(
        inner.rect.width - detailX, true),
        if selected: style else: colors.base.muted)
  if inner.rect.height > rowCount:
    inner.write(0, inner.rect.height - 1,
      "↑↓ move · tab/enter complete · esc close".truncateCells(
        inner.rect.width, true), colors.base.muted)

proc drawAgentShell*(frame: var Frame, chat: AgentChat,
    state: var AgentUiState, options: AgentTuiOptions) =
  ## Draws the whole agent shell: inset transcript, inline approval card,
  ## compact plan, activity or help line, composer, divider, and status.
  syncApproval(state, chat)
  let colors = options.colors
  if state.overlay == overlayProviders:
    let entries = if chat.authLoaded: chat.authEntries
      else: options.authEntries
    frame.providerAuthPicker(entries, state.auth, colors = colors)
    return
  if state.overlay == overlayModels:
    let entries = if chat.selectorLoaded: chat.selectorEntries
      else: options.selectorEntries
    frame.modelSelector(entries, state.selector, colors = colors)
    return
  if state.overlay == overlaySessions:
    let entries = if chat.sessionsLoaded: chat.sessionEntries
      else: options.sessionEntries
    frame.sessionPicker(entries, state.sessions, colors = colors)
    return
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
      if state.quitConfirmActive(getMonoTime()):
        activity.write(0, 0, "press ctrl-c again to exit"
          .truncateCells(activity.rect.width, true), colors.base.warning)
      else:
        activity.write(0, 0, ("esc quit · wheel scroll · enter send")
          .truncateCells(activity.rect.width, true), colors.base.muted)
  if layout.attachments.height > 0:
    for row in 0 ..< min(layout.attachments.height,
        chat.stagedAttachments.len):
      let value = chat.stagedAttachments[row]
      let dimensions = if value.width > 0 and value.height > 0:
        $value.width & "×" & $value.height else: ""
      frame.sub(rect(layout.attachments.x, layout.attachments.y + row,
        layout.attachments.width, 1)).attachmentCard(value, value.state,
        dimensions, value.altText, colors)
  if layout.composer.height > 0:
    frame.sub(layout.composer).prompt(state.prompt,
      state.focus == focusPrompt, colors = colors)
  if layout.divider.height > 0:
    frame.sub(layout.divider).rule(style = colors.base.border)
  if layout.status.height > 0:
    # Dynamic status wins once the controller has published one; the startup
    # fallback must never resurrect a stale offline flag after sign-in or a
    # later model selection.
    let dynamic = chat.status
    let live = dynamic.message.len > 0 or dynamic.provider.len > 0 or
      dynamic.model.len > 0
    let status = AgentStatus(
      provider: if dynamic.provider.len > 0: dynamic.provider
        else: options.status.provider,
      model: if dynamic.model.len > 0: dynamic.model else: options.status.model,
      mode: if dynamic.mode.len > 0: dynamic.mode else: options.status.mode,
      message: if dynamic.message.len > 0: dynamic.message
        else: options.status.message,
      contextUsed: if dynamic.contextUsed > 0: dynamic.contextUsed
        elif not live: options.status.contextUsed else: 0,
      contextLimit: if dynamic.contextLimit > 0: dynamic.contextLimit
        elif not live: options.status.contextLimit else: 0,
      offline: if live: dynamic.offline else: options.status.offline,
      saving: dynamic.saving or options.status.saving)
    frame.sub(layout.status).statusBar(status, chat.usage, colors,
      chat.rateLimit)
  if state.focus == focusPrompt:
    frame.drawCommandPopover(state.prompt, layout.composer, colors)

type
  ShellEffect* = enum
    seNone
    seQuit
    seSuspend
    seCancelTurn
    seApproval
    seSubmit
    seCopy
    seHostAction

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
    actionKind*: AgentActionKind
    argument*: string

proc handleOverlayEvent*(chat: AgentChat, state: var AgentUiState,
    options: AgentTuiOptions, event: Event): ShellOutcome =
  case state.overlay
  of overlayNone:
    discard
  of overlayProviders:
    let entries = if chat.authLoaded: chat.authEntries
      else: options.authEntries
    let outcome = state.auth.providerAuthEvent(entries, event)
    case outcome.kind
    of paDeviceLogin:
      state.overlay = overlayNone
      return ShellOutcome(effect: seHostAction, changed: true,
        actionKind: aaLogin, argument: outcome.entry.providerId)
    of paKeySubmitted:
      # The dialog stays open so the refreshed key status is visible.
      return ShellOutcome(effect: seHostAction, changed: true,
        actionKind: aaApiKey,
        argument: outcome.entry.providerId & "\n" & outcome.apiKey)
    of paCancelled:
      state.overlay = overlayNone
      return ShellOutcome(changed: true)
    of paChanged:
      return ShellOutcome(changed: true)
    of paIgnored:
      return ShellOutcome()
  of overlayModels:
    let entries = if chat.selectorLoaded: chat.selectorEntries
      else: options.selectorEntries
    let outcome = state.selector.selectorEvent(entries, event)
    case outcome.kind
    of selectorConfirmed:
      state.overlay = overlayNone
      return ShellOutcome(effect: seHostAction, changed: true,
        actionKind: aaModelSelector,
        argument: outcome.entry.providerId & "\n" & outcome.entry.modelId)
    of selectorCancelled:
      state.overlay = overlayNone
      return ShellOutcome(changed: true)
    of selectorChanged:
      return ShellOutcome(changed: true)
    of selectorIgnored:
      return ShellOutcome()
  of overlaySessions:
    let entries = if chat.sessionsLoaded: chat.sessionEntries
      else: options.sessionEntries
    let outcome = state.sessions.sessionPickerEvent(entries, event)
    case outcome.kind
    of sessionResume:
      state.overlay = overlayNone
      return ShellOutcome(effect: seHostAction, changed: true,
        actionKind: aaResumeSession, argument: outcome.entry.id)
    of sessionNew:
      state.overlay = overlayNone
      return ShellOutcome(effect: seHostAction, changed: true,
        actionKind: aaNewSession)
    of sessionArchiveRequested:
      state.overlay = overlayNone
      return ShellOutcome(effect: seHostAction, changed: true,
        actionKind: aaArchiveSession, argument: outcome.entry.id)
    of sessionCancelled:
      state.overlay = overlayNone
      return ShellOutcome(changed: true)
    of sessionChanged:
      return ShellOutcome(changed: true)
    of sessionRename:
      state.overlay = overlayNone
      return ShellOutcome(effect: seHostAction, changed: true,
        actionKind: aaRenameSession,
        argument: outcome.entry.id & "\n" & outcome.title)
    of sessionIgnored:
      return ShellOutcome()

proc runShellCommand*(chat: AgentChat, state: var AgentUiState,
    command: string): ShellOutcome =
  ## Executes the built-in slash commands. Unknown commands report quietly
  ## instead of reaching the host as a prompt.
  let pieces = command.split(' ', 1)
  let name = pieces[0]
  let argument = if pieces.len > 1: pieces[1].strip() else: ""
  case name
  of "/help":
    chat.apply notice("help",
      "/new  create a durable session\n" &
      "/sessions  browse saved sessions\n" &
      "/resume [id]  resume an exact session, or open the picker\n" &
      "/rename <title>  rename this session\n" &
      "/provider  sign in or add a provider API key\n" &
      "/model  choose any provider and model\n" &
      "/login, /logout  manage ChatGPT subscription sign-in\n" &
      "/attach <path>, /detach [name]  stage or remove an image\n" &
      "/retry  retry the last user turn\n" &
      "/clear  explain durable-history semantics\n" &
      "/quit  save and exit\n\n" &
      "ctrl-o model selector · ctrl-c twice exits (first press cancels " &
      "the turn) · ctrl-u clears the draft · " &
      "shift-enter or option-enter newline")
    ShellOutcome(effect: seNone, changed: true)
  of "/clear":
    chat.apply notice("clear-durable",
      "Durable history is not cleared in place. Use /new for a fresh session.")
    ShellOutcome(effect: seNone, changed: true)
  of "/quit", "/q", "/exit":
    ShellOutcome(effect: seQuit, changed: true)
  of "/new":
    ShellOutcome(effect: seHostAction, changed: true, actionKind: aaNewSession)
  of "/sessions":
    ShellOutcome(effect: seHostAction, changed: true,
      actionKind: aaSessions)
  of "/resume":
    if argument.len > 0:
      ShellOutcome(effect: seHostAction, changed: true,
        actionKind: aaResumeSession, argument: argument)
    else:
      ShellOutcome(effect: seHostAction, changed: true,
        actionKind: aaSessions)
  of "/rename":
    if argument.len > 0:
      ShellOutcome(effect: seHostAction, changed: true,
        actionKind: aaRenameSession, argument: argument)
    else:
      chat.apply notice("rename-usage", "Usage: /rename <title>")
      ShellOutcome(effect: seNone, changed: true)
  of "/provider":
    ShellOutcome(effect: seHostAction, changed: true,
      actionKind: aaProviderSelector)
  of "/model":
    ShellOutcome(effect: seHostAction, changed: true,
      actionKind: aaModelSelector)
  of "/attach":
    if argument.len > 0:
      ShellOutcome(effect: seHostAction, changed: true,
        actionKind: aaAttach, argument: argument)
    else:
      chat.apply notice("attach-usage", "Usage: /attach <image-path>")
      ShellOutcome(effect: seNone, changed: true)
  of "/detach":
    ShellOutcome(effect: seHostAction, changed: true,
      actionKind: aaDetach, argument: argument)
  of "/retry":
    ShellOutcome(effect: seHostAction, changed: true, actionKind: aaRetry)
  of "/login":
    ShellOutcome(effect: seHostAction, changed: true, actionKind: aaLogin)
  of "/logout":
    ShellOutcome(effect: seHostAction, changed: true, actionKind: aaLogout)
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
  if event.kind == evKey and event.key.isChar('o', {modCtrl}) and
      chat.pendingApproval.id.len == 0:
    return ShellOutcome(effect: seHostAction, changed: true,
      actionKind: aaModelSelector)
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
    # Readline-style exit: the first press cancels a running turn and arms
    # the confirmation, a second press inside the window exits.
    let now = getMonoTime()
    if state.quitConfirmActive(now):
      state.quitArmed = false
      return ShellOutcome(effect: seQuit, changed: true)
    state.quitArmed = true
    state.quitArmedAt = now
    if chat.active:
      return ShellOutcome(effect: seCancelTurn, changed: true)
    return ShellOutcome(effect: seNone, changed: true)
  if event.kind == evKey and event.key.isKey(kcEscape) and
      state.focus == focusPrompt and state.prompt.dismissSuggestions():
    return ShellOutcome(effect: seNone, changed: true)
  if event.kind == evKey and event.key.isKey(kcEscape):
    return ShellOutcome(effect: seQuit)
  if event.kind == evMouse:
    # Wheel scrolling and text selection reach the transcript from any focus.
    # Releasing a selection copies it immediately; the highlight stays until
    # the next press so the copied range remains visible.
    let changed = state.transcript.transcriptEvent(chat, event)
    if event.mouse.action == maRelease and state.transcript.hasSelection:
      return ShellOutcome(effect: seCopy, changed: true,
        text: state.transcript.selectionText(chat))
    return ShellOutcome(effect: seNone, changed: changed)
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
  var quitTimer = TimerId(0)
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
      if event.kind == evTimer and uint64(quitTimer) != 0 and
          event.timerId == uint64(quitTimer):
        quitTimer = TimerId(0)
        if state.quitArmed:
          state.quitArmed = false
          if app.running: requestDraw()
        continue
      let outcome = if event.kind == evKey and
          event.key.isChar('q', {modCtrl}):
        ShellOutcome(effect: seQuit)
      elif event.isSuspend:
        ShellOutcome(effect: seSuspend)
      elif event.kind == evUser and event.name == "tsuki.agent":
        ShellOutcome(changed: chat.drain(4096) > 0)
      elif state.overlay != overlayNone:
        handleOverlayEvent(chat, state, options, event)
      else:
        handleShellEvent(chat, state, event)
      case outcome.effect
      of seQuit:
        app.running = false
      of seSuspend:
        let suspended = app.suspend()
        # Timer IDs belong to the terminal/reactor session that was closed.
        spinnerTimer = TimerId(0)
        redrawTimer = TimerId(0)
        quitTimer = TimerId(0)
        state.quitArmed = false
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
        # Selection copy is the explicit clipboard decision; the OSC 52
        # request is bounded, capability-gated, and fails quietly.
        if outcome.text.len > 0:
          let caps = detectCapabilities(envIdentity())
          let request = encodeClipboardWrite(outcome.text, caps,
            explicitlyAllowed = true)
          if request.accepted:
            try:
              app.ui.w.write cast[seq[byte]](request.bytes)
            except CatchableError:
              discard
        onAction AgentAction(kind: aaCopy, text: outcome.text)
      of seCancelTurn:
        onAction AgentAction(kind: aaCancel)
      of seHostAction:
        if outcome.actionKind == aaProviderSelector and
            outcome.argument.len == 0:
          state.overlay = overlayProviders
          state.auth = ProviderAuthUi()
        elif outcome.actionKind == aaModelSelector and
            outcome.argument.len == 0:
          state.overlay = overlayModels
          state.selector = SelectorState()
        elif outcome.actionKind == aaSessions:
          state.overlay = overlaySessions
          state.sessions = SessionPickerState()
        else:
          onAction AgentAction(kind: outcome.actionKind,
            argument: outcome.argument)
      of seNone:
        discard
      if state.quitArmed and uint64(quitTimer) == 0 and app.running:
        quitTimer = app.setTimer(quitConfirmWindow)
      if not state.quitArmed and uint64(quitTimer) != 0:
        discard app.cancelTimer(quitTimer)
        quitTimer = TimerId(0)
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
