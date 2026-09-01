## Explicit, capability-gated OSC 8 hyperlink encoding.

import ../[terminal, text]

type HyperlinkEncoding* = object
  supported*: bool
  bytes*: string
  fallback*: string

proc encodeHyperlink*(link: Hyperlink, label: string,
    capabilities: TerminalCapabilities): HyperlinkEncoding =
  ## Encodes OSC 8 only for a validated URI and advertised capability.
  ## The label is always sanitized; unsupported terminals receive plain text.
  result.fallback = sanitizeText(label)
  if not capabilities.hyperlinks or not link.uri.safeUri:
    return
  let id = sanitizeText(link.id,
    TextPolicy(kind: tpkReplacement, maxBytes: 128,
      maxCodepoints: 128, allowNewlines: false, allowTabs: false))
  result.supported = true
  result.bytes = "\e]8;id=" & id & ";" & link.uri & "\e\\" &
    result.fallback & "\e]8;;\e\\"

