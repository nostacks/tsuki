## Agent session/model/context status bar.

import std/[strformat, strutils]
import ../render
import ../widgets/display
import model, theme

type AgentStatus* = object
  model*: string
  mode*: string
  message*: string
  contextUsed*: int64
  contextLimit*: int64

func compactCount(value: int64): string =
  if value >= 1000 and value mod 1000 == 0:
    $(value div 1000) & "k"
  elif value >= 10_000:
    $(value div 1000) & "k"
  else:
    $value

proc statusBar*(frame: Frame, status: AgentStatus, usage = Usage(),
    colors = agentTheme(), rateLimit = RateLimit()) =
  ## Displays configurable status and token/context usage in one safe line.
  var parts: seq[string]
  if status.model.len > 0: parts.add status.model
  if status.mode.len > 0: parts.add status.mode
  if status.message.len > 0: parts.add status.message
  if status.contextLimit > 0:
    parts.add compactCount(status.contextUsed) & "/" &
      compactCount(status.contextLimit)
  elif usage.inputTokens + usage.outputTokens > 0:
    parts.add "tokens " & compactCount(usage.inputTokens + usage.outputTokens)
  if rateLimit.limit > 0:
    parts.add &"requests {rateLimit.remaining}/{rateLimit.limit}"
  frame.write(0, 0, parts.join(" · ").truncateCells(frame.rect.width, true),
    colors.base.muted)
