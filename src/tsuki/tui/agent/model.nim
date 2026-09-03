## Transport-neutral coding-agent state and thread-safe typed events.

import std/[locks, strutils]
import ../[event, reactor, text]
import selector, sessionpicker

type
  AgentRole* = enum
    roleUser
    roleAssistant
    roleSystem

  AgentRisk* = enum
    riskRead
    riskWrite
    riskExecute
    riskNetwork
    riskDestructive

  ToolStatus* = enum
    toolPending
    toolRunning
    toolSuccess
    toolError
    toolCancelled

  TranscriptKind* = enum
    transcriptMessage
    transcriptThinking
    transcriptTool
    transcriptNotice
    transcriptError
    transcriptApproval

  PlanItemState* = enum
    planPending
    planActive
    planComplete
    planFailed

  PlanItem* = object
    id*: string
    text*: string
    state*: PlanItemState

  Usage* = object
    inputTokens*: int64
    outputTokens*: int64
    cachedTokens*: int64
    cost*: float

  Citation* = object
    id*: string
    label*: string
    uri*: string

  AttachmentViewState* = enum
    attachmentViewStaged
    attachmentViewReady
    attachmentViewPreviewUnsupported
    attachmentViewModelUnsupported
    attachmentViewMissing
    attachmentViewChanged
    attachmentViewSending
    attachmentViewSent
    attachmentViewFailed

  Attachment* = object
    id*: string
    name*: string
    mediaType*: string
    sizeBytes*: int64
    width*: int
    height*: int
    altText*: string
    state*: AttachmentViewState

  RateLimit* = object
    remaining*: int64
    limit*: int64
    resetsAtMs*: int64

  RetryInfo* = object
    attempt*: int
    maxAttempts*: int
    delayMs*: int64
    reason*: string

  AgentViewStatus* = object
    provider*: string
    model*: string
    mode*: string
    message*: string
    contextUsed*: int64
    contextLimit*: int64
    offline*: bool
    saving*: bool

  ApprovalRequest* = object
    id*: string
    callId*: string
    command*: string
    paths*: seq[string]
    explanation*: string
    risk*: AgentRisk
    allowAlways*: bool

  TranscriptItem* = object
    id*: string
    parentId*: string
    kind*: TranscriptKind
    role*: AgentRole
    title*: string
    detail*: string
    content*: string
    language*: string
    status*: ToolStatus
    expanded*: bool
    version*: uint64
    startedAtMs*: int64
    finishedAtMs*: int64
    citations*: seq[Citation]
    attachments*: seq[Attachment]
    partial*: bool
    retryable*: bool
    banner*: bool
    background*: bool

  AgentEventKind* = enum
    agentUserMessage
    agentThinkingDelta
    agentMessageDelta
    agentToolStarted
    agentToolOutput
    agentToolFinished
    agentApprovalRequested
    agentPlanUpdated
    agentTurnFinished
    agentNotice
    agentError
    agentCancelled
    agentCitationsUpdated
    agentRateLimitUpdated
    agentRetrying
    agentStatusUpdated
    agentSessionReset
    agentSessionTitleUpdated
    agentSelectorUpdated
    agentAuthUpdated
    agentSessionsUpdated
    agentAttachmentStaged
    agentAttachmentDetached

  AgentEvent* = object
    kind*: AgentEventKind
    id*: string
    parentId*: string
    name*: string
    text*: string
    language*: string
    success*: bool
    status*: ToolStatus
    approval*: ApprovalRequest
    plan*: seq[PlanItem]
    usage*: Usage
    timestampMs*: int64
    citations*: seq[Citation]
    attachments*: seq[Attachment]
    rateLimit*: RateLimit
    retry*: RetryInfo
    viewStatus*: AgentViewStatus
    selectorEntries*: seq[SelectorEntry]
    authEntries*: seq[ProviderAuthEntry]
    sessionEntries*: seq[SessionPickerEntry]
    banner*: bool
    background*: bool

  AgentChange = object
    revision: uint64
    index: int

  AgentChat* = ref object
    ## Application-facing durable session model. Queue fields are private and
    ## protected; transcript fields are read/mutated on the UI thread.
    title*: string
    sessionId*: string
    items*: seq[TranscriptItem]
    plan*: seq[PlanItem]
    pendingApproval*: ApprovalRequest
    usage*: Usage
    rateLimit*: RateLimit
    status*: AgentViewStatus
    stagedAttachments*: seq[Attachment]
    selectorEntries*: seq[SelectorEntry]
    authEntries*: seq[ProviderAuthEntry]
    sessionEntries*: seq[SessionPickerEntry]
    selectorLoaded*: bool
    authLoaded*: bool
    sessionsLoaded*: bool
    active*: bool
    cancelled*: bool
    transcriptRevision*: uint64
    maxToolOutputBytes*: int
    maxMessageBytes*: int
    maxHistoryItems*: int
    lock: Lock
    queue: seq[AgentEvent]
    queueHead: int
    maxQueued: int
    maxQueuedBytes: int
    queuedBytes: int
    wake: Reactor
    closed: bool
    changes: seq[AgentChange]
    changeStart: int
    changeCount: int

