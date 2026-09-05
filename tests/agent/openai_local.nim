import std/[asyncdispatch, asynchttpserver, httpcore, json, strutils, unittest]
import tsuki/agent

proc main() =
  let server = newAsyncHttpServer()
  server.listen(Port(0), "127.0.0.1")
  let baseUrl = "http://127.0.0.1:" & $server.getPort.uint16 & "/v1"
  var sawOpenRouterTitle = false
  var wireRequests: seq[JsonNode]

  proc respond(request: Request) {.async, gcsafe.} =
    if request.url.path == "/v1/models":
      if request.headers.getOrDefault("X-OpenRouter-Title") == "Tsuki":
        sawOpenRouterTitle = true
      await request.respond(Http200,
        """{"data":[{"id":"fixture-model","name":"Fixture model",
          "context_length":131072,
          "architecture":{"input_modalities":["text","image"]},
          "supported_parameters":["tools","temperature","reasoning"],
          "reasoning":{"supported_efforts":["high","low"],"default_effort":"low"},
          "top_provider":{"max_completion_tokens":8192}}]}""",
        newHttpHeaders({"Content-Type": "application/json"}))
    elif request.body.contains("\"model\":\"cancel\""):
      await sleepAsync(5_000)
      await request.respond(Http200, "data: [DONE]\n\n",
        newHttpHeaders({"Content-Type": "text/event-stream"}))
    elif request.body.contains("\"model\":\"drop\""):
      await request.respond(Http200,
        "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n",
        newHttpHeaders({"Content-Type": "text/event-stream"}))
    else:
      wireRequests.add parseJson(request.body)
      await request.respond(Http200,
        "data: {\"choices\":[{\"delta\":{\"content\":\"hello \"}}]}\n\n" &
        "data: {\"choices\":[{\"delta\":{\"content\":\"world\"}," &
        "\"finish_reason\":\"stop\"}],\"usage\":{" &
        "\"prompt_tokens\":2,\"completion_tokens\":2," &
        "\"total_tokens\":4}}\n\n" &
        "data: [DONE]\n\n",
        newHttpHeaders({"Content-Type": "text/event-stream",
          "X-RateLimit-Remaining-Requests": "9",
          "X-RateLimit-Limit-Requests": "10"}))

  proc serveRequests() {.async.} =
    for requestIndex in 0 ..< 6:
      discard requestIndex
      await server.acceptRequest(respond)

  asyncCheck serveRequests()
  let configured = ModelDescriptor(providerId: ProviderId("fixture"),
    id: ModelId("fixture-model"), displayName: "Fixture",
    capabilities: supportedCapabilities(image = true, tools = true),
    contextWindow: 16_000, maxOutputTokens: 1_000, available: true,
    provenance: provenanceConfigured)
  let adapter = newOpenAICompatProvider(ProviderId("fixture"), "Fixture",
    baseUrl, "fixture-secret", @[configured])
  let openRouter = newOpenRouterProvider(ProviderId("openrouter"),
    "OpenRouter", "fixture-secret", baseUrl = baseUrl)

  suite "loopback OpenAI-compatible adapter":
    test "discovers and streams normalized terminal state":
      let discovered = adapter.refreshModels(initCancellationToken())
      check discovered.error.ok
      check discovered.models.len == 1
      var text = ""
      var completed = false
      var usage: NormalizedUsage
      var remaining = -1'i64
      let request = ProviderRequest(providerId: adapter.id,
        model: configured, workspaceRoot: ".", reasoningEffort: "high",
        messages: @[Message(role: messageUser,
          parts: @[textPart("hello")], status: messageComplete)])
      let failure = adapter.stream(request, initCancellationToken(),
        proc (event: ProviderEvent): bool {.gcsafe.} =
        case event.kind
        of providerTextDelta: text.add event.text
        of providerUsage: usage = event.usage
        of providerRateLimitUpdate: remaining = event.rateLimitRemaining
        of providerCompleted: completed = true
        else: discard
        true)
      check failure.ok
      check text == "hello world"
      check completed
      check usage.totalTokens == 4
      check remaining == 9
      check wireRequests[^1]{"reasoning_effort"}.getStr == "high"
      check not wireRequests[^1].hasKey("reasoning")

    test "OpenRouter discovery maps provider model metadata":
      let discovered = openRouter.refreshModels(initCancellationToken())
      check discovered.error.ok
      check discovered.models.len == 1
      if discovered.models.len == 1:
        let model = discovered.models[0]
        check model.displayName == "Fixture model"
        check model.contextWindow == 131_072
        check model.maxOutputTokens == 8_192
        check model.capabilities.imageInput == capabilitySupported
        check model.capabilities.tools == capabilitySupported
        check model.reasoningEfforts == @["high", "low"]
        check model.defaultReasoningEffort == "low"
        let request = ProviderRequest(providerId: openRouter.id, model: model,
          workspaceRoot: ".", reasoningEffort: "low",
          messages: @[Message(role: messageUser, parts: @[textPart("reason")])])
        check openRouter.stream(request, initCancellationToken(),
          proc (event: ProviderEvent): bool {.gcsafe.} = true).ok
        check wireRequests[^1]{"reasoning"}{"effort"}.getStr == "low"
        check not wireRequests[^1].hasKey("reasoning_effort")
      check sawOpenRouterTitle

    test "classifies an unexpected EOF as a retryable transport failure":
      var dropping = configured
      dropping.id = ModelId("drop")
      let request = ProviderRequest(providerId: adapter.id, model: dropping,
        workspaceRoot: ".", messages: @[Message(role: messageUser,
        parts: @[textPart("drop")], status: messageComplete)])
      let failure = adapter.stream(request, initCancellationToken(),
        proc (event: ProviderEvent): bool {.gcsafe.} = true)
      check failure.kind == providerTransport
      check failure.retryable

    test "cancels a pending HTTP operation without waiting for its timeout":
      var cancelling = configured
      cancelling.id = ModelId("cancel")
      let token = initCancellationToken()
      proc cancelSoon() {.async.} =
        await sleepAsync(50)
        token.cancel()
      asyncCheck cancelSoon()
      var cancelledEvents = 0
      let request = ProviderRequest(providerId: adapter.id, model: cancelling,
        workspaceRoot: ".", messages: @[Message(role: messageUser,
        parts: @[textPart("cancel")], status: messageComplete)])
      let failure = adapter.stream(request, token,
        proc (event: ProviderEvent): bool {.gcsafe.} =
        if event.kind == providerCancelledEvent: inc cancelledEvents
        true)
      check failure.kind == providerCancelled
      check cancelledEvents == 1

  server.close()

main()
