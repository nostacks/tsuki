## ChatGPT subscription provider backed by the supported Codex App Server.
## Codex owns OAuth credentials; Tsuki exchanges bounded JSONL over stdio.

import std/[json, locks, monotimes, os, osproc, streams, strutils, times]
import std/typedthreads
import ../[limits, pathpolicy, provider, timedwait, types]

when defined(windows):
  import std/winlean
else:
  import std/posix

const
  maxProtocolLineBytes = 4 * 1024 * 1024
  maxQueuedProtocolBytes = 8 * 1024 * 1024
  loginTimeoutMs = 10 * 60 * 1_000
  readChunkBytes = 64 * 1024
  tooMuchData = "Codex returned too much data. Try a shorter request."

type
  CodexAppServerProvider* = ref object of ProviderAdapter
    executable*: string
    arguments*: seq[string]
    requestTimeoutMs*: int
    idleStreamTimeoutMs*: int
    maxResponseBytes*: int

  LineQueue = ref object
    lock: Lock
    changed: Cond
    lines: seq[string]
    head: int
    queuedBytes: int
    closed: bool
    failure: string

  ReaderArgs = object
    handle: FileHandle
    queue: LineQueue
    discardOutput: bool

  CodexConnection = ref object
    process: Process
    input: Stream
    queue: LineQueue
    reader: Thread[ReaderArgs]
    diagnosticReader: Thread[ReaderArgs]
    consumedBytes: int
    maxResponseBytes: int

func protocolError(message: string,
    kind = providerMalformedResponse): ProviderError =
  ProviderError(kind: kind, message: message.safeDisplay(2048))

proc initLineQueue(): LineQueue =
  new(result)
  initLock(result.lock)
  initCond(result.changed)

proc push(queue: LineQueue, line: sink string) =
  acquire(queue.lock)
  defer: release(queue.lock)
  if queue.closed or queue.failure.len > 0: return
  if line.len > maxProtocolLineBytes or
      line.len > maxQueuedProtocolBytes - min(maxQueuedProtocolBytes,
        queue.queuedBytes):
    queue.failure = tooMuchData
    broadcast(queue.changed)
    return
  queue.queuedBytes += line.len
  queue.lines.add move(line)
  signal(queue.changed)

proc fail(queue: LineQueue, failure: string) =
  acquire(queue.lock)
  if queue.failure.len == 0:
    queue.failure = failure.safeDisplay(1024)
  broadcast(queue.changed)
  release(queue.lock)

proc finish(queue: LineQueue, failure = "") =
  acquire(queue.lock)
  if queue.failure.len == 0 and failure.len > 0:
    queue.failure = failure.safeDisplay(1024)
  queue.closed = true
  broadcast(queue.changed)
  release(queue.lock)

proc readChunk(handle: FileHandle, buffer: var array[readChunkBytes,
    char]): int =
  ## Pipe reads return whatever is available instead of filling the buffer.
  when defined(windows):
    var count: int32 = 0
    if readFile(Handle(handle), addr buffer[0], int32(buffer.len),
        addr count, nil) == 0:
      return -1
    int(count)
  else:
    while true:
      let count = posix.read(cint(handle), addr buffer[0], buffer.len)
      if count < 0 and errno == EINTR: continue
      return int(count)

proc appendBytes(line: var string, buffer: array[readChunkBytes, char],
    start, stop: int) =
  if stop <= start: return
  let offset = line.len
  line.setLen(offset + stop - start)
  copyMem(addr line[offset], unsafeAddr buffer[start], stop - start)

proc readerMain(args: ReaderArgs) {.thread.} =
  var buffer: array[readChunkBytes, char]
  var line = ""
  var discarding = false
  while true:
    let count = readChunk(args.handle, buffer)
    if count <= 0: break
    if args.discardOutput: continue
    var start = 0
    for index in 0 ..< count:
      if buffer[index] != '\n': continue
      if not discarding:
        line.appendBytes(buffer, start, index)
        if line.endsWith("\r"): line.setLen(line.len - 1)
        args.queue.push(move(line))
      line = ""
      discarding = false
      start = index + 1
    if not discarding and start < count:
      if line.len + count - start > maxProtocolLineBytes:
        args.queue.fail(tooMuchData)
        line.setLen 0
        discarding = true
      else:
        line.appendBytes(buffer, start, count)
  if args.discardOutput: return
  if line.len > 0 and not discarding:
    args.queue.push(move(line))
  args.queue.finish()