proc initAgentChat*(title = "Agent", sessionId = "",
    maxQueued = 4096, maxToolOutputBytes = 1_048_576,
    maxHistoryItems = 100_000, maxQueuedBytes = 8_388_608,
    maxMessageBytes = 4_194_304): AgentChat =
  ## Creates a bounded session model with no model/vendor dependency.
  new(result)
  initLock(result.lock)
  result.title = sanitizeText(title, plainTextPolicy(maxBytes = 1024))
  result.sessionId = sanitizeText(sessionId, plainTextPolicy(maxBytes = 4096))
  result.maxQueued = max(1, maxQueued)
  result.maxQueuedBytes = max(1024, maxQueuedBytes)
  result.maxToolOutputBytes = max(1024, maxToolOutputBytes)
  result.maxMessageBytes = max(1024, maxMessageBytes)
  result.maxHistoryItems = max(1, maxHistoryItems)

proc attach*(chat: AgentChat, wake: Reactor) =
  ## Attaches the UI wake primitive. Safe before or during worker posting.
  acquire(chat.lock)
  chat.wake = wake
  let pending = chat.queueHead < chat.queue.len
  release(chat.lock)
  if pending and not wake.isNil:
    discard wake.post(userEvent("tsuki.agent"))

func userMessage*(turnId, text: string,
    attachments: seq[Attachment] = @[]): AgentEvent =
  AgentEvent(kind: agentUserMessage, id: turnId, text: text,
    attachments: attachments)

func thinkingDelta*(turnId, text: string): AgentEvent =
  AgentEvent(kind: agentThinkingDelta, id: turnId, text: text)

func messageDelta*(turnId, text: string): AgentEvent =
  AgentEvent(kind: agentMessageDelta, id: turnId, text: text)

func toolStarted*(callId, name: string, detail = "",
    parentId = "", background = false): AgentEvent =
  AgentEvent(kind: agentToolStarted, id: callId, parentId: parentId,
    name: name, text: detail, status: toolRunning, background: background)

func toolOutput*(callId, chunk: string, language = ""): AgentEvent =
  ## Streams one bounded output chunk. An optional language tags specialized
  ## rendering such as diffs or source; only the first chunk needs to carry it.
  AgentEvent(kind: agentToolOutput, id: callId, text: chunk,
    language: language)

