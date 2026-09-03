## Bounded OpenAI-compatible chat-completions adapter and SSE parser.

import std/[asyncdispatch, asyncstreams, base64, httpclient, json, monotimes,
  net, os, sets, strutils, tables, times, uri]
import ../[boundedio, config, limits, pathpolicy, provider, types]

type
  SseParser* = object
    buffer: string
    dataLines: seq[string]
    eventBytes: int
    maxLineBytes*: int
    maxEventBytes*: int

  OpenAICompatProvider* = ref object of ProviderAdapter
    baseUrl*: string
    credential*: string
    staticModels*: seq[ModelDescriptor]
    requestTimeoutMs*: int
    idleStreamTimeoutMs*: int
    maxResponseBytes*: int

  BoundedBody = object
    data: string
    exceeded: bool

  ProviderCancelledError = object of CatchableError

func endpoint(base, path: string): string
proc errorMessage(node: JsonNode): string {.gcsafe.}

proc addProviderHeaders(headers: HttpHeaders,
    adapter: OpenAICompatProvider) =
  if adapter.kind == "openrouter":
    headers["X-OpenRouter-Title"] = "Tsuki"

func hasString(node: JsonNode, value: string): bool =
  if node.isNil or node.kind != JArray: return false
  for item in node:
    if item.kind == JString and item.getStr == value: return true

