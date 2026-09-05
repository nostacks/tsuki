## Image attachment card with a protocol-independent text fallback.

import ../[render, text]
import ../widgets/display
import model, theme

type AttachmentCardState* = AttachmentViewState

const
  cardStaged* = attachmentViewStaged
  cardReady* = attachmentViewReady
  cardPreviewUnsupported* = attachmentViewPreviewUnsupported
  cardModelUnsupported* = attachmentViewModelUnsupported
  cardMissing* = attachmentViewMissing
  cardChanged* = attachmentViewChanged
  cardSending* = attachmentViewSending
  cardSent* = attachmentViewSent
  cardFailed* = attachmentViewFailed

proc attachmentCard*(frame: Frame, attachment: Attachment,
    state = cardReady, dimensions = "", altText = "",
    colors = agentTheme()) =
  ## Meaning remains available without color or an image terminal protocol.
  let stateLabel = case state
    of cardStaged: "staged"
    of cardReady: "ready"
    of cardPreviewUnsupported: "preview unavailable"
    of cardModelUnsupported: "model does not accept images"
    of cardMissing: "missing"
    of cardChanged: "changed"
    of cardSending: "sending"
    of cardSent: "sent"
    of cardFailed: "failed"
  let size = if attachment.sizeBytes >= 1024:
    $(attachment.sizeBytes div 1024) & " KiB" else: $attachment.sizeBytes & " B"
  frame.write(0, 0, ("Image · " & sanitizeText(attachment.name) & " · " &
    sanitizeText(attachment.mediaType) & " · " & size &
    (if dimensions.len > 0: " · " & sanitizeText(dimensions) else: "") &
    " · " & stateLabel &
    (if altText.len > 0: " · " & sanitizeText(altText) else: ""))
    .truncateCells(frame.rect.width, true),
    if state in {cardMissing, cardChanged, cardModelUnsupported, cardFailed}:
      colors.base.error else: colors.base.text)
  if frame.rect.height > 1 and altText.len > 0:
    frame.write(0, 1, ("Alt: " & sanitizeText(altText)).truncateCells(
      frame.rect.width, true), colors.base.muted)