proc resolvedExecutable(adapter: CodexAppServerProvider): string =
  if adapter.executable.isAbsolute and fileExists(adapter.executable):
    return adapter.executable
  findExe(adapter.executable)

proc startConnection(adapter: CodexAppServerProvider,
    workingDir = ""): tuple[connection: CodexConnection,
    error: ProviderError] =
  let executable = adapter.resolvedExecutable
  if executable.len == 0:
    result.error = ProviderError(kind: providerConfiguration,
      message: "Codex CLI was not found. Install Codex, then use /login.")
    return
  try:
    let process = startProcess(executable, workingDir = workingDir,
      args = adapter.arguments, options = {poUsePath})
    let connection = CodexConnection(process: process,
      input: process.inputStream, queue: initLineQueue(),
      maxResponseBytes: adapter.maxResponseBytes)
    var outputStarted = false
    try:
      createThread(connection.reader, readerMain,
        ReaderArgs(handle: process.outputHandle, queue: connection.queue))
      outputStarted = true
      createThread(connection.diagnosticReader, readerMain,
        ReaderArgs(handle: process.errorHandle, queue: connection.queue,
          discardOutput: true))
    except CatchableError:
      try:
        if process.running:
          process.terminate()
          discard process.waitForExit(1_000)
          if process.running:
            process.kill()
            discard process.waitForExit(1_000)
      except CatchableError:
        discard
      if outputStarted: joinThread(connection.reader)
      try: process.close()
      except CatchableError: discard
      raise
    result.connection = connection
  except CatchableError:
    result.error = ProviderError(kind: providerTransport,
      message: "Unable to start Codex. Run `codex app-server` to check the " &
        "Codex CLI installation.", retryable: true)

proc close(connection: CodexConnection) =
  if connection.isNil: return
  try:
    if connection.process.running:
      connection.process.terminate()
      discard connection.process.waitForExit(1_000)
      if connection.process.running:
        connection.process.kill()
        discard connection.process.waitForExit(1_000)
  except CatchableError:
    discard
  joinThread(connection.reader)
  joinThread(connection.diagnosticReader)
  try: connection.process.close()
  except CatchableError: discard

proc send(connection: CodexConnection, node: JsonNode): ProviderError =
  let line = $node
  if line.len > maxProtocolLineBytes:
    return protocolError("The request is too large for Codex. Shorten the " &
      "prompt or start a new session.",
      providerUnsupportedFeature)
  try:
    connection.input.write(line & "\n")
    connection.input.flush()
  except CatchableError:
    result = ProviderError(kind: providerTransport,
      message: "Could not write to the Codex App Server.", retryable: true)

proc awaitLine(queue: LineQueue, deadline: MonoTime,
    token: CancellationToken, line: var string, closed: var bool,
    failure: var string): bool =
  ## Blocks until a line, closure, failure, cancellation, or the deadline.
  ## The token wakes this wait through the registered waiter.
  let waiter = CancelWaiter(lock: addr queue.lock, cond: addr queue.changed)
  token.addWaiter(waiter)
  defer: token.removeWaiter(waiter)
  acquire(queue.lock)
  defer: release(queue.lock)
  while true:
    if queue.head < queue.lines.len:
      line = move(queue.lines[queue.head])
      queue.queuedBytes -= line.len
      inc queue.head
      if queue.head >= queue.lines.len:
        queue.lines.setLen 0
        queue.head = 0
      return true
    closed = queue.closed
    failure = queue.failure
    if closed or failure.len > 0 or token.isCancelled: return false
    let remaining = (deadline - getMonoTime()).inMilliseconds
    if remaining <= 0: return false
    discard timedWait(queue.changed, queue.lock, int(min(remaining,
      int64(high(int32)))))

proc nextJson(connection: CodexConnection, deadline: MonoTime,
    token: CancellationToken): tuple[node: JsonNode,
    error: ProviderError] =
  while true:
    var line, queueFailure: string
    var closed = false
    if connection.queue.awaitLine(deadline, token, line, closed,
        queueFailure):
      connection.consumedBytes += line.len
      if connection.consumedBytes > connection.maxResponseBytes:
        result.error = protocolError(tooMuchData)
        return
      if line.strip.len == 0: continue
      try:
        let node = parseJson(line)
        if node.kind == JObject:
          result.node = node
          return
      except JsonParsingError:
        discard
      continue
    if token.isCancelled:
      result.error = ProviderError(kind: providerCancelled,
        message: "cancelled")
    elif queueFailure.len > 0:
      result.error = protocolError(queueFailure)
    elif closed:
      result.error = ProviderError(kind: providerTransport,
        message: "Codex closed the connection. Try again.",
        retryable: true)
    else:
      result.error = ProviderError(kind: providerTimeout,
        message: "Codex took too long to respond. Try again.",
        retryable: true)
    return

