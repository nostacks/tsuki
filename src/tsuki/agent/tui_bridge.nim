## Safe projection from product controller events to the public he3 facade.

import controller, types
import ../tui/agent as ui
from ../tui/agent/model import agentError

func uiAttachmentState(state: AttachmentState): ui.AttachmentViewState =
  case state
  of attachmentStaged, attachmentValidating: ui.attachmentViewStaged
  of attachmentReady: ui.attachmentViewReady
  of attachmentPreviewUnsupported: ui.attachmentViewPreviewUnsupported
  of attachmentModelUnsupported: ui.attachmentViewModelUnsupported
  of attachmentMissing: ui.attachmentViewMissing
  of attachmentChanged: ui.attachmentViewChanged
  of attachmentSending: ui.attachmentViewSending
  of attachmentSent: ui.attachmentViewSent
  of attachmentFailed: ui.attachmentViewFailed

func uiAttachment(image: ImageReference): ui.Attachment =
  ui.Attachment(id: $image.id, name: image.displayName,
    mediaType: image.mediaType, sizeBytes: image.sizeBytes,
    width: image.width, height: image.height, altText: image.altText,
    state: image.state.uiAttachmentState)

proc uiAttachments(message: Message): seq[ui.Attachment] =
  for part in message.parts:
    if part.kind == contentImageReference:
      result.add part.image.uiAttachment

proc projectSession*(chat: ui.AgentChat, session: Session) =
  ## Rebuilds the transcript from canonical messages without provider fields.
  if chat.isNil: return
  chat.items.setLen 0
  chat.title = session.title.safeDisplay(1024)
  chat.sessionId = $session.id
  chat.stagedAttachments.setLen 0
  for attachment in session.stagedAttachments:
    chat.apply ui.attachmentStaged(attachment.uiAttachment)
  for message in session.messages:
    case message.role
    of messageUser:
      chat.apply ui.userMessage($message.id, message.messageText,
        message.uiAttachments)
    of messageAssistant:
      for part in message.parts:
        case part.kind
        of contentText:
          chat.apply ui.messageDelta($message.id, part.text)
        of contentVisibleSummary:
          chat.apply ui.thinkingDelta($message.id & ":summary", part.text)
        of contentToolCall:
          chat.apply ui.toolStarted($part.toolCall.id, part.toolCall.name,
            part.toolCall.argumentsJson.safeDisplay(1024), $message.turnId)
        of contentToolResult, contentImageReference:
          discard
    of messageTool:
      for part in message.parts:
        if part.kind == contentToolResult:
          chat.apply ui.toolOutput($part.toolResult.callId,
            part.toolResult.content)
          chat.apply ui.toolFinished($part.toolResult.callId,
            part.toolResult.success)
    of messageSystem:
      chat.apply ui.notice($message.id, message.messageText)
  chat.active = false
  chat.cancelled = session.lastTurnState in {turnCancelled, turnInterrupted}

proc tuiEventSink*(chat: ui.AgentChat): ControllerEventProc =
  ## Creates the only controller-to-he3 dependency used by the product host.
  result = proc (event: ControllerEvent) {.gcsafe.} =
    if chat.isNil: return
    case event.kind
    of controllerUserMessage:
      discard chat.post ui.userMessage(event.id, event.message.messageText,
        event.message.uiAttachments)
    of controllerTextDelta:
      discard chat.post ui.messageDelta(event.id, event.text)
    of controllerSummaryDelta:
      discard chat.post ui.thinkingDelta(event.id & ":summary", event.text)
    of controllerToolStarted:
      discard chat.post ui.toolStarted(event.id, event.name, event.text,
        event.parentId)
    of controllerToolOutput:
      discard chat.post ui.toolOutput(event.id, event.text)
    of controllerToolFinished:
      discard chat.post ui.toolFinished(event.id, event.success)
    of controllerNotice:
      discard chat.post ui.notice(event.id, event.text)
    of controllerError:
      discard chat.post agentError(event.id, event.text)
    of controllerRetrying:
      discard chat.post ui.retrying(event.id, ui.RetryInfo(
        attempt: event.attempt, maxAttempts: event.maxAttempts,
        delayMs: event.delayMs, reason: event.text))
    of controllerRateLimit:
      discard chat.post ui.rateLimitUpdated(ui.RateLimit(
        remaining: event.rateLimitRemaining, limit: event.rateLimitLimit,
        resetsAtMs: event.rateLimitResetAtMs))
    of controllerTurnFinished:
      discard chat.post ui.turnFinished(event.id, ui.Usage(
        inputTokens: event.usage.inputTokens,
        outputTokens: event.usage.outputTokens,
        cachedTokens: event.usage.cachedTokens))
    of controllerTurnCancelled:
      discard chat.post ui.turnCancelled(event.id)
    of controllerStatus:
      discard chat.post ui.statusUpdated(ui.AgentViewStatus(
        provider: $event.providerId, model: $event.modelId, mode: "agent",
        message: event.text, contextUsed: event.contextUsed,
        contextLimit: event.contextLimit, offline: event.offline,
        saving: event.saving))
    of controllerAttachmentStaged:
      discard chat.post ui.attachmentStaged(event.attachment.uiAttachment)
      if event.text.len > 0:
        discard chat.post ui.notice(event.id & ":warning", event.text)
    of controllerAttachmentDetached:
      discard chat.post ui.attachmentDetached(event.id)
    of controllerSessionChanged:
      discard chat.post ui.sessionReset(event.id, event.text)
    of controllerSessionRenamed:
      discard chat.post ui.sessionTitleUpdated(event.id, event.text)
    of controllerSessionsChanged, controllerModelsChanged:
      discard
