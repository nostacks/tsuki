## Explicit version-1 durable session JSON encoding and bounded decoding.

import std/[json, os, parsejson, streams, strutils]
import ../[limits, types]

type
  SessionDecodeResult* = object
    session*: Session
    error*: string
    futureVersion*: bool

  SessionHeader* = object
    ## The listing view of one session document, decoded without building
    ## its messages.
    id*: SessionId
    title*: string
    workspaceRoot*: string
    updatedAtMs*: int64
    providerId*: ProviderId
    modelId*: ModelId
    interrupted*: bool
    archived*: bool

  SessionHeaderResult* = object
    header*: SessionHeader
    error*: string
    futureVersion*: bool

const
  inFlightStates = {turnStarting, turnStreaming, turnAwaitingTool,
    turnRetrying, turnCancelling}
  maxNestingDepth = 256

func enumValue[T: enum](value: string, fallback: T): T =
  try: parseEnum[T](value)
  except ValueError: fallback

proc putKey(output: var string, key: string) =
  if output[^1] notin {'{', '['}: output.add ','
  output.add '"'
  output.add key
  output.add "\":"

proc putString(output: var string, key, value: string) =
  output.putKey key
  escapeJson(value, output)

proc putInt(output: var string, key: string, value: int64) =
  output.putKey key
  output.addInt value

proc putBool(output: var string, key: string, value: bool) =
  output.putKey key
  output.add(if value: "true" else: "false")

proc putImage(output: var string, image: ImageReference) =
  output.add '{'
  output.putString "id", $image.id
  output.putString "path", image.path
  output.putString "location", $image.location
  output.putString "displayName", image.displayName
  output.putString "mediaType", image.mediaType
  output.putInt "sizeBytes", image.sizeBytes
  output.putInt "width", image.width
  output.putInt "height", image.height
  output.putInt "modifiedAtMs", image.modifiedAtMs
  output.putString "altText", image.altText
  output.putString "state", $image.state
  output.add '}'

proc putPart(output: var string, part: ContentPart) =
  output.add '{'
  output.putString "kind", $part.kind
  case part.kind
  of contentText, contentVisibleSummary:
    output.putString "text", part.text
  of contentImageReference:
    output.putKey "image"
    output.putImage part.image
  of contentToolCall:
    output.putKey "call"
    output.add '{'
    output.putString "id", $part.toolCall.id
    output.putString "name", part.toolCall.name
    output.putString "argumentsJson", part.toolCall.argumentsJson
    output.add '}'
  of contentToolResult:
    output.putKey "result"
    output.add '{'
    output.putString "callId", $part.toolResult.callId
    output.putString "name", part.toolResult.name
    output.putString "content", part.toolResult.content
    output.putBool "success", part.toolResult.success
    output.putBool "truncated", part.toolResult.truncated
    output.putString "errorCode", part.toolResult.errorCode
    output.add '}'
  output.add '}'

proc putMessage(output: var string, message: Message) =
  output.add '{'
  output.putString "id", $message.id
  output.putString "turnId", $message.turnId
  output.putString "role", $message.role
  output.putKey "parts"
  output.add '['
  for part in message.parts:
    if output[^1] != '[': output.add ','
    output.putPart part
  output.add ']'
  output.putInt "createdAtMs", message.createdAtMs
  output.putInt "finishedAtMs", message.finishedAtMs
  output.putString "status", $message.status
  output.putString "providerId", $message.providerId
  output.putString "modelId", $message.modelId
  output.putString "retryOf", $message.retryOf
  output.putKey "usage"
  output.add '{'
  output.putInt "inputTokens", message.usage.inputTokens
  output.putInt "outputTokens", message.usage.outputTokens
  output.putInt "cachedTokens", message.usage.cachedTokens
  output.putInt "totalTokens", message.usage.totalTokens
  output.add '}'
  output.add '}'

proc encodeSession*(session: Session): string =
  ## Encodes only canonical product state, never credentials or terminal
  ## state. The document is written directly, without a JSON tree.
  result = newStringOfCap(4096)
  result.add '{'
  result.putInt "schemaVersion", currentSessionSchemaVersion
  result.putString "id", $session.id
  result.putString "title", session.title
  result.putString "workspaceRoot", session.workspaceRoot
  result.putInt "createdAtMs", session.createdAtMs
  result.putInt "updatedAtMs", session.updatedAtMs
  result.putString "providerId", $session.providerId
  result.putString "modelId", $session.modelId
  result.putString "reasoningEffort", session.reasoningEffort
  result.putKey "attachments"
  result.add '['
  for attachment in session.stagedAttachments:
    if result[^1] != '[': result.add ','
    result.putImage attachment
  result.add ']'
  result.putKey "messages"
  result.add '['
  for message in session.messages:
    if result[^1] != '[': result.add ','
    result.putMessage message
  result.add ']'
  result.putString "lastTurnState", $session.lastTurnState
  result.putBool "archived", session.archived
  result.add '}'

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
      reasoningEffort: root.boundedString("reasoningEffort", 64).safeId(64),
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
    if result.session.lastTurnState in inFlightStates:
      result.session.lastTurnState = turnInterrupted
      for message in result.session.messages.mitems:
        if message.status == messagePartial:
          message.status = messageInterrupted
  except JsonParsingError as failure:
    result.error = "malformed session JSON: " & failure.msg.safeDisplay(1024)
  except CatchableError as failure:
    result.error = "invalid session: " & failure.msg.safeDisplay(1024)

