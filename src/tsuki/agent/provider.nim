## Provider adapter contract, normalized stream events, and registry.

import std/[algorithm, locks, monotimes, tables, times]
import timedwait, types

type
  ProviderErrorKind* = enum
    providerConfiguration
    providerAuthentication
    providerPermission
    providerRateLimit
    providerTimeout
    providerTransport
    providerMalformedResponse
    providerUnsupportedFeature
    providerCancelled

  ProviderError* = object
    kind*: ProviderErrorKind
    message*: string
    retryable*: bool
    retryAfterMs*: int64
    httpStatus*: int

  ProviderEventKind* = enum
    providerStreamStarted
    providerTextDelta
    providerVisibleSummaryDelta
    providerToolCall
    providerUsage
    providerRateLimitUpdate
    providerCompleted
    providerCancelledEvent
    providerFailed

  ProviderEvent* = object
    kind*: ProviderEventKind
    text*: string
    toolCall*: ToolCall
    usage*: NormalizedUsage
    contextLimit*: int64
    rateLimitRemaining*: int64
    rateLimitLimit*: int64
    rateLimitResetAtMs*: int64
    error*: ProviderError

  ProviderToolDefinition* = object
    name*: string
    description*: string
    parametersJson*: string

  ProviderRequest* = object
    sessionId*: SessionId
    turnId*: TurnId
    providerId*: ProviderId
    model*: ModelDescriptor
    workspaceRoot*: string
    reasoningEffort*: string
    systemInstruction*: string
    messages*: seq[Message]
    tools*: seq[ProviderToolDefinition]
    maxOutputTokens*: int

  CancelWaiter* = object
    ## A lock/condition pair another queue blocks on; cancel wakes it.
    lock*: ptr Lock
    cond*: ptr Cond

  CancellationToken* = ref object
    lock: Lock
    changed: Cond
    stopped: bool
    waiters: seq[CancelWaiter]

  ProviderEventProc* = proc (event: ProviderEvent): bool {.closure, gcsafe.}

  ProviderAuthEventKind* = enum
    providerAuthPrompt
    providerAuthComplete

  ProviderAuthEvent* = object
    kind*: ProviderAuthEventKind
    verificationUrl*: string
    userCode*: string
    message*: string

  ProviderAuthEventProc* = proc (event: ProviderAuthEvent): bool {.
    closure, gcsafe.}

  ProviderAdapter* = ref object of RootObj
    id*: ProviderId
    kind*: string
    displayName*: string

  ProviderRegistry* = object
    adapters: Table[string, ProviderAdapter]

proc cancel*(token: CancellationToken) {.gcsafe.}
proc isCancelled*(token: CancellationToken): bool {.gcsafe.}

method validate*(adapter: ProviderAdapter): ProviderError {.base, gcsafe.} =
  if adapter.isNil:
    ProviderError(kind: providerConfiguration,
      message: "provider adapter is nil")
  else:
    ProviderError()

method listModels*(adapter: ProviderAdapter): seq[ModelDescriptor] {.base,
    gcsafe.} =
  discard adapter

method refreshModels*(adapter: ProviderAdapter,
    token: CancellationToken): tuple[models: seq[ModelDescriptor],
    error: ProviderError] {.base, gcsafe.} =
  if token.isCancelled:
    result.error = ProviderError(kind: providerCancelled, message: "cancelled")
  else:
    result.models = adapter.listModels()

method stream*(adapter: ProviderAdapter, request: ProviderRequest,
    token: CancellationToken,
    emit: ProviderEventProc): ProviderError {.base, gcsafe.} =
  discard adapter
  discard request
  discard token
  discard emit.isNil
  ProviderError(kind: providerUnsupportedFeature,
    message: "provider does not implement streaming")

method cancel*(adapter: ProviderAdapter, token: CancellationToken) {.base.} =
  discard adapter
  token.cancel()

method loginChatGpt*(adapter: ProviderAdapter, token: CancellationToken,
    emit: ProviderAuthEventProc): ProviderError {.base, gcsafe.} =
  discard adapter
  discard token
  discard emit.isNil
  ProviderError(kind: providerUnsupportedFeature,
    message: "This provider does not support ChatGPT sign-in.")

method logout*(adapter: ProviderAdapter,
    token: CancellationToken): ProviderError {.base, gcsafe.} =
  discard adapter
  discard token
  ProviderError(kind: providerUnsupportedFeature,
    message: "This provider does not support sign-out.")

proc initCancellationToken*(): CancellationToken =
  new(result)
  initLock(result.lock)
  initCond(result.changed)

proc cancel*(token: CancellationToken) {.gcsafe.} =
  ## Waiters are signalled after the token lock is released, so a waiter may
  ## hold its own lock while checking `isCancelled` without deadlocking.
  if token.isNil: return
  acquire(token.lock)
  token.stopped = true
  let waiters = token.waiters
  broadcast(token.changed)
  release(token.lock)
  for waiter in waiters:
    acquire(waiter.lock[])
    broadcast(waiter.cond[])
    release(waiter.lock[])

proc isCancelled*(token: CancellationToken): bool {.gcsafe.} =
  if token.isNil: return false
  acquire(token.lock)
  result = token.stopped
  release(token.lock)

