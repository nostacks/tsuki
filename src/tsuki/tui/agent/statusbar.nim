## Agent session/model/context status bar.

import std/[strformat, strutils]
import ../render
import ../widgets/display
import model, theme

type AgentStatus* = object
  provider*: string
  model*: string
  mode*: string
  message*: string
  contextUsed*: int64
  contextLimit*: int64
  offline*: bool
  saving*: bool

func compactCount(value: int64): string =
  if value >= 1000 and value mod 1000 == 0:
    $(value div 1000) & "k"
  elif value >= 10_000:
    $(value div 1000) & "k"
  else:
    $value

func contextLabel(used, limit: int64, tokens: Usage): string =
  if limit > 0 and used > 0:
    let percent = clamp(used * 100 div limit, 0, 100)
    "ctx " & compactCount(used) & "/" & compactCount(limit) &
      " (" & $percent & "%)"
  elif used > 0:
    "ctx " & compactCount(used) & " tokens"
  elif tokens.inputTokens + tokens.outputTokens > 0:
    "tokens " & compactCount(tokens.inputTokens + tokens.outputTokens)
  else:
    ""

proc statusBar*(frame: Frame, status: AgentStatus, usage = Usage(),
    colors = agentTheme(), rateLimit = RateLimit()) =
  ## Displays configurable status and token/context usage in one safe line.
  var parts: seq[string]
  if status.provider.len > 0: parts.add status.provider
  if status.model.len > 0: parts.add status.model
  if status.mode.len > 0: parts.add status.mode
  if status.message.len > 0: parts.add status.message
  let context = contextLabel(status.contextUsed, status.contextLimit, usage)
  if context.len > 0: parts.add context
  if rateLimit.limit > 0:
    parts.add &"requests {rateLimit.remaining}/{rateLimit.limit}"
  if status.saving: parts.add "saving"
  if status.offline and status.message != "offline": parts.add "offline"
  frame.write(0, 0, parts.join(" · ").truncateCells(frame.rect.width, true),
    colors.base.muted)
