## Explicit version-1 durable session JSON encoding and bounded decoding.

import std/[json, os, strutils]
import ../[limits, types]

type SessionDecodeResult* = object
  session*: Session
  error*: string
  futureVersion*: bool

func enumValue[T: enum](value: string, fallback: T): T =
  try: parseEnum[T](value)
  except ValueError: fallback

proc imageJson(image: ImageReference): JsonNode =
  %*{"id": $image.id, "path": image.path, "location": $image.location,
    "displayName": image.displayName, "mediaType": image.mediaType,
    "sizeBytes": image.sizeBytes, "width": image.width,
    "height": image.height, "modifiedAtMs": image.modifiedAtMs,
    "altText": image.altText, "state": $image.state}

proc partJson(part: ContentPart): JsonNode =
  case part.kind
  of contentText, contentVisibleSummary:
    %*{"kind": $part.kind, "text": part.text}
  of contentImageReference:
    %*{"kind": $part.kind, "image": part.image.imageJson}
  of contentToolCall:
    %*{"kind": $part.kind, "call": {"id": $part.toolCall.id,
      "name": part.toolCall.name, "argumentsJson":
      part.toolCall.argumentsJson}}
  of contentToolResult:
    %*{"kind": $part.kind, "result": {"callId": $part.toolResult.callId,
      "name": part.toolResult.name, "content": part.toolResult.content,
      "success": part.toolResult.success,
      "truncated": part.toolResult.truncated,
      "errorCode": part.toolResult.errorCode}}

proc messageJson(message: Message): JsonNode =
  var parts = newJArray()
  for part in message.parts: parts.add part.partJson
  %*{"id": $message.id, "turnId": $message.turnId, "role": $message.role,
    "parts": parts, "createdAtMs": message.createdAtMs,
    "finishedAtMs": message.finishedAtMs, "status": $message.status,
    "providerId": $message.providerId, "modelId": $message.modelId,
    "retryOf": $message.retryOf, "usage": {
      "inputTokens": message.usage.inputTokens,
      "outputTokens": message.usage.outputTokens,
      "cachedTokens": message.usage.cachedTokens,
      "totalTokens": message.usage.totalTokens}}

proc encodeSession*(session: Session): string =
  ## Encodes only canonical product state—never credentials or terminal state.
  var messages = newJArray()
  for message in session.messages: messages.add message.messageJson
  var attachments = newJArray()
  for attachment in session.stagedAttachments:
    attachments.add attachment.imageJson
  $(%*{"schemaVersion": currentSessionSchemaVersion,
    "id": $session.id, "title": session.title,
    "workspaceRoot": session.workspaceRoot,
    "createdAtMs": session.createdAtMs, "updatedAtMs": session.updatedAtMs,
    "providerId": $session.providerId, "modelId": $session.modelId,
    "attachments": attachments, "messages": messages,
    "lastTurnState": $session.lastTurnState,
    "archived": session.archived})

proc boundedString(node: JsonNode, key: string, maxBytes: int,
    required = false): string =
  if node.isNil:
    raise newException(ValueError, "missing object for field: " & key)
  if not node.hasKey(key):
    if required: raise newException(ValueError, "missing field: " & key)
    return
  if node[key].kind != JString:
    raise newException(ValueError, "field must be a string: " & key)
  result = node[key].getStr
  if result.len > maxBytes:
    raise newException(ValueError, "field exceeds bound: " & key)

proc parseImage(node: JsonNode): ImageReference =
  if node.isNil or node.kind != JObject:
    raise newException(ValueError, "invalid image")
  result = ImageReference(
    id: AttachmentId(node.boundedString("id", 256, true).safeId(256)),
    path: node.boundedString("path", 32 * 1024, true),
    location: enumValue(node{"location"}.getStr,
      attachmentWorkspaceRelative),
    displayName: node.boundedString("displayName", 4096).safeDisplay(4096),
    mediaType: node.boundedString("mediaType", 128).safeDisplay(128),
    sizeBytes: node{"sizeBytes"}.getInt(0), width: node{"width"}.getInt(0),
    height: node{"height"}.getInt(0),
    modifiedAtMs: node{"modifiedAtMs"}.getInt(0),
    altText: node.boundedString("altText", 4096).safeDisplay(4096),
    state: enumValue(node{"state"}.getStr, attachmentStaged))
  if result.sizeBytes < 0 or result.width < 0 or result.height < 0:
    raise newException(ValueError, "invalid image bounds")

proc parsePart(node: JsonNode): ContentPart =
  if node.isNil or node.kind != JObject:
    raise newException(ValueError, "invalid content part")
  let kind = enumValue(node{"kind"}.getStr, contentText)
  case kind
  of contentText, contentVisibleSummary:
    let text = node.boundedString("text", phase1Limits().maxSessionBytes)
    result = ContentPart(kind: kind, text: text)
  of contentImageReference:
    result = imagePart(parseImage(node{"image"}))
  of contentToolCall:
    let call = node{"call"}
    result = callPart(ToolCall(
      id: ToolCallId(call.boundedString("id", 512, true).safeId(512)),
      name: call.boundedString("name", 256, true).safeId(256),
      argumentsJson: call.boundedString("argumentsJson", 1024 * 1024, true)))
  of contentToolResult:
    let value = node{"result"}
    result = resultPart(ToolResult(
      callId: ToolCallId(value.boundedString("callId", 512, true).safeId(512)),
      name: value.boundedString("name", 256).safeId(256),
      content: value.boundedString("content", phase1Limits(
      ).maxToolOutputBytes),
      success: value{"success"}.getBool,
      truncated: value{"truncated"}.getBool,
      errorCode: value.boundedString("errorCode", 128).safeId(128)))