func toolFinished*(callId: string, success = true,
    timestampMs = 0'i64): AgentEvent =
  AgentEvent(kind: agentToolFinished, id: callId, success: success,
    status: if success: toolSuccess else: toolError,
    timestampMs: timestampMs)

func approvalRequested*(callId, command: string, risk = riskWrite,
    paths: seq[string] = @[], explanation = "",
    allowAlways = false): AgentEvent =
  AgentEvent(kind: agentApprovalRequested, id: callId,
    approval: ApprovalRequest(id: callId, callId: callId,
      command: command, paths: paths, explanation: explanation,
      risk: risk, allowAlways: allowAlways))

func planUpdated*(items: seq[PlanItem]): AgentEvent =
  AgentEvent(kind: agentPlanUpdated, plan: items)

func turnFinished*(turnId: string, usage = Usage()): AgentEvent =
  AgentEvent(kind: agentTurnFinished, id: turnId, usage: usage)

func notice*(id, text: string, banner = false): AgentEvent =
  ## A subdued system row. `banner` marks multi-line welcome cards whose first
  ## line renders in the accent color.
  AgentEvent(kind: agentNotice, id: id, text: text, banner: banner)

func agentError*(id, text: string): AgentEvent =
  AgentEvent(kind: agentError, id: id, text: text, success: false)

func turnCancelled*(turnId: string): AgentEvent =
  AgentEvent(kind: agentCancelled, id: turnId)

func citationsUpdated*(itemId: string,
    citations: seq[Citation]): AgentEvent =
  AgentEvent(kind: agentCitationsUpdated, id: itemId, citations: citations)

func rateLimitUpdated*(value: RateLimit): AgentEvent =
  AgentEvent(kind: agentRateLimitUpdated, rateLimit: value)

func retrying*(turnId: string, info: RetryInfo): AgentEvent =
  AgentEvent(kind: agentRetrying, id: turnId, retry: info)

func statusUpdated*(status: AgentViewStatus): AgentEvent =
  AgentEvent(kind: agentStatusUpdated, viewStatus: status)

func sessionReset*(sessionId, title: string): AgentEvent =
  AgentEvent(kind: agentSessionReset, id: sessionId, text: title)

func sessionTitleUpdated*(sessionId, title: string): AgentEvent =
  AgentEvent(kind: agentSessionTitleUpdated, id: sessionId, text: title)

func selectorUpdated*(entries: seq[SelectorEntry]): AgentEvent =
  AgentEvent(kind: agentSelectorUpdated, selectorEntries: entries)

func authUpdated*(entries: seq[ProviderAuthEntry]): AgentEvent =
  AgentEvent(kind: agentAuthUpdated, authEntries: entries)

func sessionsUpdated*(entries: seq[SessionPickerEntry]): AgentEvent =
  AgentEvent(kind: agentSessionsUpdated, sessionEntries: entries)

func attachmentStaged*(attachment: Attachment): AgentEvent =
  AgentEvent(kind: agentAttachmentStaged, attachments: @[attachment])

func attachmentDetached*(id: string): AgentEvent =
  AgentEvent(kind: agentAttachmentDetached, id: id)

func canCoalesce(previous, next: AgentEvent): bool =
  previous.kind == next.kind and previous.id == next.id and
    next.kind in {agentThinkingDelta, agentMessageDelta, agentToolOutput}

func eventFootprint(event: AgentEvent, limit: int): int =
  ## Counts retained payload bytes with a small allowance for sequence/object
  ## metadata. Returning -1 means the configured queue byte bound was exceeded.
  result = 128
  template addAmount(amount: int) =
    if amount < 0 or result > limit - min(limit, amount):
      return -1
    result += amount
  template addString(value: string) =
    addAmount(value.len)
  addString event.id
  addString event.parentId
  addString event.name
  addString event.text
  addString event.language
  addString event.approval.id
  addString event.approval.callId
  addString event.approval.command
  addString event.approval.explanation
  for path in event.approval.paths:
    addAmount 32
    addString path
  for item in event.plan:
    addAmount 32
    addString item.id
    addString item.text
  for citation in event.citations:
    addAmount 48
    addString citation.id
    addString citation.label
    addString citation.uri
  for attachment in event.attachments:
    addAmount 48
    addString attachment.id
    addString attachment.name
    addString attachment.mediaType
    addString attachment.altText
  addString event.retry.reason
  addString event.viewStatus.provider
  addString event.viewStatus.model
  addString event.viewStatus.mode
  addString event.viewStatus.message
  for entry in event.selectorEntries:
    addAmount 64
    addString entry.providerId
    addString entry.providerName
    addString entry.modelId
    addString entry.displayName
    addString entry.reason
  for entry in event.authEntries:
    addAmount 64
    addString entry.providerId
    addString entry.providerName
    addString entry.credentialEnv
    addString entry.detail
  for entry in event.sessionEntries:
    addAmount 64
    addString entry.id
    addString entry.title
    addString entry.workspace
    addString entry.updatedLabel
    addString entry.providerModel
    addString entry.diagnostic

proc post*(chat: AgentChat, posted: sink AgentEvent): bool =
  ## Posts safely from a worker. Count and byte bounds apply before adjacent
  ## deltas merge, and only the empty-to-nonempty transition emits a wake.
  if chat.isNil: return false
  var wake: Reactor
  var shouldWake = false
  acquire(chat.lock)
  if chat.closed:
    release(chat.lock)
    return false
  let queued = chat.queue.len - chat.queueHead
  if chat.queue.len > chat.queueHead and chat.queue[^1].canCoalesce(posted):
    let extra = posted.text.len + (if chat.queue[^1].language.len == 0:
      posted.language.len else: 0)
    if extra > chat.maxQueuedBytes - chat.queuedBytes:
      release(chat.lock)
      return false
    chat.queue[^1].text.add posted.text
    if chat.queue[^1].language.len == 0:
      chat.queue[^1].language = posted.language
    chat.queuedBytes += extra
    release(chat.lock)
    return true
  let footprint = eventFootprint(posted, chat.maxQueuedBytes)
  if queued >= chat.maxQueued or footprint < 0 or
      footprint > chat.maxQueuedBytes - chat.queuedBytes:
    release(chat.lock)
    return false
  shouldWake = queued == 0
  chat.queue.add posted
  chat.queuedBytes += footprint
  wake = chat.wake
  release(chat.lock)
  if shouldWake and not wake.isNil:
    discard wake.post(userEvent("tsuki.agent"))
  true

proc pop*(chat: AgentChat, event: var AgentEvent): bool =
  ## Pops one queued typed event in O(1).
  if chat.isNil: return false
  acquire(chat.lock)
  defer: release(chat.lock)
  if chat.queueHead >= chat.queue.len: return false
  let footprint = eventFootprint(chat.queue[chat.queueHead],
    chat.maxQueuedBytes)
  event = move(chat.queue[chat.queueHead])
  if footprint >= 0:
    chat.queuedBytes = max(0, chat.queuedBytes - footprint)
  else:
    chat.queuedBytes = 0
  inc chat.queueHead
  if chat.queueHead >= chat.queue.len:
    chat.queue.setLen 0
    chat.queueHead = 0
  elif chat.queueHead >= 1024 and chat.queueHead * 2 >= chat.queue.len:
    let remaining = chat.queue.len - chat.queueHead
    for index in 0 ..< remaining:
      chat.queue[index] = move(chat.queue[chat.queueHead + index])
    chat.queue.setLen remaining
    chat.queueHead = 0
  true

proc pendingCount*(chat: AgentChat): int =
  ## Returns the number of typed events awaiting the UI thread.
  if chat.isNil: return 0
  acquire(chat.lock)
  result = chat.queue.len - chat.queueHead
  release(chat.lock)

func findItem(chat: AgentChat, id: string, kind: TranscriptKind): int =
  for index in countdown(chat.items.len - 1, 0):
    if chat.items[index].id == id and chat.items[index].kind == kind:
      return index
  -1

func findItem(chat: AgentChat, id: string): int =
  for index in countdown(chat.items.len - 1, 0):
    if chat.items[index].id == id: return index
  -1

proc recordChange(chat: AgentChat, index: int) =
  const capacity = 4096
  inc chat.transcriptRevision
  if chat.changes.len == 0:
    chat.changes = newSeq[AgentChange](capacity)
  let slot = (chat.changeStart + chat.changeCount) mod capacity
  chat.changes[slot] = AgentChange(revision: chat.transcriptRevision,
    index: max(0, index))
  if chat.changeCount < capacity:
    inc chat.changeCount
  else:
    chat.changeStart = (chat.changeStart + 1) mod capacity

proc changesSince*(chat: AgentChat, revision: uint64,
    firstChanged: var int): bool =
  ## Finds the first transcript item changed after `revision`. Returns false
  ## when the caller's revision predates the bounded change journal.
  firstChanged = chat.items.len
  if revision == chat.transcriptRevision:
    return true
  if chat.changeCount == 0:
    return false
  let oldest = chat.changes[chat.changeStart].revision
  if revision + 1 < oldest:
    return false
  for offset in 0 ..< chat.changeCount:
    let change = chat.changes[(chat.changeStart + offset) mod chat.changes.len]
    if change.revision > revision:
      firstChanged = min(firstChanged, change.index)
  true

proc toggleExpanded*(chat: AgentChat, index: int): bool =
  ## Toggles one collapsible transcript item and journals the layout change.
  if chat.isNil or index < 0 or index >= chat.items.len:
    return false
  chat.items[index].expanded = not chat.items[index].expanded
  inc chat.items[index].version
  chat.recordChange(index)
  true

proc appendItem(chat: AgentChat, item: sink TranscriptItem): int =
  var changedFrom = chat.items.len
  if chat.items.len >= chat.maxHistoryItems:
    # History retention is bounded. This compaction occurs only at the configured
    # retention boundary, never on the per-frame visible path.
    let removeCount = max(1, chat.maxHistoryItems div 10)
    let removed = min(removeCount, chat.items.len)
    for index in removed ..< chat.items.len:
      chat.items[index - removed] = move(chat.items[index])
    chat.items.setLen(chat.items.len - removed)
    changedFrom = 0
  chat.items.add item
  result = chat.items.len - 1
  chat.recordChange(min(changedFrom, result))

proc safeAttachments(values: openArray[Attachment]): seq[Attachment] =
  for value in values:
    result.add Attachment(id: sanitizeText(value.id,
      plainTextPolicy(maxBytes = 4096)), name: sanitizeText(value.name,
      plainTextPolicy(maxBytes = 4096)), mediaType: sanitizeText(
      value.mediaType, plainTextPolicy(maxBytes = 128)),
      sizeBytes: max(0'i64, value.sizeBytes), width: max(0, value.width),
      height: max(0, value.height), altText: sanitizeText(value.altText,
      plainTextPolicy(maxBytes = 4096)), state: value.state)

proc apply*(chat: AgentChat, event: AgentEvent) =
  ## Applies one event on the UI thread, preserving stable IDs and versions.
  let safeText = sanitizeText(event.text)
  case event.kind
  of agentUserMessage:
    discard chat.appendItem TranscriptItem(id: event.id,
      kind: transcriptMessage,
      role: roleUser, content: safeText, expanded: true, version: 1,
      attachments: safeAttachments(event.attachments))
    chat.active = true
    chat.cancelled = false
    chat.stagedAttachments.setLen 0
  of agentThinkingDelta, agentMessageDelta:
    let itemKind = if event.kind == agentThinkingDelta: transcriptThinking
      else: transcriptMessage
    var index = chat.findItem(event.id, itemKind)
    if index < 0:
      discard chat.appendItem TranscriptItem(id: event.id, kind: itemKind,
        role: roleAssistant, expanded: true, version: 1,
        parentId: event.parentId)
      index = chat.items.len - 1
    let remaining = max(0, chat.maxMessageBytes -
      chat.items[index].content.len)
    if remaining > 0:
      chat.items[index].content.add sanitizeText(safeText,
        plainTextPolicy(maxBytes = remaining))
    if safeText.len > remaining and not chat.items[index].content.endsWith(
        "\n… output truncated"):
      chat.items[index].content.add "\n… output truncated"
    inc chat.items[index].version
    chat.recordChange(index)
    chat.active = true
  of agentToolStarted:
    discard chat.appendItem TranscriptItem(id: event.id, kind: transcriptTool,
      role: roleAssistant, title: sanitizeText(event.name), detail: safeText,
      status: toolRunning, expanded: true, version: 1,
      startedAtMs: event.timestampMs, parentId: event.parentId,
      background: event.background)
    if not event.background:
      chat.active = true
  of agentToolOutput:
    let index = chat.findItem(event.id, transcriptTool)
    if index >= 0:
      if event.language.len > 0 and chat.items[index].language.len == 0:
        chat.items[index].language = sanitizeText(event.language,
          plainTextPolicy(maxBytes = 128))
      let remaining = max(0, chat.maxToolOutputBytes -
        chat.items[index].content.len)
      if remaining > 0:
        chat.items[index].content.add sanitizeText(event.text,
          plainTextPolicy(maxBytes = remaining))
      if event.text.len > remaining and not chat.items[index].content.endsWith(
          "\n… output truncated"):
        chat.items[index].content.add "\n… output truncated"
      inc chat.items[index].version
      chat.recordChange(index)
  of agentToolFinished:
    let index = chat.findItem(event.id, transcriptTool)
    if index >= 0:
      chat.items[index].status = event.status
      chat.items[index].finishedAtMs = event.timestampMs
      inc chat.items[index].version
      chat.recordChange(index)
  of agentApprovalRequested:
    # One presentation only: the modal overlay. No live transcript duplicate.
    chat.pendingApproval = event.approval
    chat.pendingApproval.command = sanitizeText(event.approval.command,
      plainTextPolicy(maxBytes = 65_536))
    chat.pendingApproval.explanation = sanitizeText(
      event.approval.explanation, plainTextPolicy(maxBytes = 65_536))
    chat.pendingApproval.paths.setLen 0
    for path in event.approval.paths:
      chat.pendingApproval.paths.add sanitizeText(path,
        plainTextPolicy(maxBytes = 4096))
  of agentPlanUpdated:
    chat.plan = event.plan
  of agentTurnFinished:
    chat.usage = event.usage
    chat.active = false
  of agentNotice:
    discard chat.appendItem TranscriptItem(id: event.id, kind: transcriptNotice,
      role: roleSystem, title: "Notice", content: safeText,
      expanded: true, version: 1, banner: event.banner)
  of agentError:
    discard chat.appendItem TranscriptItem(id: event.id, kind: transcriptError,
      role: roleSystem, title: "Error", content: safeText,
      status: toolError, expanded: true, version: 1)
    chat.active = false
  of agentCancelled:
    chat.cancelled = true
    chat.active = false
    let index = chat.findItem(event.id)
    if index >= 0:
      chat.items[index].partial = true
      inc chat.items[index].version
      chat.recordChange(index)
  of agentCitationsUpdated:
    let index = chat.findItem(event.id)
    if index >= 0:
      chat.items[index].citations.setLen 0
      for citation in event.citations:
        if citation.uri.safeUri:
          chat.items[index].citations.add Citation(
            id: sanitizeText(citation.id), label: sanitizeText(citation.label),
            uri: citation.uri)
      inc chat.items[index].version
      chat.recordChange(index)
  of agentRateLimitUpdated:
    chat.rateLimit = event.rateLimit
  of agentRetrying:
    discard chat.appendItem TranscriptItem(id: event.id & ":retry:" &
      $event.retry.attempt, kind: transcriptNotice, role: roleSystem,
      title: "Retrying", content: sanitizeText(event.retry.reason),
      expanded: true, version: 1, retryable: true)
  of agentStatusUpdated:
    chat.status = AgentViewStatus(
      provider: sanitizeText(event.viewStatus.provider,
        plainTextPolicy(maxBytes = 256)),
      model: sanitizeText(event.viewStatus.model,
        plainTextPolicy(maxBytes = 1024)),
      mode: sanitizeText(event.viewStatus.mode,
        plainTextPolicy(maxBytes = 128)),
      message: sanitizeText(event.viewStatus.message,
        plainTextPolicy(maxBytes = 1024)),
      contextUsed: max(0'i64, event.viewStatus.contextUsed),
      contextLimit: max(0'i64, event.viewStatus.contextLimit),
      offline: event.viewStatus.offline, saving: event.viewStatus.saving)
  of agentSessionReset:
    chat.items.setLen 0
    chat.plan.setLen 0
    chat.pendingApproval = ApprovalRequest()
    chat.stagedAttachments.setLen 0
    chat.title = sanitizeText(event.text, plainTextPolicy(maxBytes = 1024))
    chat.sessionId = sanitizeText(event.id,
      plainTextPolicy(maxBytes = 4096))
    chat.active = false
    chat.cancelled = false
    chat.transcriptRevision = 0
    chat.changeCount = 0
    chat.changeStart = 0
  of agentSessionTitleUpdated:
    if event.id == chat.sessionId:
      chat.title = sanitizeText(event.text, plainTextPolicy(maxBytes = 1024))
  of agentSelectorUpdated:
    chat.selectorEntries.setLen 0
    for entry in event.selectorEntries:
      chat.selectorEntries.add SelectorEntry(
        providerId: sanitizeText(entry.providerId,
          plainTextPolicy(maxBytes = 256)),
        providerName: sanitizeText(entry.providerName,
          plainTextPolicy(maxBytes = 512)),
        modelId: sanitizeText(entry.modelId,
          plainTextPolicy(maxBytes = 1024)),
        displayName: sanitizeText(entry.displayName,
          plainTextPolicy(maxBytes = 1024)),
        imageInput: entry.imageInput, tools: entry.tools,
        available: entry.available,
        reason: sanitizeText(entry.reason,
          plainTextPolicy(maxBytes = 2048)))
    chat.selectorLoaded = true
  of agentAuthUpdated:
    chat.authEntries.setLen 0
    for entry in event.authEntries:
      chat.authEntries.add ProviderAuthEntry(
        providerId: sanitizeText(entry.providerId,
          plainTextPolicy(maxBytes = 256)),
        providerName: sanitizeText(entry.providerName,
          plainTextPolicy(maxBytes = 512)),
        kind: entry.kind, status: entry.status,
        credentialEnv: sanitizeText(entry.credentialEnv,
          plainTextPolicy(maxBytes = 256)),
        detail: sanitizeText(entry.detail,
          plainTextPolicy(maxBytes = 2048)))
    chat.authLoaded = true
  of agentSessionsUpdated:
    chat.sessionEntries.setLen 0
    for entry in event.sessionEntries:
      chat.sessionEntries.add SessionPickerEntry(
        id: sanitizeText(entry.id, plainTextPolicy(maxBytes = 4096)),
        title: sanitizeText(entry.title, plainTextPolicy(maxBytes = 4096)),
        workspace: sanitizeText(entry.workspace,
          plainTextPolicy(maxBytes = 32 * 1024)),
        updatedLabel: sanitizeText(entry.updatedLabel,
          plainTextPolicy(maxBytes = 256)),
        providerModel: sanitizeText(entry.providerModel,
          plainTextPolicy(maxBytes = 2048)),
        interrupted: entry.interrupted, corrupt: entry.corrupt,
        diagnostic: sanitizeText(entry.diagnostic,
          plainTextPolicy(maxBytes = 4096)))
    chat.sessionsLoaded = true
  of agentAttachmentStaged:
    let values = safeAttachments(event.attachments)
    if values.len > 0:
      var replaced = false
      for attachment in chat.stagedAttachments.mitems:
        if attachment.id == values[0].id:
          attachment = values[0]
          replaced = true
          break
      if not replaced:
        chat.stagedAttachments.add values[0]
  of agentAttachmentDetached:
    let safeId = sanitizeText(event.id, plainTextPolicy(maxBytes = 4096))
    for index in countdown(chat.stagedAttachments.len - 1, 0):
      if chat.stagedAttachments[index].id == safeId:
        chat.stagedAttachments.delete(index)
        break

proc drain*(chat: AgentChat, maxEvents = 256): int =
  ## Applies a bounded event batch and returns the number consumed. If work
  ## remains, another coalesced wake is posted so a large custom queue cannot
  ## become stranded after the shell's batch limit.
  var event: AgentEvent
  while result < max(1, maxEvents) and chat.pop(event):
    chat.apply(event)
    inc result
  var wake: Reactor
  acquire(chat.lock)
  let pending = chat.queueHead < chat.queue.len
  wake = chat.wake
  release(chat.lock)
  if pending and not wake.isNil:
    discard wake.post(userEvent("tsuki.agent"))

proc close*(chat: AgentChat) =
  ## Rejects future posts. Retained worker references remain safe.
  if chat.isNil: return
  acquire(chat.lock)
  chat.closed = true
  chat.wake = nil
  chat.queue.setLen 0
  chat.queueHead = 0
  chat.queuedBytes = 0
  release(chat.lock)