func rpcFailure(node: JsonNode): ProviderError =
  let error = node{"error"}
  if error.isNil or error.kind != JObject: return
  let message = error{"message"}.getStr(
    "Codex rejected the request.").safeDisplay(2048)
  let lowered = message.toLowerAscii
  let kind = if "login" in lowered or "auth" in lowered or
      "account" in lowered: providerAuthentication
    else: providerTransport
  ProviderError(kind: kind, message: message,
    retryable: kind == providerTransport)

proc response(connection: CodexConnection, id: int, deadline: MonoTime,
    token: CancellationToken): tuple[node: JsonNode,
    error: ProviderError] =
  while true:
    let incoming = connection.nextJson(deadline, token)
    if not incoming.error.ok: return incoming
    if incoming.node.hasKey("id") and incoming.node{"id"}.getInt(-1) == id:
      result.node = incoming.node
      result.error = incoming.node.rpcFailure
      return

proc initialize(connection: CodexConnection, token: CancellationToken,
    timeoutMs: int): ProviderError =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  result = connection.send(%*{"method": "initialize", "id": 1,
    "params": {"clientInfo": {"name": "tsuki", "title": "Tsuki",
      "version": "0.1.0"}}})
  if not result.ok: return
  let initialized = connection.response(1, deadline, token)
  if not initialized.error.ok: return initialized.error
  result = connection.send(%*{"method": "initialized", "params": {}})

func modelDescriptor(adapter: CodexAppServerProvider,
    node: JsonNode): ModelDescriptor =
  let id = node{"id"}.getStr.safeDisplay(1024)
  if id.len == 0: return
  let modalities = node{"inputModalities"}
  var textInput = capabilityUnknown
  var imageInput = capabilityUnknown
  if not modalities.isNil and modalities.kind == JArray:
    textInput = capabilityUnsupported
    imageInput = capabilityUnsupported
    for item in modalities:
      if item.kind != JString: continue
      case item.getStr
      of "text": textInput = capabilitySupported
      of "image": imageInput = capabilitySupported
      else: discard
  result = ModelDescriptor(providerId: adapter.id, id: ModelId(id),
    displayName: node{"displayName"}.getStr(id).safeDisplay(512),
    capabilities: ModelCapabilities(textInput: textInput,
      imageInput: imageInput, streaming: capabilitySupported,
      tools: capabilityUnsupported), available: true,
    provenance: provenanceDiscovered)
  let efforts = node{"supportedReasoningEfforts"}
  if not efforts.isNil and efforts.kind == JArray:
    for option in efforts:
      result.addReasoningEffort(option{"reasoningEffort"}.getStr)
  let defaultEffort = node{"defaultReasoningEffort"}.getStr
  if defaultEffort in result.reasoningEfforts:
    result.defaultReasoningEffort = defaultEffort

proc newCodexAppServerProvider*(id = ProviderId("chatgpt"),
    displayName = "ChatGPT (Codex subscription)", executable = "codex",
    arguments: seq[string] = @["app-server"],
    limits = phase1Limits()): CodexAppServerProvider =
  ## Creates a provider that delegates authentication and model access to Codex.
  new(result)
  result.id = id
  result.kind = "codex_app_server"
  result.displayName = displayName.safeDisplay(256)
  result.executable = executable
  result.arguments = arguments
  result.requestTimeoutMs = limits.requestTimeoutMs
  result.idleStreamTimeoutMs = limits.idleStreamTimeoutMs
  result.maxResponseBytes = limits.maxResponseBytes

method validate*(adapter: CodexAppServerProvider): ProviderError {.gcsafe.} =
  if adapter.resolvedExecutable.len == 0:
    ProviderError(kind: providerConfiguration,
      message: "Codex CLI was not found. Install Codex, then use /login.")
  else:
    ProviderError()