proc parseMessage(node: JsonNode): Message =
  if node.isNil or node.kind != JObject:
    raise newException(ValueError, "invalid message")
  result = Message(
    id: MessageId(node.boundedString("id", 512, true).safeId(512)),
    turnId: TurnId(node.boundedString("turnId", 512, true).safeId(512)),
    role: enumValue(node{"role"}.getStr, messageUser),
    createdAtMs: node{"createdAtMs"}.getInt(0),
    finishedAtMs: node{"finishedAtMs"}.getInt(0),
    status: enumValue(node{"status"}.getStr, messageError),
    providerId: ProviderId(node.boundedString("providerId", 256).safeId(256)),
    modelId: ModelId(node.boundedString("modelId", 1024).safeDisplay(1024)),
    retryOf: TurnId(node.boundedString("retryOf", 512).safeId(512)))
  let usage = node{"usage"}
  if not usage.isNil and usage.kind == JObject:
    result.usage = NormalizedUsage(
      inputTokens: usage{"inputTokens"}.getInt(0),
      outputTokens: usage{"outputTokens"}.getInt(0),
      cachedTokens: usage{"cachedTokens"}.getInt(0),
      totalTokens: usage{"totalTokens"}.getInt(0))
  let parts = node{"parts"}
  if parts.isNil or parts.kind != JArray:
    raise newException(ValueError, "message parts missing")
  if parts.len > 100_000: raise newException(ValueError, "too many content parts")
  for part in parts: result.parts.add parsePart(part)

proc decodeSession*(source: string,
    limits = phase1Limits()): SessionDecodeResult =
  if source.len > limits.maxSessionBytes:
    result.error = "session exceeds the configured size bound"
    return
  try:
    let root = parseJson(source)
    if root.kind != JObject:
      raise newException(ValueError, "session root must be an object")
    let version = root{"schemaVersion"}.getInt(0)
    if version > currentSessionSchemaVersion:
      result.futureVersion = true
      result.error = "session schema is newer than this Tsuki build"
      return
    if version notin 0 .. currentSessionSchemaVersion:
      result.error = "unsupported session schema"
      return
    result.session = Session(schemaVersion: currentSessionSchemaVersion,
      id: SessionId(root.boundedString("id", 256, true).safeId(256)),
      title: root.boundedString("title", 4096, true).safeDisplay(4096),
      workspaceRoot: root.boundedString("workspaceRoot", 32 * 1024, true),
      createdAtMs: root{"createdAtMs"}.getInt(0),
      updatedAtMs: root{"updatedAtMs"}.getInt(0),
      providerId: ProviderId(root.boundedString("providerId", 256).safeId(256)),
      modelId: ModelId(root.boundedString("modelId", 1024).safeDisplay(1024)),
      lastTurnState: enumValue(root{"lastTurnState"}.getStr, turnInterrupted),
      archived: root{"archived"}.getBool)
    if $result.session.id == "" or result.session.workspaceRoot.len == 0:
      raise newException(ValueError, "session identity is incomplete")
    if not isAbsolute(result.session.workspaceRoot):
      raise newException(ValueError, "session workspace must be absolute")
    result.session.workspaceRoot = normalizedPath(
      result.session.workspaceRoot)
    let attachments = root{"attachments"}
    if not attachments.isNil and attachments.kind == JArray:
      if attachments.len > 16:
        raise newException(ValueError, "session contains too many attachments")
      for attachment in attachments:
        result.session.stagedAttachments.add parseImage(attachment)
    elif not attachments.isNil:
      raise newException(ValueError, "session attachments must be an array")
    let messages = root{"messages"}
    if messages.isNil or messages.kind != JArray:
      raise newException(ValueError, "session messages must be an array")
    if messages.len > 100_000:
      raise newException(ValueError, "session contains too many messages")
    var imageReferences = result.session.stagedAttachments.len
    for message in messages:
      let parsed = parseMessage(message)
      for part in parsed.parts:
        if part.kind == contentImageReference:
          inc imageReferences
          if imageReferences > 1_000:
            raise newException(ValueError,
              "session contains too many image references")
      result.session.messages.add parsed
    if result.session.lastTurnState in {turnStarting, turnStreaming,
        turnAwaitingTool, turnRetrying, turnCancelling}:
      result.session.lastTurnState = turnInterrupted
      for message in result.session.messages.mitems:
        if message.status == messagePartial:
          message.status = messageInterrupted
  except JsonParsingError as failure:
    result.error = "malformed session JSON: " & failure.msg.safeDisplay(1024)
  except CatchableError as failure:
    result.error = "invalid session: " & failure.msg.safeDisplay(1024)
