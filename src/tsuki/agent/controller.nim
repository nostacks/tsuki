## Single-foreground-turn controller, bounded command queue, tools, and saves.

import std/[locks, monotimes, os, sets, times]
import attachments, context, limits, provider, types
import sessions/store
import tools/[readonly, types as tooltypes]

type
  ControllerCommandKind* = enum
    commandSubmit
    commandCancel
    commandRetry
    commandSelectModel
    commandSwitchSession
    commandNewSession
    commandAttach
    commandDetach
    commandRename
    commandArchive
    commandLogin
    commandLogout
    commandSave
    commandShutdown

  ControllerCommand* = object
    kind*: ControllerCommandKind
    text*: string
    providerId*: ProviderId
    model*: ModelDescriptor
    sessionId*: SessionId
    attachmentId*: AttachmentId
    adapter*: ProviderAdapter
    toolsEnabled*: bool
    toolsConfigured*: bool
    reasoningEffort*: string

  ControllerEventKind* = enum
    controllerUserMessage
    controllerTextDelta
    controllerSummaryDelta
    controllerToolStarted
    controllerToolOutput
    controllerToolFinished
    controllerNotice
    controllerError
    controllerRetrying
    controllerRateLimit
    controllerTurnFinished
    controllerTurnCancelled
    controllerStatus
    controllerAttachmentStaged
    controllerAttachmentDetached
    controllerSessionChanged
    controllerSessionRenamed
    controllerSessionsChanged
    controllerModelsChanged
    controllerConfirmed

  ControllerEvent* = object
    kind*: ControllerEventKind
    id*: string
    parentId*: string
    name*: string
    text*: string
    message*: Message
    attachment*: ImageReference
    usage*: NormalizedUsage
    attempt*: int
    maxAttempts*: int
    delayMs*: int
    rateLimitRemaining*: int64
    rateLimitLimit*: int64
    rateLimitResetAtMs*: int64
    success*: bool
    providerId*: ProviderId
    modelId*: ModelId
    directory*: string
    reasoningEffort*: string
    contextUsed*: int64
    contextLimit*: int64
    offline*: bool
    saving*: bool
    models*: seq[ModelDescriptor]

  ControllerEventProc* = proc (event: ControllerEvent) {.closure, gcsafe.}

  ControllerQueue* = ref object
    lock: Lock
    available: Cond
    items: seq[ControllerCommand]
    head: int
    maxItems: int
    closed: bool

  RetryPolicy* = object
    maxAttempts*: int
    baseDelayMs*: int
    maxDelayMs*: int
    wait*: proc (milliseconds: int,
      token: CancellationToken) {.closure, gcsafe.}

  AgentController* = ref object
    lock: Lock
    commands*: ControllerQueue
    session*: Session
    store*: SessionStore
    adapter*: ProviderAdapter
    model*: ModelDescriptor
    hostToolsEnabled*: bool
    toolPolicy*: ToolHostPolicy
    limits*: AgentLimits
    retryPolicy*: RetryPolicy
    emit*: ControllerEventProc
    staged*: seq[ImageReference]
    state*: TurnState
    activeToken: CancellationToken
    activeTurn: TurnId
    pendingSubmits: int
    contextUsed: int64
    cancelBeforeStart: bool
    shuttingDown: bool
    lastSaveMs: int64
    lastUserTurn: TurnId

proc initControllerQueue*(maxItems = 64): ControllerQueue =
  new(result)
  initLock(result.lock)
  initCond(result.available)
  result.maxItems = max(1, maxItems)

proc post*(queue: ControllerQueue, command: sink ControllerCommand): bool =
  if queue.isNil: return false
  acquire(queue.lock)
  defer: release(queue.lock)
  let used = queue.items.len - queue.head
  let full = if command.kind == commandShutdown: used >= queue.maxItems
    else: used >= max(1, queue.maxItems - 1)
  if queue.closed or full:
    return false
  queue.items.add command
  signal(queue.available)
  true

proc pop*(queue: ControllerQueue, command: var ControllerCommand): bool =
  if queue.isNil: return false
  acquire(queue.lock)
  defer: release(queue.lock)
  while queue.head >= queue.items.len and not queue.closed:
    wait(queue.available, queue.lock)
  if queue.head >= queue.items.len: return false
  command = move(queue.items[queue.head])
  inc queue.head
  if queue.head >= queue.items.len:
    queue.items.setLen 0
    queue.head = 0
  elif queue.head >= 64 and queue.head * 2 >= queue.items.len:
    let remaining = queue.items.len - queue.head
    for index in 0 ..< remaining:
      queue.items[index] = move(queue.items[queue.head + index])
    queue.items.setLen remaining
    queue.head = 0
  true

proc close*(queue: ControllerQueue) =
  if queue.isNil: return
  acquire(queue.lock)
  queue.closed = true
  broadcast(queue.available)
  release(queue.lock)

