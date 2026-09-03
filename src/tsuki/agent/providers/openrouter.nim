## OpenRouter defaults layered over the bounded OpenAI-compatible adapter.

import ../[limits, types]
import openai_compat

const openRouterBaseUrl* = "https://openrouter.ai/api/v1"

proc newOpenRouterProvider*(id: ProviderId, displayName,
    credential: string, models: seq[ModelDescriptor] = @[],
    limits = phase1Limits(), baseUrl = openRouterBaseUrl):
    OpenAICompatProvider =
  ## Creates an OpenRouter adapter with provider-specific discovery metadata.
  result = newOpenAICompatProvider(id, displayName, baseUrl, credential,
    models, limits)
  result.kind = "openrouter"
