## Provider-neutral durable coding-agent value types.

import std/[strutils, times, unicode]

type
  ProviderId* = distinct string
  ModelId* = distinct string
  SessionId* = distinct string
  TurnId* = distinct string
  MessageId* = distinct string
  ToolCallId* = distinct string
  AttachmentId* = distinct string

  CapabilityState* = enum
    capabilityUnknown
    capabilityUnsupported
    capabilitySupported

  ModelProvenance* = enum
    provenanceConfigured
    provenanceDiscovered
    provenanceCached

  ModelCapabilities* = object
    textInput*: CapabilityState
    imageInput*: CapabilityState
    streaming*: CapabilityState
    tools*: CapabilityState

  ModelDescriptor* = object
    providerId*: ProviderId
    id*: ModelId
    displayName*: string
    capabilities*: ModelCapabilities
    contextWindow*: int64
    maxOutputTokens*: int64
    available*: bool
    unavailableReason*: string
    provenance*: ModelProvenance

  MessageRole* = enum
    messageSystem
    messageUser
    messageAssistant
    messageTool

  MessageStatus* = enum
    messageComplete
    messagePartial
    messageCancelled
    messageError
    messageInterrupted

  AttachmentLocation* = enum
    attachmentWorkspaceRelative
    attachmentExternalAbsolute

  AttachmentState* = enum
    attachmentStaged
    attachmentValidating
    attachmentReady
    attachmentPreviewUnsupported
    attachmentModelUnsupported
    attachmentMissing
    attachmentChanged
    attachmentSending
    attachmentSent
    attachmentFailed

  ImageReference* = object
    id*: AttachmentId
    path*: string
    location*: AttachmentLocation
    displayName*: string
    mediaType*: string
    sizeBytes*: int64
    width*: int
    height*: int
    modifiedAtMs*: int64
    altText*: string
    state*: AttachmentState

  ToolCall* = object
    id*: ToolCallId
    name*: string
    argumentsJson*: string

  ToolResult* = object
    callId*: ToolCallId
    name*: string
    content*: string
    success*: bool
    truncated*: bool
    errorCode*: string

  ContentPartKind* = enum
    contentText
    contentVisibleSummary
    contentImageReference
    contentToolCall
    contentToolResult

  ContentPart* = object
    case kind*: ContentPartKind
    of contentText, contentVisibleSummary:
      text*: string
    of contentImageReference:
      image*: ImageReference
    of contentToolCall:
      toolCall*: ToolCall
    of contentToolResult:
      toolResult*: ToolResult

  NormalizedUsage* = object
    inputTokens*: int64
    outputTokens*: int64
    cachedTokens*: int64
    totalTokens*: int64

  Message* = object
    id*: MessageId
    turnId*: TurnId
    role*: MessageRole
    parts*: seq[ContentPart]
    createdAtMs*: int64
    finishedAtMs*: int64
    status*: MessageStatus
    providerId*: ProviderId
    modelId*: ModelId
    retryOf*: TurnId
    usage*: NormalizedUsage

  TurnState* = enum
    turnIdle
    turnStarting
    turnStreaming
    turnAwaitingTool
    turnRetrying
    turnCancelling
    turnCompleted
    turnFailed
    turnCancelled
    turnInterrupted
    turnShuttingDown

  Session* = object
    schemaVersion*: int
    id*: SessionId
    title*: string
    workspaceRoot*: string
    createdAtMs*: int64
    updatedAtMs*: int64
    providerId*: ProviderId
    modelId*: ModelId
    stagedAttachments*: seq[ImageReference]
    messages*: seq[Message]
    lastTurnState*: TurnState
    archived*: bool

const currentSessionSchemaVersion* = 1

proc `==`*(a, b: ProviderId): bool {.borrow.}
proc `==`*(a, b: ModelId): bool {.borrow.}
proc `==`*(a, b: SessionId): bool {.borrow.}
proc `==`*(a, b: TurnId): bool {.borrow.}
proc `==`*(a, b: MessageId): bool {.borrow.}
proc `==`*(a, b: ToolCallId): bool {.borrow.}
proc `==`*(a, b: AttachmentId): bool {.borrow.}