proc defaultWait(milliseconds: int,
    token: CancellationToken) {.gcsafe.} =
  if token.isNil:
    sleep(max(0, milliseconds))
  else:
    discard token.waitCancel(milliseconds)

func defaultRetryPolicy*(): RetryPolicy =
  RetryPolicy(maxAttempts: 3, baseDelayMs: 500, maxDelayMs: 4_000,
    wait: defaultWait)

proc initAgentController*(session: Session, store: SessionStore,
    adapter: ProviderAdapter, model: ModelDescriptor,
    emit: ControllerEventProc, limits = phase1Limits(),
    retryPolicy = defaultRetryPolicy(), toolsEnabled = true): AgentController =
  new(result)
  initLock(result.lock)
  result.commands = initControllerQueue()
  result.session = session
  discard result.session.refreshAttachmentReferences(limits)
  result.store = store
  result.adapter = adapter
  result.model = model
  result.hostToolsEnabled = toolsEnabled
  result.emit = emit
  result.limits = limits
  result.retryPolicy = retryPolicy
  result.staged = result.session.stagedAttachments
  result.state = if session.lastTurnState == turnInterrupted:
    turnInterrupted else: turnIdle
  result.toolPolicy = defaultToolPolicy(session.workspaceRoot,
    enabled = toolsEnabled and
      model.capabilities.tools != capabilityUnsupported)

proc send(controller: AgentController, event: ControllerEvent) =
  if not controller.emit.isNil: controller.emit(event)