proc waitCancel*(token: CancellationToken, timeoutMs: int): bool {.gcsafe.} =
  ## Blocks up to `timeoutMs` and returns true once the token is cancelled.
  if token.isNil: return false
  let deadline = getMonoTime() + initDuration(milliseconds = max(0, timeoutMs))
  acquire(token.lock)
  while not token.stopped:
    let remaining = (deadline - getMonoTime()).inMilliseconds
    if remaining <= 0: break
    discard timedWait(token.changed, token.lock, int(remaining))
  result = token.stopped
  release(token.lock)

proc addWaiter*(token: CancellationToken, waiter: CancelWaiter) {.gcsafe.} =
  ## Registers a queue to wake on cancel. The caller must remove the waiter
  ## before the lock and condition it points to are destroyed.
  if token.isNil or waiter.lock.isNil or waiter.cond.isNil: return
  acquire(token.lock)
  token.waiters.add waiter
  release(token.lock)

proc removeWaiter*(token: CancellationToken, waiter: CancelWaiter) {.gcsafe.} =
  if token.isNil: return
  acquire(token.lock)
  for index in countdown(token.waiters.len - 1, 0):
    if token.waiters[index].lock == waiter.lock and
        token.waiters[index].cond == waiter.cond:
      token.waiters.delete(index)
  release(token.lock)

func ok*(failure: ProviderError): bool =
  failure.message.len == 0

func streamStarted*(): ProviderEvent =
  ProviderEvent(kind: providerStreamStarted)

func textDelta*(text: string): ProviderEvent =
  ProviderEvent(kind: providerTextDelta, text: text)

func visibleSummaryDelta*(text: string): ProviderEvent =
  ProviderEvent(kind: providerVisibleSummaryDelta, text: text)

func toolCallEvent*(call: ToolCall): ProviderEvent =
  ProviderEvent(kind: providerToolCall, toolCall: call)

func usageEvent*(usage: NormalizedUsage, contextLimit = 0'i64): ProviderEvent =
  ProviderEvent(kind: providerUsage, usage: usage, contextLimit: contextLimit)

func rateLimitEvent*(remaining, limit, resetAtMs: int64): ProviderEvent =
  ProviderEvent(kind: providerRateLimitUpdate,
    rateLimitRemaining: remaining, rateLimitLimit: limit,
    rateLimitResetAtMs: resetAtMs)

func completedEvent*(): ProviderEvent =
  ProviderEvent(kind: providerCompleted)

func cancelledEvent*(): ProviderEvent =
  ProviderEvent(kind: providerCancelledEvent)

func failedEvent*(failure: ProviderError): ProviderEvent =
  ProviderEvent(kind: providerFailed, error: failure)

proc initProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(adapters: initTable[string, ProviderAdapter]())

proc register*(registry: var ProviderRegistry,
    adapter: ProviderAdapter): ProviderError =
  ## Registers one stable provider identity without replacing an existing one.
  if adapter.isNil or $adapter.id == "":
    return ProviderError(kind: providerConfiguration,
      message: "provider ID must not be empty")
  if adapter.kind.len == 0:
    return ProviderError(kind: providerConfiguration,
      message: "provider kind must not be empty")
  let key = $adapter.id
  if registry.adapters.hasKey(key):
    return ProviderError(kind: providerConfiguration,
      message: "duplicate provider ID: " & key.safeDisplay())
  registry.adapters[key] = adapter

proc find*(registry: ProviderRegistry, id: ProviderId): ProviderAdapter =
  registry.adapters.getOrDefault($id)

proc providers*(registry: ProviderRegistry): seq[ProviderAdapter] =
  for adapter in registry.adapters.values:
    result.add adapter
  result.sort(proc (left, right: ProviderAdapter): int =
    cmp($left.id, $right.id))

func classifyHttpError*(status: int, message = "",
    retryAfterMs = 0'i64): ProviderError =
  ## Maps HTTP outcomes without retaining response headers or credentials.
  let safe = message.safeDisplay(2048)
  result = case status
  of 400:
    ProviderError(kind: providerMalformedResponse,
      message: if safe.len > 0: safe else: "provider rejected the request",
      httpStatus: status)
  of 401:
    ProviderError(kind: providerAuthentication,
      message: "provider authentication failed", httpStatus: status)
  of 403:
    ProviderError(kind: providerPermission,
      message: "provider permission denied", httpStatus: status)
  of 404:
    ProviderError(kind: providerConfiguration,
      message: "provider endpoint or model was not found", httpStatus: status)
  of 408:
    ProviderError(kind: providerTimeout, message: "provider timed out",
      retryable: true, httpStatus: status)
  of 409, 425, 500..599:
    ProviderError(kind: providerTransport,
      message: if safe.len > 0: safe else: "temporary provider failure",
      retryable: true, httpStatus: status)
  of 429:
    ProviderError(kind: providerRateLimit,
      message: "provider rate limit reached", retryable: true,
      httpStatus: status)
  else:
    ProviderError(kind: providerTransport,
      message: if safe.len > 0: safe else: "provider HTTP error " & $status,
      retryable: status >= 500, httpStatus: status)
  if result.retryable and retryAfterMs > 0:
    result.retryAfterMs = retryAfterMs