func positiveInt64(node: JsonNode, key: string): int64 =
  if not node.isNil and node.kind == JObject and node.hasKey(key) and
      node[key].kind == JInt:
    max(0'i64, node[key].getBiggestInt)
  else:
    0'i64

func discoveredModel(adapter: OpenAICompatProvider,
    node: JsonNode): ModelDescriptor =
  let id = node{"id"}.getStr.safeDisplay(1024)
  if id.len == 0: return
  result = ModelDescriptor(providerId: adapter.id, id: ModelId(id),
    displayName: node{"name"}.getStr(id).safeDisplay(512),
    capabilities: unknownCapabilities(), available: true,
    provenance: provenanceDiscovered)
  if adapter.kind == "openrouter":
    let modalities = node{"architecture"}{"input_modalities"}
    if not modalities.isNil and modalities.kind == JArray:
      result.capabilities.textInput = if modalities.hasString("text"):
        capabilitySupported else: capabilityUnsupported
      result.capabilities.imageInput = if modalities.hasString("image"):
        capabilitySupported else: capabilityUnsupported
    result.capabilities.streaming = capabilitySupported
    let parameters = node{"supported_parameters"}
    if not parameters.isNil and parameters.kind == JArray:
      result.capabilities.tools = if parameters.hasString("tools"):
        capabilitySupported else: capabilityUnsupported
    result.contextWindow = node.positiveInt64("context_length")
    result.maxOutputTokens = node{"top_provider"}.positiveInt64(
      "max_completion_tokens")

proc waitUntil[T](future: Future[T], deadline: MonoTime,
    token: CancellationToken): T =
  while not future.finished:
    if not token.isNil and token.isCancelled:
      raise newException(ProviderCancelledError, "cancelled")
    let remaining = (deadline - getMonoTime()).inMilliseconds
    if remaining <= 0:
      raise newException(TimeoutError, "provider operation timed out")
    poll(min(100, int(remaining)))
  future.read

proc readDeadline(total: MonoTime, idleMs: int): MonoTime =
  let idle = getMonoTime() + initDuration(milliseconds = max(1, idleMs))
  if idle < total: idle else: total

proc readBounded(stream: FutureStream[string], maxBytes: int,
    deadline: MonoTime, idleMs: int,
    token: CancellationToken): BoundedBody =
  while true:
    let (hasData, chunk) = stream.read().waitUntil(
      deadline.readDeadline(idleMs), token)
    if not hasData: break
    if chunk.len > maxBytes - min(maxBytes, result.data.len):
      result.exceeded = true
      return
    result.data.add chunk

func initSseParser*(maxLineBytes = 1024 * 1024,
    maxEventBytes = 2 * 1024 * 1024): SseParser =
  SseParser(maxLineBytes: max(1024, maxLineBytes),
    maxEventBytes: max(1024, maxEventBytes))

proc processLine(parser: var SseParser, line: string,
    events: var seq[string]): string =
  if line.len > parser.maxLineBytes:
    return "provider event line exceeded the configured bound"
  if line.len == 0:
    if parser.dataLines.len > 0:
      let data = parser.dataLines.join("\n")
      if data.len > parser.maxEventBytes:
        return "provider event exceeded the configured bound"
      events.add data
      parser.dataLines.setLen 0
      parser.eventBytes = 0
    return
  if line[0] == ':': return
  let colon = line.find(':')
  let field = if colon < 0: line else: line[0 ..< colon]
  var value = if colon < 0: "" else: line[colon + 1 .. ^1]
  if value.startsWith(" "): value.delete(0 .. 0)
  if field == "data":
    let separator = if parser.dataLines.len > 0: 1 else: 0
    if value.len + separator > parser.maxEventBytes -
        min(parser.maxEventBytes, parser.eventBytes):
      return "provider event exceeded the configured bound"
    parser.dataLines.add value
    parser.eventBytes += value.len + separator

proc feed*(parser: var SseParser, chunk: string,
    events: var seq[string]): string =
  ## Parses arbitrary byte chunks; only complete UTF-8 JSON events escape it.
  parser.buffer.add chunk
  while true:
    let newline = parser.buffer.find('\n')
    if newline < 0: break
    var line = parser.buffer[0 ..< newline]
    parser.buffer.delete(0 .. newline)
    if line.endsWith("\r"): line.setLen(line.len - 1)
    result = parser.processLine(line, events)
    if result.len > 0: return
  if parser.buffer.len > parser.maxLineBytes:
    return "provider event line exceeded the configured bound"

proc finish*(parser: var SseParser, events: var seq[string]): string =
  if parser.buffer.len > 0:
    var line = parser.buffer
    if line.endsWith("\r"): line.setLen(line.len - 1)
    result = parser.processLine(line, events)
    parser.buffer.setLen 0
    if result.len > 0: return
  result = parser.processLine("", events)

func loopbackHost(host: string): bool =
  let value = host.toLowerAscii
  value in ["localhost", "127.0.0.1", "::1", "[::1]"]

proc validateBaseUrl*(value: string): ProviderError =
  try:
    let parsed = parseUri(value)
    if parsed.hostname.len == 0 or parsed.scheme notin ["http", "https"]:
      return ProviderError(kind: providerConfiguration,
        message: "provider base URL must be an absolute HTTP(S) URL")
    if parsed.username.len > 0 or parsed.password.len > 0:
      return ProviderError(kind: providerConfiguration,
        message: "provider base URL must not contain credentials")
    if parsed.query.len > 0 or parsed.anchor.len > 0:
      return ProviderError(kind: providerConfiguration,
        message: "provider base URL must not contain a query or fragment")
    if parsed.scheme == "http" and not parsed.hostname.loopbackHost:
      return ProviderError(kind: providerConfiguration,
        message: "plain HTTP is allowed only for loopback development hosts")
  except ValueError:
    result = ProviderError(kind: providerConfiguration,
      message: "provider base URL is invalid")

proc newOpenAICompatProvider*(id: ProviderId, displayName, baseUrl,
    credential: string, models: seq[ModelDescriptor] = @[],
    limits = phase1Limits()): OpenAICompatProvider =
  new(result)
  result.id = id
  result.kind = "openai_compatible"
  result.displayName = displayName.safeDisplay(256)
  result.baseUrl = baseUrl.strip(chars = {'/'})
  result.credential = credential
  result.staticModels = models
  result.requestTimeoutMs = limits.requestTimeoutMs
  result.idleStreamTimeoutMs = limits.idleStreamTimeoutMs
  result.maxResponseBytes = limits.maxResponseBytes

method validate*(adapter: OpenAICompatProvider): ProviderError {.gcsafe.} =
  result = validateBaseUrl(adapter.baseUrl)
  if result.ok and adapter.credential.len == 0:
    result = ProviderError(kind: providerConfiguration,
      message: "provider credential is missing")

method listModels*(adapter: OpenAICompatProvider): seq[
    ModelDescriptor] {.gcsafe.} =
  adapter.staticModels

method refreshModels*(adapter: OpenAICompatProvider,
    token: CancellationToken): tuple[models: seq[ModelDescriptor],
    error: ProviderError] {.gcsafe.} =
  result.error = adapter.validate()
  if not result.error.ok or token.isCancelled:
    if token.isCancelled:
      result.error = ProviderError(kind: providerCancelled,
        message: "cancelled")
    return
  try:
    var client = newAsyncHttpClient(userAgent = "tsuki/0.1",
      maxRedirects = 0)
    defer: client.close()
    let timeoutMs = min(adapter.requestTimeoutMs, 10_000)
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    let headers = newHttpHeaders({"Authorization":
      "Bearer " & adapter.credential, "Accept": "application/json"})
    headers.addProviderHeaders(adapter)
    let response = client.request(adapter.baseUrl.endpoint("/models"),
      headers = headers)
      .waitUntil(deadline, token)
    let bounded = response.bodyStream.readBounded(4 * 1024 * 1024,
      deadline, timeoutMs, token)
    if bounded.exceeded:
      result.error = ProviderError(kind: providerMalformedResponse,
        message: "model discovery response exceeded the configured bound")
      return
    let body = bounded.data
    if int(response.code) < 200 or int(response.code) >= 300:
      var detail = ""
      try: detail = parseJson(body).errorMessage
      except JsonParsingError: discard
      result.error = classifyHttpError(int(response.code),
        redact(detail, [adapter.credential]))
      return
    let data = parseJson(body){"data"}
    if data.isNil or data.kind != JArray:
      result.error = ProviderError(kind: providerMalformedResponse,
        message: "model discovery data must be an array")
      return
    if data.len > 10_000:
      result.error = ProviderError(kind: providerMalformedResponse,
        message: "model discovery returned too many entries")
      return
    for node in data:
      if token.isCancelled:
        result.error = ProviderError(kind: providerCancelled,
          message: "cancelled")
        return
      let model = adapter.discoveredModel(node)
      if $model.id != "": result.models.add model
    for configured in adapter.staticModels:
      var found = false
      for model in result.models.mitems:
        if model.id == configured.id:
          model = configured
          found = true
          break
      if not found: result.models.add configured
  except JsonParsingError as failure:
    result.error = ProviderError(kind: providerMalformedResponse,
      message: "invalid model discovery JSON: " & failure.msg.safeDisplay())
  except ProviderCancelledError:
    result.error = ProviderError(kind: providerCancelled,
      message: "cancelled")
  except TimeoutError:
    result.error = ProviderError(kind: providerTimeout,
      message: "model discovery timed out", retryable: true)
  except CatchableError as failure:
    result.error = ProviderError(kind: providerTransport,
      message: "model discovery failed: " &
        redact(failure.msg, [adapter.credential]),
      retryable: true)

proc wireContent(part: ContentPart, workspaceRoot: string,
    maxImageBytes: int): JsonNode =
  case part.kind
  of contentText, contentVisibleSummary:
    %*{"type": "text", "text": part.text}
  of contentImageReference:
    if not part.image.availableForProvider: return newJNull()
    if part.image.location == attachmentExternalAbsolute and
        not isAbsolute(part.image.path):
      raise newException(ValueError,
        "external image reference is not absolute")
    let resolved = resolveAttachmentPath(workspaceRoot, part.image.path)
    if resolved.error.len > 0 or
        part.image.location == attachmentWorkspaceRelative and
          resolved.external:
      raise newException(ValueError, "image path is outside its stored policy")
    let path = resolved.path
    let before = getFileInfo(path, followSymlink = false)
    if before.kind != pcFile or before.isSpecial or before.size <= 0 or
        before.size > maxImageBytes or before.size != part.image.sizeBytes or
        before.lastWriteTime.toUnix * 1_000 != part.image.modifiedAtMs:
      raise newException(ValueError,
        "image is missing, changed, or exceeds the limit")
    let source = readBoundedRegularFile(path, maxImageBytes)
    if source.error.len > 0 or source.data.len != int(before.size):
      raise newException(ValueError,
        "image changed while it was being read")
    let data = source.data
    let encoded = base64.encode(data)
    %*{"type": "image_url", "image_url": {"url":
      "data:" & part.image.mediaType & ";base64," & encoded}}
  of contentToolCall, contentToolResult:
    newJNull()

proc requestJson(request: ProviderRequest, maxImageBytes: int): string =
  var messages = newJArray()
  if request.systemInstruction.len > 0:
    messages.add %*{"role": "system", "content": request.systemInstruction}
  for message in request.messages:
    case message.role
    of messageTool:
      for part in message.parts:
        if part.kind == contentToolResult:
          messages.add %*{"role": "tool",
            "tool_call_id": $part.toolResult.callId,
            "content": part.toolResult.content}
    of messageAssistant:
      var text = ""
      var calls = newJArray()
      for part in message.parts:
        case part.kind
        of contentText, contentVisibleSummary: text.add part.text
        of contentToolCall:
          calls.add %*{"id": $part.toolCall.id, "type": "function",
            "function": {"name": part.toolCall.name,
              "arguments": part.toolCall.argumentsJson}}
        else: discard
      var node = %*{"role": "assistant", "content": text}
      if calls.len > 0: node["tool_calls"] = calls
      messages.add node
    of messageSystem, messageUser:
      var content = newJArray()
      for part in message.parts:
        let wire = wireContent(part, request.workspaceRoot, maxImageBytes)
        if wire.kind != JNull: content.add wire
      messages.add %*{"role": if message.role == messageUser: "user"
        else: "system", "content": content}
  var root = %*{"model": $request.model.id, "stream": true,
    "stream_options": {"include_usage": true}, "messages": messages}
  if request.maxOutputTokens > 0:
    root["max_tokens"] = %request.maxOutputTokens
  if request.tools.len > 0:
    var tools = newJArray()
    for tool in request.tools:
      tools.add %*{"type": "function", "function": {
        "name": tool.name, "description": tool.description,
        "parameters": parseJson(tool.parametersJson)}}
    root["tools"] = tools
  $root

proc errorMessage(node: JsonNode): string {.gcsafe.} =
  if not node.isNil and node.kind == JObject and node.hasKey("error"):
    let value = node["error"]
    if value.kind == JObject and value.hasKey("message"):
      return value["message"].getStr.safeDisplay(2048)

proc normalizedUsage(node: JsonNode): NormalizedUsage =
  if node.isNil or node.kind != JObject: return
  result.inputTokens = node{"prompt_tokens"}.getInt(0)
  result.outputTokens = node{"completion_tokens"}.getInt(0)
  result.totalTokens = node{"total_tokens"}.getInt(
    result.inputTokens + result.outputTokens)
  let details = node{"prompt_tokens_details"}
  if not details.isNil and details.kind == JObject:
    result.cachedTokens = details{"cached_tokens"}.getInt(0)

func endpoint(base, path: string): string =
  base.strip(chars = {'/'}) & path

method stream*(adapter: OpenAICompatProvider, request: ProviderRequest,
    token: CancellationToken,
    emit: ProviderEventProc): ProviderError {.gcsafe.} =
  result = adapter.validate()
  if not result.ok: return
  if emit.isNil:
    return ProviderError(kind: providerConfiguration,
      message: "provider event consumer is missing")
  if token.isCancelled:
    discard emit(cancelledEvent())
    return ProviderError(kind: providerCancelled, message: "cancelled")
  if request.providerId != adapter.id or
      request.model.providerId != adapter.id or $request.model.id == "":
    return ProviderError(kind: providerConfiguration,
      message: "provider request identity does not match the adapter")
  if request.model.capabilities.streaming == capabilityUnsupported:
    return ProviderError(kind: providerUnsupportedFeature,
      message: "selected model does not support streaming")
  try:
    let body = requestJson(request, phase1Limits().maxImageBytes)
    if body.len > phase1Limits().maxRequestBytes:
      return ProviderError(kind: providerUnsupportedFeature,
        message: "provider request exceeded the configured byte limit")
    var client = newAsyncHttpClient(userAgent = "tsuki/0.1",
      maxRedirects = 0)
    defer: client.close()
    let deadline = getMonoTime() + initDuration(
      milliseconds = adapter.requestTimeoutMs)
    let headers = newHttpHeaders({
      "Authorization": "Bearer " & adapter.credential,
      "Content-Type": "application/json",
      "Accept": "text/event-stream"})
    headers.addProviderHeaders(adapter)
    let response = client.request(adapter.baseUrl.endpoint(
      "/chat/completions"), httpMethod = HttpPost, body = body,
      headers = headers).waitUntil(deadline, token)
    if int(response.code) < 200 or int(response.code) >= 300:
      let bounded = response.bodyStream.readBounded(64 * 1024, deadline,
        adapter.idleStreamTimeoutMs, token)
      var detail = ""
      if not bounded.exceeded:
        try: detail = parseJson(bounded.data).errorMessage
        except JsonParsingError: discard
      return classifyHttpError(int(response.code),
        redact(detail, [adapter.credential]))
    var remaining = -1'i64
    var requestLimit = -1'i64
    try:
      remaining = parseBiggestInt(response.headers.getOrDefault(
        "x-ratelimit-remaining-requests"))
    except ValueError:
      discard
    try:
      requestLimit = parseBiggestInt(response.headers.getOrDefault(
        "x-ratelimit-limit-requests"))
    except ValueError:
      discard
    if remaining >= 0 or requestLimit >= 0:
      discard emit(rateLimitEvent(max(0'i64, remaining),
        max(0'i64, requestLimit), 0))
    if not emit(streamStarted()):
      token.cancel()
      return ProviderError(kind: providerCancelled, message: "cancelled")
    var parser = initSseParser()
    var total = 0
    var calls = initTable[int, ToolCall]()
    var sawTerminal = false

    proc consume(data: string): ProviderError =
      if data == "[DONE]":
        sawTerminal = true
        return
      let node = parseJson(data)
      if node.isNil or node.kind != JObject:
        return ProviderError(kind: providerMalformedResponse,
          message: "provider event must be a JSON object")
      if node.hasKey("error"):
        return ProviderError(kind: providerMalformedResponse,
          message: node.errorMessage)
      if node.hasKey("usage") and node["usage"].kind == JObject:
        if not emit(usageEvent(node["usage"].normalizedUsage)):
          token.cancel()
      let choices = node{"choices"}
      if choices.isNil or choices.kind != JArray: return
      for choice in choices:
        if choice.isNil or choice.kind != JObject: continue
        if choice.hasKey("finish_reason") and
            choice["finish_reason"].kind != JNull:
          sawTerminal = true
        let delta = choice{"delta"}
        if delta.isNil or delta.kind != JObject: continue
        if delta.hasKey("content") and delta["content"].kind == JString:
          if not emit(textDelta(delta["content"].getStr)):
            token.cancel()
        let toolCalls = delta{"tool_calls"}
        if not toolCalls.isNil and toolCalls.kind == JArray:
          for fragment in toolCalls:
            if fragment.isNil or fragment.kind != JObject: continue
            let index = fragment{"index"}.getInt(0)
            var call = calls.getOrDefault(index)
            if fragment.hasKey("id"):
              call.id = ToolCallId($call.id & fragment["id"].getStr)
            let fn = fragment{"function"}
            if not fn.isNil and fn.kind == JObject:
              if fn.hasKey("name"): call.name.add fn["name"].getStr
              if fn.hasKey("arguments"):
                call.argumentsJson.add fn["arguments"].getStr
            if ($call.id).len > 512 or call.name.len > 256 or
                call.argumentsJson.len > 1024 * 1024:
              return ProviderError(kind: providerMalformedResponse,
                message: "provider tool call exceeded the configured bound")
            calls[index] = call

    while true:
      if token.isCancelled:
        discard emit(cancelledEvent())
        return ProviderError(kind: providerCancelled, message: "cancelled")
      let (hasData, chunk) = response.bodyStream.read().waitUntil(
        deadline.readDeadline(adapter.idleStreamTimeoutMs), token)
      if not hasData: break
      total += chunk.len
      if total > adapter.maxResponseBytes:
        return ProviderError(kind: providerMalformedResponse,
          message: "provider response exceeded the configured bound")
      var events: seq[string]
      let parseError = parser.feed(chunk, events)
      if parseError.len > 0:
        return ProviderError(kind: providerMalformedResponse,
          message: parseError)
      for data in events:
        let eventError = consume(data)
        if not eventError.ok: return eventError
      if sawTerminal: break
    var finalEvents: seq[string]
    let finalError = parser.finish(finalEvents)
    if finalError.len > 0:
      return ProviderError(kind: providerMalformedResponse,
        message: finalError)
    for data in finalEvents:
      let eventError = consume(data)
      if not eventError.ok: return eventError
    if not sawTerminal:
      return ProviderError(kind: providerTransport,
        message: "provider stream ended before a terminal event",
        retryable: true)
    var callIds = initHashSet[string]()
    for index, call in calls.pairs:
      discard index
      if $call.id == "" or call.name.len == 0 or call.argumentsJson.len == 0:
        return ProviderError(kind: providerMalformedResponse,
          message: "provider returned an incomplete tool call")
      if $call.id in callIds:
        return ProviderError(kind: providerMalformedResponse,
          message: "provider returned a duplicate tool call ID")
      callIds.incl $call.id
      try: discard parseJson(call.argumentsJson)
      except JsonParsingError:
        return ProviderError(kind: providerMalformedResponse,
          message: "provider returned malformed tool arguments")
      if not emit(toolCallEvent(call)): token.cancel()
    if token.isCancelled:
      discard emit(cancelledEvent())
      return ProviderError(kind: providerCancelled, message: "cancelled")
    discard emit(completedEvent())
  except JsonParsingError as failure:
    result = ProviderError(kind: providerMalformedResponse,
      message: "provider returned malformed JSON: " & failure.msg.safeDisplay())
  except ValueError as failure:
    result = ProviderError(kind: providerMalformedResponse,
      message: failure.msg.safeDisplay(1024))
  except ProviderCancelledError:
    discard emit(cancelledEvent())
    result = ProviderError(kind: providerCancelled, message: "cancelled")
  except TimeoutError:
    result = ProviderError(kind: providerTimeout,
      message: "provider request timed out", retryable: true)
  except CatchableError as failure:
    result = ProviderError(kind: providerTransport,
      message: "provider transport failed: " &
        redact(failure.msg, [adapter.credential]),
      retryable: true)

method cancel*(adapter: OpenAICompatProvider, token: CancellationToken) =
  discard adapter
  token.cancel()