method refreshModels*(adapter: CodexAppServerProvider,
    token: CancellationToken): tuple[models: seq[ModelDescriptor],
    error: ProviderError] {.gcsafe.} =
  result.error = adapter.validate()
  if not result.error.ok: return
  let started = adapter.startConnection()
  if not started.error.ok: return (result.models, started.error)
  let connection = started.connection
  defer: connection.close()
  result.error = connection.initialize(token, adapter.requestTimeoutMs)
  if not result.error.ok: return
  var requestId = 2
  let accountDeadline = getMonoTime() + initDuration(
    milliseconds = adapter.requestTimeoutMs)
  result.error = connection.send(%*{"method": "account/read",
    "id": requestId, "params": {"refreshToken": false}})
  if not result.error.ok: return
  let account = connection.response(requestId, accountDeadline, token)
  if not account.error.ok: return (result.models, account.error)
  let accountNode = account.node{"result"}{"account"}
  if accountNode.isNil or accountNode.kind == JNull:
    result.error = ProviderError(kind: providerAuthentication,
      message: "Sign in with ChatGPT using /login to load Codex models.")
    return
  if accountNode{"type"}.getStr != "chatgpt":
    result.error = ProviderError(kind: providerAuthentication,
      message: "The Codex CLI is not signed in with a ChatGPT subscription. " &
        "Use /login to switch accounts.")
    return
  var cursor = ""
  var pages = 0
  while pages < 100 and result.models.len < 10_000:
    inc pages
    inc requestId
    var params = %*{"limit": 100}
    if cursor.len > 0: params["cursor"] = %cursor
    result.error = connection.send(%*{"method": "model/list",
      "id": requestId, "params": params})
    if not result.error.ok: return
    let listed = connection.response(requestId,
      getMonoTime() + initDuration(milliseconds = adapter.requestTimeoutMs),
      token)
    if not listed.error.ok: return (result.models, listed.error)
    let data = listed.node{"result"}{"data"}
    if data.isNil or data.kind != JArray:
      result.error = protocolError(
        "Codex returned an invalid model list. Update the Codex CLI and try again.")
      return
    for item in data:
      let model = adapter.modelDescriptor(item)
      if $model.id != "": result.models.add model
      if result.models.len >= 10_000: break
    cursor = listed.node{"result"}{"nextCursor"}.getStr
    if cursor.len == 0: break
  if pages >= 100 and cursor.len > 0:
    result.error = protocolError(
      "Codex returned too many model pages. Update the Codex CLI and try again.")

proc startLogin(connection: CodexConnection, loginType: string,
    requestId: int, token: CancellationToken): tuple[node: JsonNode,
    error: ProviderError] =
  result.error = connection.send(%*{"method": "account/login/start",
    "id": requestId, "params": {"type": loginType}})
  if not result.error.ok: return
  connection.response(requestId, getMonoTime() + initDuration(
    milliseconds = 30_000), token)

method loginChatGpt*(adapter: CodexAppServerProvider,
    token: CancellationToken,
    emit: ProviderAuthEventProc): ProviderError {.gcsafe.} =
  result = adapter.validate()
  if not result.ok: return
  if emit.isNil:
    return ProviderError(kind: providerConfiguration,
      message: "Authentication event consumer is missing.")
  let started = adapter.startConnection()
  if not started.error.ok: return started.error
  let connection = started.connection
  defer: connection.close()
  result = connection.initialize(token, adapter.requestTimeoutMs)
  if not result.ok: return
  var login = connection.startLogin("chatgptDeviceCode", 2, token)
  if not login.error.ok and login.error.kind != providerCancelled:
    login = connection.startLogin("chatgpt", 3, token)
  if not login.error.ok: return login.error
  let details = login.node{"result"}
  let loginId = details{"loginId"}.getStr.safeDisplay(512)
  let verificationUrl = details{"verificationUrl"}.getStr(
    details{"authUrl"}.getStr).safeDisplay(4096)
  let userCode = details{"userCode"}.getStr.safeDisplay(256)
  if loginId.len == 0 or verificationUrl.len == 0:
    return protocolError("Codex returned an incomplete sign-in prompt. " &
      "Update the Codex CLI and try again.")
  if not emit(ProviderAuthEvent(kind: providerAuthPrompt,
      verificationUrl: verificationUrl, userCode: userCode,
      message: "Complete ChatGPT sign-in in your browser.")):
    token.cancel()
  let deadline = getMonoTime() + initDuration(milliseconds = loginTimeoutMs)
  while not token.isCancelled:
    let incoming = connection.nextJson(deadline, token)
    if not incoming.error.ok: return incoming.error
    if incoming.node{"method"}.getStr != "account/login/completed": continue
    let params = incoming.node{"params"}
    if params{"loginId"}.getStr != loginId: continue
    if not params{"success"}.getBool(false):
      return ProviderError(kind: providerAuthentication,
        message: params{"error"}.getStr(
          "ChatGPT sign-in did not complete.").safeDisplay(2048))
    discard emit(ProviderAuthEvent(kind: providerAuthComplete,
      message: "Signed in with ChatGPT."))
    return ProviderError()
  discard connection.send(%*{"method": "account/login/cancel", "id": 4,
    "params": {"loginId": loginId}})
  result = ProviderError(kind: providerCancelled, message: "cancelled")

