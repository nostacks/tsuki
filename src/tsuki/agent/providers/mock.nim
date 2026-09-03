## Deterministic provider adapter for tests and offline development.

import ../[provider, types]

type
  MockStepKind* = enum
    mockStart
    mockText
    mockSummary
    mockToolCall
    mockUsage
    mockRateLimit
    mockComplete
    mockFailure

  MockStep* = object
    kind*: MockStepKind
    text*: string
    call*: ToolCall
    usage*: NormalizedUsage
    remaining*: int64
    limit*: int64
    resetAtMs*: int64
    failure*: ProviderError

  MockProvider* = ref object of ProviderAdapter
    models*: seq[ModelDescriptor]
    script*: seq[MockStep]
    scripts*: seq[seq[MockStep]]
    requests*: seq[ProviderRequest]

func mockText*(text: string): MockStep =
  MockStep(kind: mockText, text: text)

func mockSummary*(text: string): MockStep =
  MockStep(kind: mockSummary, text: text)

func mockCall*(id, name, argumentsJson: string): MockStep =
  MockStep(kind: mockToolCall, call: ToolCall(id: ToolCallId(id), name: name,
    argumentsJson: argumentsJson))

func mockDone*(usage = NormalizedUsage()): MockStep =
  if usage.totalTokens > 0 or usage.inputTokens > 0 or
      usage.outputTokens > 0:
    MockStep(kind: mockUsage, usage: usage)
  else:
    MockStep(kind: mockComplete)

func mockRate*(remaining, limit, resetAtMs: int64): MockStep =
  MockStep(kind: mockRateLimit, remaining: remaining, limit: limit,
    resetAtMs: resetAtMs)

func mockFail*(failure: ProviderError): MockStep =
  MockStep(kind: mockFailure, failure: failure)

proc newMockProvider*(script: seq[MockStep] = @[],
    models: seq[ModelDescriptor] = @[],
    scripts: seq[seq[MockStep]] = @[]): MockProvider =
  new(result)
  result.id = ProviderId("mock")
  result.kind = "mock"
  result.displayName = "Mock"
  result.script = script
  result.scripts = scripts
  if models.len > 0:
    result.models = models
  else:
    result.models = @[ModelDescriptor(providerId: result.id,
      id: ModelId("mock-tsuki"), displayName: "mock-tsuki",
      capabilities: supportedCapabilities(image = true, tools = true),
      contextWindow: 16_000, maxOutputTokens: 4_096, available: true,
      provenance: provenanceConfigured)]

method listModels*(adapter: MockProvider): seq[ModelDescriptor] {.gcsafe.} =
  adapter.models

method refreshModels*(adapter: MockProvider,
    token: CancellationToken): tuple[models: seq[ModelDescriptor],
    error: ProviderError] {.gcsafe.} =
  if token.isCancelled:
    result.error = ProviderError(kind: providerCancelled, message: "cancelled")
  else:
    result.models = adapter.models

method stream*(adapter: MockProvider, request: ProviderRequest,
    token: CancellationToken,
    emit: ProviderEventProc): ProviderError {.gcsafe.} =
  if emit.isNil:
    return ProviderError(kind: providerConfiguration,
      message: "provider event consumer is missing")
  if request.providerId != adapter.id or
      request.model.providerId != adapter.id or $request.model.id == "":
    return ProviderError(kind: providerConfiguration,
      message: "provider request identity does not match the adapter")
  let requestIndex = adapter.requests.len
  adapter.requests.add request
  let steps = if requestIndex < adapter.scripts.len:
      adapter.scripts[requestIndex]
    elif adapter.script.len > 0: adapter.script else: @[
    MockStep(kind: mockStart), mockText("Mock response: "),
    mockText(request.messages[^1].messageText), MockStep(kind: mockComplete)]
  var terminal = false
  for step in steps:
    if token.isCancelled:
      discard emit(cancelledEvent())
      return ProviderError(kind: providerCancelled, message: "cancelled")
    var event: ProviderEvent
    case step.kind
    of mockStart: event = streamStarted()
    of mockText: event = textDelta(step.text)
    of mockSummary: event = visibleSummaryDelta(step.text)
    of mockToolCall: event = toolCallEvent(step.call)
    of mockUsage: event = usageEvent(step.usage)
    of mockRateLimit:
      event = rateLimitEvent(step.remaining, step.limit, step.resetAtMs)
    of mockComplete:
      event = completedEvent()
      terminal = true
    of mockFailure:
      event = failedEvent(step.failure)
      discard emit(event)
      return step.failure
    if not emit(event):
      token.cancel()
      return ProviderError(kind: providerCancelled,
        message: "event consumer stopped")
  if not terminal:
    discard emit(completedEvent())

method cancel*(adapter: MockProvider, token: CancellationToken) =
  discard adapter
  token.cancel()
