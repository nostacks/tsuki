## Explicit, bounded OSC 52 clipboard requests.

import std/base64
import ../[terminal, text]

type ClipboardRequest* = object
  accepted*: bool
  bytes*: string
  error*: string

proc encodeClipboardWrite*(value: string, capabilities: TerminalCapabilities,
    explicitlyAllowed = false, maxBytes = 100_000): ClipboardRequest =
  ## Returns an OSC 52 request only after an explicit application opt-in.
  if not explicitlyAllowed:
    result.error = "clipboard write requires explicit application approval"
    return
  if not capabilities.clipboard:
    result.error = "terminal clipboard protocol is unavailable"
    return
  let safe = sanitizeText(value, plainTextPolicy(maxBytes = maxBytes))
  if safe.len > maxBytes:
    result.error = "clipboard payload exceeds configured limit"
    return
  result.accepted = true
  result.bytes = "\e]52;c;" & encode(safe) & "\a"