method logout*(adapter: CodexAppServerProvider,
    token: CancellationToken): ProviderError {.gcsafe.} =
  result = adapter.validate()
  if not result.ok: return
  let started = adapter.startConnection()
  if not started.error.ok: return started.error
  let connection = started.connection
  defer: connection.close()
  result = connection.initialize(token, adapter.requestTimeoutMs)
  if not result.ok: return
  result = connection.send(%*{"method": "account/logout", "id": 2})
  if not result.ok: return
  result = connection.response(2, getMonoTime() + initDuration(
    milliseconds = adapter.requestTimeoutMs), token).error

proc requestText(request: ProviderRequest): string =
  for message in request.messages:
    result.add case message.role
      of messageSystem: "SYSTEM\n"
      of messageUser: "USER\n"
      of messageAssistant: "ASSISTANT\n"
      of messageTool: "TOOL RESULT\n"
    for part in message.parts:
      case part.kind
      of contentText, contentVisibleSummary: result.add part.text
      of contentImageReference:
        result.add "[Attached image: " & part.image.displayName & "]"
      of contentToolCall:
        result.add "[Tool call: " & part.toolCall.name & "]"
      of contentToolResult: result.add part.toolResult.content
    result.add "\n\n"
  result = result.safeDisplay(phase1Limits().maxRequestBytes)

proc developerInstructions(request: ProviderRequest): string =
  result = "Tsuki provider policy: inspect only the local workspace. Do not " &
    "modify files, request approval, access the network or browser, or call " &
    "MCP servers, apps, connectors, image generation, computer use, or " &
    "external environments. Read-only local commands are allowed."
  if request.systemInstruction.len > 0:
    result.add "\n\n" & request.systemInstruction
  result = result.safeDisplay(phase1Limits().maxRequestBytes)

proc currentImages(request: ProviderRequest): tuple[items: seq[JsonNode],
    error: ProviderError] =
  if request.messages.len == 0: return
  let message = request.messages[^1]
  if message.role != messageUser: return
  for part in message.parts:
    if part.kind != contentImageReference or
        not part.image.availableForProvider: continue
    let resolved = resolveAttachmentPath(request.workspaceRoot,
      part.image.path)
    if resolved.error.len > 0 or
        part.image.location == attachmentWorkspaceRelative and
          resolved.external:
      result.error = protocolError(
        "An attached image is outside its stored path policy.")
      return
    try:
      let info = getFileInfo(resolved.path, followSymlink = false)
      if info.kind != pcFile or info.isSpecial or info.size <= 0 or
          info.size > phase1Limits().maxImageBytes or
          info.size != part.image.sizeBytes or
          info.lastWriteTime.toUnix * 1_000 != part.image.modifiedAtMs:
        result.error = protocolError(
          "An attached image is missing, changed, or exceeds the limit.")
        return
      result.items.add %*{"type": "localImage", "path": resolved.path}
    except CatchableError:
      result.error = protocolError(
        "An attached image could not be validated.")
      return