proc `$`*(value: ProviderId): string {.borrow.}
proc `$`*(value: ModelId): string {.borrow.}
proc `$`*(value: SessionId): string {.borrow.}
proc `$`*(value: TurnId): string {.borrow.}
proc `$`*(value: MessageId): string {.borrow.}
proc `$`*(value: ToolCallId): string {.borrow.}
proc `$`*(value: AttachmentId): string {.borrow.}

func supportedCapabilities*(text = true, image = false, streaming = true,
    tools = false): ModelCapabilities =
  ## Creates an explicit capability set; omitted optional features are false.
  ModelCapabilities(
    textInput: if text: capabilitySupported else: capabilityUnsupported,
    imageInput: if image: capabilitySupported else: capabilityUnsupported,
    streaming: if streaming: capabilitySupported else: capabilityUnsupported,
    tools: if tools: capabilitySupported else: capabilityUnsupported)

func unknownCapabilities*(): ModelCapabilities =
  ModelCapabilities()

proc safeDisplay*(value: string, maxBytes = 1024): string =
  ## Removes controls and bidi overrides while preserving ordinary Unicode.
  if maxBytes <= 0: return ""
  for rune in value.runes:
    let number = int(rune)
    if number == 0x0A or number == 0x09:
      result.add rune.toUTF8
    elif number < 0x20 or number in 0x7F .. 0x9F or
        number in 0x202A .. 0x202E or number in 0x2066 .. 0x2069:
      result.add "�"
    else:
      result.add rune.toUTF8
    if result.len >= maxBytes:
      while result.len > maxBytes:
        result.setLen(result.len - 1)
      while result.len > 0 and validateUtf8(result) >= 0:
        result.setLen(result.len - 1)
      break

func safeId*(value: string, maxBytes = 128): string =
  ## Converts an external identifier to a bounded filename/log-safe value.
  for ch in value:
    if result.len >= maxBytes: break
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', ':'}:
      result.add ch
    elif ch notin {'\0'..' ', '\x7f'}:
      result.add '_'
  result = result.strip(chars = {'-', '_', '.', ':'})

func textPart*(text: string): ContentPart =
  ContentPart(kind: contentText, text: text)

func summaryPart*(text: string): ContentPart =
  ContentPart(kind: contentVisibleSummary, text: text)

func imagePart*(image: ImageReference): ContentPart =
  ContentPart(kind: contentImageReference, image: image)

func availableForProvider*(image: ImageReference): bool =
  image.state notin {attachmentModelUnsupported, attachmentMissing,
    attachmentChanged, attachmentFailed}

func callPart*(call: ToolCall): ContentPart =
  ContentPart(kind: contentToolCall, toolCall: call)

func resultPart*(value: ToolResult): ContentPart =
  ContentPart(kind: contentToolResult, toolResult: value)

proc unixTimeMs*(): int64 =
  let now = getTime()
  now.toUnix * 1_000 + now.nanosecond div 1_000_000

proc messageText*(message: Message): string =
  ## Returns only visible text in content order.
  for part in message.parts:
    if part.kind in {contentText, contentVisibleSummary}:
      result.add part.text

proc initialSessionTitle*(prompt: string): string =
  ## Names a session locally without sending a provider request.
  result = prompt.safeDisplay(80).replace("\n", " ").strip()
  if result.len == 0: result = "New session"

proc newSession*(id: SessionId, workspaceRoot: string,
    providerId = ProviderId(""), modelId = ModelId(""),
    timestampMs = -1'i64): Session =
  let now = if timestampMs >= 0: timestampMs else: unixTimeMs()
  Session(schemaVersion: currentSessionSchemaVersion, id: id,
    title: "New session", workspaceRoot: workspaceRoot,
    createdAtMs: now, updatedAtMs: now,
    providerId: providerId, modelId: modelId, lastTurnState: turnIdle)