proc skipValue(parser: var JsonParser, depth: int) =
  if depth > maxNestingDepth:
    raise newException(ValueError, "session nesting is too deep")
  case parser.tok
  of tkCurlyLe:
    discard getTok(parser)
    while parser.tok != tkCurlyRi:
      if parser.tok != tkString:
        raiseParseErr(parser, "string literal as key")
      discard getTok(parser)
      eat(parser, tkColon)
      skipValue(parser, depth + 1)
      if parser.tok != tkComma: break
      discard getTok(parser)
    eat(parser, tkCurlyRi)
  of tkBracketLe:
    discard getTok(parser)
    while parser.tok != tkBracketRi:
      skipValue(parser, depth + 1)
      if parser.tok != tkComma: break
      discard getTok(parser)
    eat(parser, tkBracketRi)
  of tkString, tkInt, tkFloat, tkTrue, tkFalse, tkNull:
    discard getTok(parser)
  else:
    raiseParseErr(parser, "value")

proc takeString(parser: var JsonParser, key: string, maxBytes: int): string =
  if parser.tok != tkString:
    raise newException(ValueError, "field must be a string: " & key)
  if parser.a.len > maxBytes:
    raise newException(ValueError, "field exceeds bound: " & key)
  result = parser.a
  discard getTok(parser)

proc takeInt(parser: var JsonParser, key: string): int64 =
  if parser.tok != tkInt:
    raise newException(ValueError, "field must be an integer: " & key)
  result = parseBiggestInt(parser.a)
  discard getTok(parser)

proc decodeSessionHeader*(source: string,
    limits = phase1Limits()): SessionHeaderResult =
  ## Reads the listing fields of a session document while skipping its
  ## messages, so scanning a large store never materializes transcripts.
  if source.len > limits.maxSessionBytes:
    result.error = "session exceeds the configured size bound"
    return
  var parser: JsonParser
  parser.open(newStringStream(source), "session")
  defer: parser.close()
  try:
    discard getTok(parser)
    if parser.tok != tkCurlyLe:
      raise newException(ValueError, "session root must be an object")
    discard getTok(parser)
    var version = 0'i64
    var sawId, sawTitle, sawWorkspace = false
    var lastTurnState = ""
    while parser.tok != tkCurlyRi:
      if parser.tok != tkString:
        raiseParseErr(parser, "string literal as key")
      let key = parser.a
      discard getTok(parser)
      eat(parser, tkColon)
      case key
      of "schemaVersion":
        version = parser.takeInt(key)
      of "id":
        result.header.id = SessionId(parser.takeString(key, 256).safeId(256))
        sawId = true
      of "title":
        result.header.title = parser.takeString(key, 4096).safeDisplay(4096)
        sawTitle = true
      of "workspaceRoot":
        result.header.workspaceRoot = parser.takeString(key, 32 * 1024)
        sawWorkspace = true
      of "updatedAtMs":
        result.header.updatedAtMs = parser.takeInt(key)
      of "providerId":
        result.header.providerId = ProviderId(
          parser.takeString(key, 256).safeId(256))
      of "modelId":
        result.header.modelId = ModelId(
          parser.takeString(key, 1024).safeDisplay(1024))
      of "lastTurnState":
        lastTurnState = parser.takeString(key, 64)
      of "archived":
        if parser.tok notin {tkTrue, tkFalse}:
          raise newException(ValueError, "field must be a boolean: archived")
        result.header.archived = parser.tok == tkTrue
        discard getTok(parser)
      else:
        skipValue(parser, 1)
      if parser.tok != tkComma: break
      discard getTok(parser)
    eat(parser, tkCurlyRi)
    eat(parser, tkEof)
    if version > currentSessionSchemaVersion:
      result.futureVersion = true
      result.error = "session schema is newer than this Tsuki build"
      return
    if version < 0:
      result.error = "unsupported session schema"
      return
    if not sawId or not sawTitle or not sawWorkspace:
      raise newException(ValueError, "session identity is incomplete")
    if $result.header.id == "" or result.header.workspaceRoot.len == 0:
      raise newException(ValueError, "session identity is incomplete")
    if not isAbsolute(result.header.workspaceRoot):
      raise newException(ValueError, "session workspace must be absolute")
    result.header.workspaceRoot = normalizedPath(result.header.workspaceRoot)
    let state = enumValue(lastTurnState, turnInterrupted)
    result.header.interrupted = state == turnInterrupted or
      state in inFlightStates
  except JsonParsingError as failure:
    result.error = "malformed session JSON: " & failure.msg.safeDisplay(1024)
  except CatchableError as failure:
    result.error = "invalid session: " & failure.msg.safeDisplay(1024)