proc postStatus(controller: AgentController, message = "", offline = false,
    saving = false, contextUsed = -1'i64) =
  if contextUsed >= 0: controller.contextUsed = contextUsed
  controller.send ControllerEvent(kind: controllerStatus, text: message,
    providerId: controller.session.providerId,
    modelId: controller.session.modelId, contextUsed: controller.contextUsed,
    directory: controller.session.workspaceRoot,
    reasoningEffort: controller.session.reasoningEffort,
    contextLimit: controller.model.contextWindow, offline: offline,
    saving: saving)

func terminal(state: TurnState): bool =
  state in {turnIdle, turnCompleted, turnFailed, turnCancelled,
    turnInterrupted}

proc transition(controller: AgentController, target: TurnState): bool =
  let current = controller.state
  result = case current
    of turnIdle, turnCompleted, turnFailed, turnCancelled, turnInterrupted:
      target in {turnStarting, turnShuttingDown, turnIdle}
    of turnStarting:
      target in {turnStreaming, turnFailed, turnCancelling, turnShuttingDown}
    of turnStreaming:
      target in {turnAwaitingTool, turnRetrying, turnCompleted, turnFailed,
        turnCancelling, turnShuttingDown}
    of turnAwaitingTool:
      target in {turnStreaming, turnCompleted, turnFailed, turnCancelling,
        turnShuttingDown}
    of turnRetrying:
      target in {turnStreaming, turnFailed, turnCancelling, turnShuttingDown}
    of turnCancelling:
      target in {turnCancelled, turnShuttingDown}
    of turnShuttingDown:
      false
  if result:
    controller.state = target
    controller.session.lastTurnState = target

proc checkpoint(controller: AgentController, force = false): bool =
  let now = unixTimeMs()
  if not force and now - controller.lastSaveMs <
      int64(controller.limits.saveDebounceMs):
    return true
  controller.session.updatedAtMs = now
  controller.postStatus("saving", saving = true)
  let error = controller.store.save(controller.session)
  controller.lastSaveMs = now
  if error.len > 0:
    controller.send ControllerEvent(kind: controllerError,
      id: "save-error", text: error)
    controller.postStatus("save failed")
    return false
  controller.postStatus("saved")
  true

proc freshId(prefix: string): string =
  prefix & ($generateSessionId())[2 .. ^1]

proc assistantIndex(controller: AgentController, turn: TurnId): int =
  for index in countdown(controller.session.messages.len - 1, 0):
    let message = controller.session.messages[index]
    if message.turnId != turn: continue
    if message.role == messageAssistant: return index
    if message.role == messageTool: return -1
  -1

proc ensureAssistant(controller: AgentController, turn: TurnId): int =
  result = controller.assistantIndex(turn)
  if result >= 0: return
  controller.session.messages.add Message(id: MessageId(freshId("m-")),
    turnId: turn, role: messageAssistant, createdAtMs: unixTimeMs(),
    status: messagePartial, providerId: controller.session.providerId,
    modelId: controller.session.modelId)
  result = controller.session.messages.len - 1

proc appendText(controller: AgentController, turn: TurnId, text: string,
    summary = false) =
  let index = controller.ensureAssistant(turn)
  let kind = if summary: contentVisibleSummary else: contentText
  if controller.session.messages[index].parts.len > 0 and
      controller.session.messages[index].parts[^1].kind == kind:
    controller.session.messages[index].parts[^1].text.add text
  else:
    controller.session.messages[index].parts.add(
      if summary: summaryPart(text) else: textPart(text))
  controller.send ControllerEvent(
    kind: if summary: controllerSummaryDelta else: controllerTextDelta,
    id: $controller.session.messages[index].id, parentId: $turn, text: text)

proc finishAttempt(controller: AgentController, turn: TurnId,
    state: TurnState, messageStatus: MessageStatus,
    usage = NormalizedUsage()) =
  let index = controller.assistantIndex(turn)
  if index >= 0:
    controller.session.messages[index].status = messageStatus
    controller.session.messages[index].finishedAtMs = unixTimeMs()
    controller.session.messages[index].usage = usage
  for message in controller.session.messages.mitems:
    if message.turnId == turn and message.role == messageUser:
      for part in message.parts.mitems:
        if part.kind == contentImageReference:
          part.image.state = if state == turnCompleted: attachmentSent
            else: attachmentFailed
  discard controller.transition(state)
  discard controller.checkpoint(force = true)
  # Publishes the post-turn context picture so the status bar reflects the
  # durable session rather than the last streaming estimate.
  controller.postStatus(if state == turnCompleted: "ready" else: "idle",
    contextUsed = if usage.totalTokens > 0: usage.totalTokens else: -1)
  if state == turnCancelled:
    controller.send ControllerEvent(kind: controllerTurnCancelled,
      id: if index >= 0: $controller.session.messages[index].id else: $turn)
  controller.send ControllerEvent(kind: controllerTurnFinished, id: $turn,
    usage: usage, success: state == turnCompleted)
  controller.send ControllerEvent(kind: controllerSessionsChanged,
    text: controller.session.workspaceRoot)
  acquire(controller.lock)
  controller.activeToken = nil
  controller.activeTurn = TurnId("")
  release(controller.lock)

proc executeTools(controller: AgentController, turn: TurnId,
    calls: seq[ToolCall], deadline: MonoTime): bool =
  if calls.len == 0: return true
  if calls.len > 32:
    controller.send ControllerEvent(kind: controllerError,
      id: $turn & ":tool-calls",
      text: "Provider returned more than 32 tool calls in one round.")
    return false
  var callIds = initHashSet[string]()
  for call in calls:
    if $call.id == "" or $call.id in callIds:
      controller.send ControllerEvent(kind: controllerError,
        id: $turn & ":tool-call-id",
        text: "Provider returned an empty or duplicate tool call ID.")
      return false
    callIds.incl $call.id
  discard controller.transition(turnAwaitingTool)
  let callingAssistant = controller.assistantIndex(turn)
  if callingAssistant >= 0:
    controller.session.messages[callingAssistant].status = messageComplete
    controller.session.messages[callingAssistant].finishedAtMs = unixTimeMs()
  for call in calls:
    if controller.activeToken.isCancelled: return false
    if getMonoTime() >= deadline:
      controller.send ControllerEvent(kind: controllerError,
        id: $turn & ":tool-time", text: "Tool time limit reached.")
      return false
    controller.send ControllerEvent(kind: controllerToolStarted,
      id: $call.id, parentId: $turn, name: call.name,
      text: call.argumentsJson.safeDisplay(1024))
    let request = ToolRequest(id: call.id, name: call.name,
      argumentsJson: call.argumentsJson)
    let value = controller.toolPolicy.execute(request)
    controller.send ControllerEvent(kind: controllerToolOutput,
      id: $call.id, text: if value.success: value.content
        else: value.errorMessage)
    controller.send ControllerEvent(kind: controllerToolFinished,
      id: $call.id, success: value.success)
    controller.session.messages.add Message(id: MessageId(freshId("m-")),
      turnId: turn, role: messageTool, parts: @[value.asContentPart],
      createdAtMs: unixTimeMs(), finishedAtMs: unixTimeMs(),
      status: if value.success: messageComplete else: messageError,
      providerId: controller.session.providerId,
      modelId: controller.session.modelId)
    if not controller.checkpoint(force = true): return false
    if getMonoTime() >= deadline and not controller.activeToken.isCancelled:
      controller.send ControllerEvent(kind: controllerError,
        id: $turn & ":tool-time", text: "Tool time limit reached.")
      return false
  discard controller.transition(turnStreaming)
  true

proc clearActive(controller: AgentController) =
  acquire(controller.lock)
  controller.activeToken = nil
  controller.activeTurn = TurnId("")
  release(controller.lock)

proc executeTurn(controller: AgentController, prompt: string,
    retryOf = TurnId(""), fromSubmit = false) =
  ## The token becomes active before any other work so a cancel arriving
  ## between the queue pop and the first provider call is never lost.
  let turn = TurnId(freshId("t-"))
  let token = initCancellationToken()
  acquire(controller.lock)
  if fromSubmit and controller.pendingSubmits > 0:
    dec controller.pendingSubmits
  if controller.cancelBeforeStart:
    controller.cancelBeforeStart = false
    token.cancel()
  controller.activeToken = token
  controller.activeTurn = turn
  release(controller.lock)
  if not controller.state.terminal:
    controller.clearActive()
    controller.send ControllerEvent(kind: controllerNotice,
      id: "turn-busy", text: "A foreground turn is already active.")
    return
  if $controller.model.id == "" or not controller.model.available:
    controller.clearActive()
    controller.send ControllerEvent(kind: controllerError,
      id: "model-unavailable", text: "Select an available model before sending.")
    controller.postStatus("offline", offline = true)
    return
  let now = unixTimeMs()
  var parts = @[textPart(prompt)]
  for attachment in controller.staged:
    if controller.model.capabilities.imageInput == capabilityUnsupported:
      controller.clearActive()
      controller.send ControllerEvent(kind: controllerError,
        id: "image-unsupported", text: "The selected model does not support " &
          "image input.")
      return
    if controller.model.capabilities.imageInput == capabilityUnknown:
      controller.send ControllerEvent(kind: controllerNotice,
        id: "image-capability-unknown", text: "Image support is unknown for " &
          "this model; the provider may reject the attachment.")
    let checked = validateUnchanged(controller.session.workspaceRoot,
      attachment, controller.limits)
    if checked.error.len > 0:
      controller.clearActive()
      controller.send ControllerEvent(kind: controllerError,
        id: "attachment-changed", text: checked.error)
      return
    var sending = checked.attachment
    sending.state = attachmentSending
    parts.add imagePart(sending)
  let user = Message(id: MessageId(freshId("m-")), turnId: turn,
    role: messageUser, parts: parts, createdAtMs: now, finishedAtMs: now,
    status: messageComplete, providerId: controller.session.providerId,
    modelId: controller.session.modelId, retryOf: retryOf)
  controller.session.messages.add user
  controller.lastUserTurn = turn
  if controller.session.messages.len == 1:
    controller.session.title = initialSessionTitle(prompt)
  discard controller.transition(turnStarting)
  var toolDeadline: MonoTime
  controller.toolPolicy.cancelled = proc (): bool {.gcsafe.} =
    token.isCancelled or toolDeadline != MonoTime() and
      getMonoTime() >= toolDeadline
  controller.send ControllerEvent(kind: controllerUserMessage,
    id: $user.id, message: user)
  controller.staged.setLen 0
  controller.session.stagedAttachments.setLen 0
  if not controller.checkpoint(force = true):
    controller.finishAttempt(turn, turnFailed, messageError)
    return

  var rounds = 0
  var usage: NormalizedUsage
  var outputBytes = 0
  var responseLimitExceeded = false
  while rounds <= controller.limits.maxToolRounds:
    if token.isCancelled:
      discard controller.transition(turnCancelling)
      controller.finishAttempt(turn, turnCancelled, messageCancelled, usage)
      return
    var projection = projectRequest(controller.session, controller.model,
      limits = controller.limits,
      toolsEnabled = controller.toolPolicy.enabled)
    if projection.error.len > 0:
      controller.send ControllerEvent(kind: controllerError,
        id: $turn & ":context", text: projection.error)
      controller.finishAttempt(turn, turnFailed, messageError, usage)
      return
    if projection.notice.len > 0:
      controller.send ControllerEvent(kind: controllerNotice,
        id: $turn & ":context", text: projection.notice)
    controller.postStatus("streaming · context estimate",
      contextUsed = projection.estimatedInputBytes div 3)
    let request = ProviderRequest(sessionId: controller.session.id,
      turnId: turn, providerId: controller.session.providerId,
      model: controller.model, workspaceRoot: controller.session.workspaceRoot,
      reasoningEffort: controller.session.reasoningEffort,
      systemInstruction: move(projection.systemInstruction),
      messages: move(projection.messages),
      tools: if controller.toolPolicy.enabled: readOnlyToolDefinitions(
          ) else: @[],
      maxOutputTokens: int(if controller.model.maxOutputTokens > 0:
        min(controller.model.maxOutputTokens, 4096) else: 4096))
    var pendingCalls: seq[ToolCall]
    var accepted = false
    var completed = false
    var attempt = 1
    var failure: ProviderError
    while attempt <= max(1, controller.retryPolicy.maxAttempts):
      if attempt > 1:
        let exponential = min(controller.retryPolicy.maxDelayMs,
          controller.retryPolicy.baseDelayMs shl min(attempt - 2, 16))
        let hinted = if failure.retryAfterMs > 0:
          min(int64(int.high), failure.retryAfterMs).int else: exponential
        let delay = min(controller.retryPolicy.maxDelayMs, hinted)
        discard controller.transition(turnRetrying)
        controller.send ControllerEvent(kind: controllerRetrying,
          id: $turn, text: failure.message, attempt: attempt,
          maxAttempts: controller.retryPolicy.maxAttempts, delayMs: delay)
        if not controller.retryPolicy.wait.isNil:
          controller.retryPolicy.wait(delay, token)
        if token.isCancelled: break
      discard controller.transition(turnStreaming)
      var emittedFailure: ProviderError
      let returnedFailure = controller.adapter.stream(request, token,
        proc (event: ProviderEvent): bool =
        if token.isCancelled: return false
        case event.kind
        of providerStreamStarted: discard
        of providerTextDelta:
          accepted = accepted or event.text.len > 0
          outputBytes += event.text.len
          if outputBytes > controller.limits.maxResponseBytes:
            responseLimitExceeded = true
            token.cancel()
            return false
          controller.appendText(turn, event.text)
          discard controller.checkpoint()
        of providerVisibleSummaryDelta:
          accepted = accepted or event.text.len > 0
          outputBytes += event.text.len
          if outputBytes > controller.limits.maxResponseBytes:
            responseLimitExceeded = true
            token.cancel()
            return false
          controller.appendText(turn, event.text, summary = true)
        of providerToolCall:
          accepted = true
          pendingCalls.add event.toolCall
          let index = controller.ensureAssistant(turn)
          controller.session.messages[index].parts.add callPart(event.toolCall)
        of providerUsage:
          usage = event.usage
          if event.contextLimit > 0:
            controller.model.contextWindow = event.contextLimit
          controller.postStatus("streaming", contextUsed = usage.totalTokens)
        of providerRateLimitUpdate:
          controller.send ControllerEvent(kind: controllerRateLimit,
            rateLimitRemaining: event.rateLimitRemaining,
            rateLimitLimit: event.rateLimitLimit,
            rateLimitResetAtMs: event.rateLimitResetAtMs)
        of providerCompleted: completed = true
        of providerCancelledEvent: token.cancel()
        of providerFailed: emittedFailure = event.error
        true)
      failure = if returnedFailure.ok: emittedFailure else: returnedFailure
      if failure.ok and not completed and not token.isCancelled:
        failure = ProviderError(kind: providerMalformedResponse,
          message: "provider stream ended without completion")
      if responseLimitExceeded:
        controller.send ControllerEvent(kind: controllerError,
          id: $turn & ":response-limit",
          text: "Provider response exceeded the configured byte limit.")
        controller.finishAttempt(turn, turnFailed, messagePartial, usage)
        return
      if token.isCancelled or failure.kind == providerCancelled: break
      if failure.ok and completed: break
      if accepted or not failure.retryable: break
      inc attempt
    if token.isCancelled:
      discard controller.transition(turnCancelling)
      controller.finishAttempt(turn, turnCancelled, messageCancelled, usage)
      return
    if not failure.ok and not completed:
      controller.send ControllerEvent(kind: controllerError,
        id: $turn & ":provider", text: failure.message)
      controller.finishAttempt(turn, turnFailed,
        if accepted: messagePartial else: messageError, usage)
      return
    if pendingCalls.len == 0:
      controller.finishAttempt(turn, turnCompleted, messageComplete, usage)
      return
    inc rounds
    if rounds > controller.limits.maxToolRounds:
      controller.send ControllerEvent(kind: controllerError,
        id: $turn & ":tools", text: "Tool round limit reached.")
      controller.finishAttempt(turn, turnFailed, messagePartial, usage)
      return
    if toolDeadline == MonoTime():
      toolDeadline = getMonoTime() + initDuration(
        milliseconds = controller.limits.maxToolTimeMs)
    if not controller.executeTools(turn, pendingCalls, toolDeadline):
      if token.isCancelled:
        discard controller.transition(turnCancelling)
        controller.finishAttempt(turn, turnCancelled, messageCancelled, usage)
      else:
        controller.finishAttempt(turn, turnFailed, messagePartial, usage)
      return

proc requestCancel*(controller: AgentController): bool =
  ## Cancels directly through the shared token while the worker is streaming.
  acquire(controller.lock)
  let token = controller.activeToken
  release(controller.lock)
  if not token.isNil:
    token.cancel()
    result = true

proc finishProviderOperation(controller: AgentController,
    token: CancellationToken) =
  acquire(controller.lock)
  if controller.activeToken == token: controller.activeToken = nil
  release(controller.lock)

proc login(controller: AgentController, requested: ProviderAdapter) =
  if not controller.state.terminal:
    controller.send ControllerEvent(kind: controllerNotice,
      id: "login-busy",
      text: "Cancel the active turn before signing in.")
    return
  let token = initCancellationToken()
  acquire(controller.lock)
  if not controller.activeToken.isNil:
    release(controller.lock)
    controller.send ControllerEvent(kind: controllerNotice,
      id: "login-busy", text: "Another provider operation is active.")
    return
  controller.activeToken = token
  release(controller.lock)
  defer: controller.finishProviderOperation(token)
  let adapter = if requested.isNil: controller.adapter else: requested
  controller.postStatus("waiting for ChatGPT sign-in")
  let failure = adapter.loginChatGpt(token,
    proc (event: ProviderAuthEvent): bool {.gcsafe.} =
    case event.kind
    of providerAuthPrompt:
      var message = "Open " & event.verificationUrl
      if event.userCode.len > 0:
        message.add "\nEnter code: " & event.userCode
      message.add "\nTsuki is waiting for ChatGPT sign-in."
      controller.send ControllerEvent(kind: controllerNotice,
        id: "chatgpt-login", text: message)
    of providerAuthComplete:
      controller.send ControllerEvent(kind: controllerNotice,
        id: "chatgpt-login-complete", text: event.message)
    not token.isCancelled)
  if token.isCancelled or failure.kind == providerCancelled:
    controller.send ControllerEvent(kind: controllerNotice,
      id: "chatgpt-login-cancelled", text: "ChatGPT sign-in was cancelled.")
    controller.postStatus("sign-in cancelled")
    return
  if not failure.ok:
    controller.send ControllerEvent(kind: controllerError,
      id: "chatgpt-login-error", text: failure.message)
    controller.postStatus("sign-in failed", offline = true)
    return
  let discovered = adapter.refreshModels(token)
  if discovered.error.ok:
    controller.send ControllerEvent(kind: controllerModelsChanged,
      providerId: adapter.id, models: discovered.models)
  else:
    controller.send ControllerEvent(kind: controllerNotice,
      id: "chatgpt-models-error",
      text: "Signed in, but models could not be refreshed: " &
        discovered.error.message)
  controller.postStatus("signed in")

proc logout(controller: AgentController, requested: ProviderAdapter) =
  if not controller.state.terminal:
    controller.send ControllerEvent(kind: controllerNotice,
      id: "logout-busy",
      text: "Cancel the active turn before signing out.")
    return
  let token = initCancellationToken()
  acquire(controller.lock)
  if not controller.activeToken.isNil:
    release(controller.lock)
    controller.send ControllerEvent(kind: controllerNotice,
      id: "logout-busy", text: "Another provider operation is active.")
    return
  controller.activeToken = token
  release(controller.lock)
  defer: controller.finishProviderOperation(token)
  let adapter = if requested.isNil: controller.adapter else: requested
  let failure = adapter.logout(token)
  if failure.ok:
    controller.send ControllerEvent(kind: controllerNotice,
      id: "chatgpt-logout", text: "Signed out of ChatGPT.")
    controller.send ControllerEvent(kind: controllerModelsChanged,
      providerId: adapter.id)
    controller.postStatus("signed out", offline = true)
  elif failure.kind != providerCancelled:
    controller.send ControllerEvent(kind: controllerError,
      id: "chatgpt-logout-error", text: failure.message)

proc emitSession(controller: AgentController) =
  ## Reprojects canonical history after a reset; queue ordering prevents leaks.
  controller.send ControllerEvent(kind: controllerSessionChanged,
    id: $controller.session.id, text: controller.session.title)
  for attachment in controller.staged:
    controller.send ControllerEvent(kind: controllerAttachmentStaged,
      id: $attachment.id, attachment: attachment)
  for message in controller.session.messages:
    case message.role
    of messageUser:
      controller.send ControllerEvent(kind: controllerUserMessage,
        id: $message.id, message: message)
    of messageAssistant:
      for part in message.parts:
        case part.kind
        of contentText:
          controller.send ControllerEvent(kind: controllerTextDelta,
            id: $message.id, parentId: $message.turnId, text: part.text)
        of contentVisibleSummary:
          controller.send ControllerEvent(kind: controllerSummaryDelta,
            id: $message.id, parentId: $message.turnId, text: part.text)
        of contentToolCall:
          controller.send ControllerEvent(kind: controllerToolStarted,
            id: $part.toolCall.id, parentId: $message.turnId,
            name: part.toolCall.name, text: part.toolCall.argumentsJson)
        of contentImageReference, contentToolResult:
          discard
    of messageTool:
      for part in message.parts:
        if part.kind == contentToolResult:
          controller.send ControllerEvent(kind: controllerToolOutput,
            id: $part.toolResult.callId, text: part.toolResult.content)
          controller.send ControllerEvent(kind: controllerToolFinished,
            id: $part.toolResult.callId, success: part.toolResult.success)
    of messageSystem:
      controller.send ControllerEvent(kind: controllerNotice,
        id: $message.id, text: message.messageText)
  controller.send ControllerEvent(kind: controllerTurnFinished,
    id: "session:" & $controller.session.id)
  controller.contextUsed = 0
  for index in countdown(controller.session.messages.len - 1, 0):
    let message = controller.session.messages[index]
    if message.role == messageAssistant:
      controller.contextUsed = max(0'i64, message.usage.totalTokens)
      break
  controller.postStatus("ready")

proc post*(controller: AgentController, command: sink ControllerCommand): bool =
  if controller.isNil: return false
  if command.kind == commandSubmit:
    acquire(controller.lock)
    result = controller.commands.post(command)
    if result: inc controller.pendingSubmits
    release(controller.lock)
    return
  if command.kind == commandCancel:
    if controller.requestCancel(): return true
    acquire(controller.lock)
    if controller.pendingSubmits > 0:
      controller.cancelBeforeStart = true
      release(controller.lock)
      return true
    release(controller.lock)
  if command.kind == commandShutdown:
    discard controller.requestCancel()
  controller.commands.post(command)

proc handle(controller: AgentController, command: ControllerCommand) =
  case command.kind
  of commandSubmit:
    controller.executeTurn(command.text, fromSubmit = true)
  of commandCancel:
    if controller.state.terminal:
      controller.send ControllerEvent(kind: controllerNotice,
        id: "nothing-to-cancel", text: "No turn is running.")
  of commandRetry:
    var prompt = ""
    var source = TurnId("")
    for index in countdown(controller.session.messages.len - 1, 0):
      let message = controller.session.messages[index]
      if message.role == messageUser:
        prompt = message.messageText
        source = message.turnId
        controller.staged.setLen 0
        for part in message.parts:
          if part.kind == contentImageReference:
            controller.staged.add part.image
        controller.session.stagedAttachments = controller.staged
        break
    if prompt.len == 0:
      controller.send ControllerEvent(kind: controllerNotice,
        id: "nothing-to-retry", text: "There is no user turn to retry.")
    else:
      controller.executeTurn(prompt, source)
  of commandSelectModel:
    if not controller.state.terminal:
      controller.send ControllerEvent(kind: controllerNotice,
        id: "model-busy", text: "Cancel the active turn before switching models.")
    elif command.reasoningEffort.len > 0 and
        command.reasoningEffort notin command.model.reasoningEfforts:
      controller.send ControllerEvent(kind: controllerError,
        id: "reasoning-unavailable",
        text: "This model does not support the selected reasoning level.")
    elif not command.model.available:
      controller.send ControllerEvent(kind: controllerError,
        id: "model-unavailable", text: command.model.unavailableReason)
    else:
      let nextAdapter = if not command.adapter.isNil: command.adapter
        elif not controller.adapter.isNil and
            controller.adapter.id == command.model.providerId:
          controller.adapter
        else: nil
      if nextAdapter.isNil or nextAdapter.id != command.model.providerId:
        controller.send ControllerEvent(kind: controllerError,
          id: "provider-unavailable",
          text: "The selected provider adapter is unavailable.")
        return
      controller.adapter = nextAdapter
      controller.model = command.model
      controller.session.reasoningEffort = command.reasoningEffort
      if command.toolsConfigured:
        controller.hostToolsEnabled = command.toolsEnabled
      controller.session.providerId = command.model.providerId
      controller.session.modelId = command.model.id
      controller.toolPolicy.enabled =
        controller.hostToolsEnabled and
        command.model.capabilities.tools != capabilityUnsupported
      discard controller.checkpoint(force = true)
      let validation = controller.adapter.validate()
      if validation.ok:
        controller.postStatus("model selected")
        controller.send ControllerEvent(kind: controllerConfirmed,
          id: "model-selected", text: "Model set to " &
            controller.adapter.displayName & " / " &
            command.model.displayName)
      else:
        controller.postStatus(validation.message, offline = true)
  of commandSwitchSession:
    if not controller.state.terminal:
      discard controller.requestCancel()
      controller.send ControllerEvent(kind: controllerNotice,
        id: "session-busy", text: "Cancel the active turn before switching sessions.")
    else:
      let loaded = controller.store.load(command.sessionId)
      if loaded.error.len > 0:
        controller.send ControllerEvent(kind: controllerError,
          id: "session-load", text: loaded.error)
      else:
        controller.session = loaded.session
        discard controller.session.refreshAttachmentReferences(
          controller.limits)
        controller.staged = controller.session.stagedAttachments
        controller.toolPolicy.workspaceRoot = loaded.session.workspaceRoot
        controller.state = loaded.session.lastTurnState
        if not command.adapter.isNil and
            command.adapter.id == loaded.session.providerId:
          controller.adapter = command.adapter
        if command.toolsConfigured:
          controller.hostToolsEnabled = command.toolsEnabled
        if $command.model.id != "" and
            command.model.providerId == loaded.session.providerId and
            command.model.id == loaded.session.modelId:
          controller.model = command.model
        elif controller.model.providerId != loaded.session.providerId or
            controller.model.id != loaded.session.modelId:
          controller.model = ModelDescriptor(
            providerId: loaded.session.providerId, id: loaded.session.modelId,
            displayName: $loaded.session.modelId, available: false,
            unavailableReason: "The session model is no longer configured.",
            provenance: provenanceCached)
        controller.toolPolicy.enabled = controller.hostToolsEnabled and
          controller.model.capabilities.tools != capabilityUnsupported
        controller.emitSession()
        controller.send ControllerEvent(kind: controllerSessionsChanged,
          text: controller.session.workspaceRoot)
  of commandNewSession:
    if controller.state.terminal:
      discard controller.checkpoint(force = true)
      let effort = controller.session.reasoningEffort
      controller.session = newSession(generateSessionId(),
        controller.session.workspaceRoot, controller.session.providerId,
        controller.session.modelId)
      controller.session.reasoningEffort = effort
      controller.staged.setLen 0
      controller.state = turnIdle
      discard controller.checkpoint(force = true)
      controller.emitSession()
      controller.send ControllerEvent(kind: controllerSessionsChanged,
        text: controller.session.workspaceRoot)
  of commandAttach:
    if controller.staged.len >= 16:
      controller.send ControllerEvent(kind: controllerError,
        id: "attach-limit", text: "At most 16 images may be staged.")
    else:
      let inspected = inspectAttachment(controller.session.workspaceRoot,
        command.text)
      if inspected.error.len > 0:
        controller.send ControllerEvent(kind: controllerError,
          id: "attach-error", text: inspected.error)
        return
      var duplicate = false
      for staged in controller.staged:
        if staged.path == inspected.attachment.path:
          duplicate = true
          break
      if duplicate:
        controller.send ControllerEvent(kind: controllerNotice,
          id: "attach-duplicate", text: "That image is already attached.")
      else:
        controller.staged.add inspected.attachment
        controller.session.stagedAttachments = controller.staged
        controller.send ControllerEvent(kind: controllerAttachmentStaged,
          id: $inspected.attachment.id, attachment: inspected.attachment,
          text: inspected.warning)
        discard controller.checkpoint(force = true)
  of commandDetach:
    var detached: ImageReference
    for index in countdown(controller.staged.len - 1, 0):
      if $command.attachmentId == "" or
          controller.staged[index].id == command.attachmentId or
          controller.staged[index].displayName == command.text:
        detached = controller.staged[index]
        controller.staged.delete(index)
        break
    if $detached.id != "":
      controller.session.stagedAttachments = controller.staged
      controller.send ControllerEvent(kind: controllerAttachmentDetached,
        id: $detached.id, attachment: detached)
      discard controller.checkpoint(force = true)
  of commandRename:
    let target = if $command.sessionId != "": command.sessionId
      else: controller.session.id
    let error = controller.store.rename(target, command.text)
    if error.len > 0:
      controller.send ControllerEvent(kind: controllerError,
        id: "rename-error", text: error)
    elif target == controller.session.id:
      let renamed = controller.store.load(target)
      if renamed.error.len == 0:
        controller.session.title = renamed.session.title
        controller.send ControllerEvent(kind: controllerSessionRenamed,
          id: $target, text: controller.session.title)
    if error.len == 0:
      controller.send ControllerEvent(kind: controllerSessionsChanged,
        text: controller.session.workspaceRoot)
  of commandArchive:
    let target = if $command.sessionId != "": command.sessionId
      else: controller.session.id
    let error = controller.store.archive(target)
    if error.len > 0:
      controller.send ControllerEvent(kind: controllerError,
        id: "archive-error", text: error)
    elif target == controller.session.id:
      controller.session = newSession(generateSessionId(),
        controller.session.workspaceRoot, controller.session.providerId,
        controller.session.modelId)
      controller.staged.setLen 0
      controller.state = turnIdle
      discard controller.checkpoint(force = true)
      controller.emitSession()
    if error.len == 0:
      controller.send ControllerEvent(kind: controllerSessionsChanged,
        text: controller.session.workspaceRoot)
  of commandLogin:
    controller.login(command.adapter)
  of commandLogout:
    controller.logout(command.adapter)
  of commandSave:
    discard controller.checkpoint(force = true)
  of commandShutdown:
    controller.shuttingDown = true
    controller.state = turnShuttingDown
    controller.session.lastTurnState = if $controller.activeTurn != "":
      turnInterrupted else: turnIdle
    discard controller.checkpoint(force = true)
    controller.commands.close()

proc run*(controller: AgentController) =
  ## Blocks without polling until commands arrive, then shuts down deterministically.
  if controller.isNil: return
  var command: ControllerCommand
  while controller.commands.pop(command):
    controller.handle(command)
    if command.kind == commandShutdown: break

proc shutdown*(controller: AgentController) =
  if controller.isNil: return
  discard controller.post ControllerCommand(kind: commandShutdown)