method stream*(adapter: CodexAppServerProvider, request: ProviderRequest,
    token: CancellationToken,
    emit: ProviderEventProc): ProviderError {.gcsafe.} =
  result = adapter.validate()
  if not result.ok: return
  if emit.isNil:
    return ProviderError(kind: providerConfiguration,
      message: "Provider event consumer is missing.")
  if request.providerId != adapter.id or request.model.providerId != adapter.id:
    return ProviderError(kind: providerConfiguration,
      message: "Provider request identity does not match the adapter.")
  let text = request.requestText
  if text.len > phase1Limits().maxRequestBytes:
    return ProviderError(kind: providerUnsupportedFeature,
      message: "Provider request exceeded the configured byte limit.")
  let images = request.currentImages
  if not images.error.ok: return images.error
  let started = adapter.startConnection(request.workspaceRoot)
  if not started.error.ok: return started.error
  let connection = started.connection
  defer: connection.close()
  result = connection.initialize(token, adapter.requestTimeoutMs)
  if not result.ok: return
  result = connection.send(%*{"method": "thread/start", "id": 2,
    "params": {"model": $request.model.id, "cwd": request.workspaceRoot,
      "approvalPolicy": "never", "sandbox": "read-only",
      "developerInstructions": request.developerInstructions,
      "config": {"web_search": "disabled",
        "features.plugins": false, "features.apps": false,
        "features.connectors": false, "features.browser_use": false,
        "features.image_generation": false,
        "features.computer_use": false},
      "ephemeral": true}})
  if not result.ok: return
  let thread = connection.response(2, getMonoTime() + initDuration(
    milliseconds = adapter.requestTimeoutMs), token)
  if not thread.error.ok: return thread.error
  let threadId = thread.node{"result"}{"thread"}{"id"}.getStr.safeDisplay(512)
  if threadId.len == 0:
    return protocolError("Codex could not start a session. Update the Codex " &
      "CLI and try again.")
  var input = newJArray()
  input.add %*{"type": "text", "text": text}
  for item in images.items: input.add item
  var turnParams = %*{"threadId": threadId, "input": input,
      "approvalPolicy": "never",
      "sandboxPolicy": {"type": "readOnly", "networkAccess": false},
      "model": $request.model.id}
  if request.reasoningEffort.len > 0:
    turnParams["effort"] = %request.reasoningEffort
  result = connection.send(%*{"method": "turn/start", "id": 3,
    "params": turnParams})
  if not result.ok: return
  let turn = connection.response(3, getMonoTime() + initDuration(
    milliseconds = adapter.requestTimeoutMs), token)
  if not turn.error.ok: return turn.error
  let turnId = turn.node{"result"}{"turn"}{"id"}.getStr.safeDisplay(512)
  if turnId.len == 0:
    return protocolError("Codex could not start the request. Update the Codex " &
      "CLI and try again.")
  if not emit(streamStarted()): token.cancel()
  while not token.isCancelled:
    let incoming = connection.nextJson(getMonoTime() + initDuration(
      milliseconds = adapter.idleStreamTimeoutMs), token)
    if not incoming.error.ok:
      if incoming.error.kind == providerCancelled:
        discard emit(cancelledEvent())
      return incoming.error
    let methodName = incoming.node{"method"}.getStr
    let params = incoming.node{"params"}
    if params{"threadId"}.getStr notin ["", threadId]: continue
    if params{"turnId"}.getStr notin ["", turnId]: continue
    case methodName
    of "item/agentMessage/delta":
      if not emit(textDelta(params{"delta"}.getStr)): token.cancel()
    of "item/reasoning/summaryTextDelta":
      if not emit(visibleSummaryDelta(params{"delta"}.getStr)):
        token.cancel()
    of "thread/tokenUsage/updated":
      let tokenUsage = params{"tokenUsage"}
      let last = tokenUsage{"last"}
      let usage = NormalizedUsage(
        inputTokens: max(0'i64, last{"inputTokens"}.getBiggestInt),
        outputTokens: max(0'i64, last{"outputTokens"}.getBiggestInt),
        cachedTokens: max(0'i64, last{"cachedInputTokens"}.getBiggestInt),
        totalTokens: max(0'i64, last{"totalTokens"}.getBiggestInt))
      if not emit(usageEvent(usage,
          max(0'i64, tokenUsage{"modelContextWindow"}.getBiggestInt))):
        token.cancel()
    of "turn/completed":
      let status = params{"turn"}{"status"}.getStr
      case status
      of "completed":
        discard emit(completedEvent())
        return ProviderError()
      of "interrupted", "cancelled":
        discard emit(cancelledEvent())
        return ProviderError(kind: providerCancelled, message: "cancelled")
      else:
        let message = params{"turn"}{"error"}{"message"}.getStr(
          "Codex turn failed.").safeDisplay(2048)
        return ProviderError(kind: providerTransport, message: message)
    else:
      discard
  discard connection.send(%*{"method": "turn/interrupt", "id": 4,
    "params": {"threadId": threadId, "turnId": turnId}})
  discard emit(cancelledEvent())
  result = ProviderError(kind: providerCancelled, message: "cancelled")

method cancel*(adapter: CodexAppServerProvider,
    token: CancellationToken) =
  discard adapter
  token.cancel()
