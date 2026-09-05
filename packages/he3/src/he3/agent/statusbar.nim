## Agent session/model/context status bar.

import std/strutils
import ../[graphemes, render, style, text]
import ../widgets/display
import model, theme

type AgentStatus* = object
  provider*: string
  model*: string
  mode*: string
  message*: string
  directory*: string
  reasoningEffort*: string
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

func contextStyle(colors: AgentTheme, fraction: float): Style =
  # Interpolate the existing capacity colors through amber in sRGB. Keep
  # attribute-led themes intact when RGB colors are unavailable.
  let start = if fraction < 0.5: colors.base.success else: colors.base.warning
  let finish = if fraction < 0.5: colors.base.warning else: colors.base.error
  let blend = clamp(if fraction < 0.5: fraction * 2 else: fraction * 2 - 1,
    0.0, 1.0)
  if start.fg.kind != ckRgb or finish.fg.kind != ckRgb:
    return if blend < 0.5: start else: finish
  let a = start.fg.rgb
  let b = finish.fg.rgb
  var channels: array[3, range[0..255]]
  for index in 0 .. 2:
    channels[index] = range[0..255](int(float(a[index]) * (1 - blend) +
      float(b[index]) * blend))
  colors.base.text.withFg(rgb(channels[0], channels[1], channels[2]))

func cleanLabel(value: string): string =
  sanitizeText(value).replace('\n', ' ').replace('\t', ' ')

func directoryName(value: string): string =
  let clean = cleanLabel(value)
  let trimmed = clean.strip(chars = {'/', '\\'}, leading = false)
  if trimmed.len == 0: return clean
  let separator = max(trimmed.rfind('/'), trimmed.rfind('\\'))
  trimmed[separator + 1 .. ^1]

proc directoryLabel(value: string, width: int): string =
  if width <= 0: return ""
  let clean = directoryName(value)
  if clean.cellWidth <= width: return clean
  var clusters: seq[string]
  for cluster in clean.graphemes: clusters.add cluster
  var used = 1
  var first = clusters.len
  while first > 0 and used + clusters[first - 1].cellWidth <= width:
    dec first
    used += clusters[first].cellWidth
  "…" & clusters[first ..< clusters.len].join("")

proc statusBar*(frame: Frame, status: AgentStatus, usage = Usage(),
    colors = agentTheme(), rateLimit = RateLimit()) =
  ## Reserves the right edge for context capacity; text and a position marker
  ## keep the meter readable without color. Directory text is host-supplied.
  let width = frame.rect.width
  if width <= 0 or frame.rect.height <= 0: return
  let known = status.contextLimit > 0
  let used = max(0'i64, status.contextUsed)
  let fraction = if known:
      clamp(used.float / status.contextLimit.float, 0.0, 1.0) else: 0.0
  let percent = ($(int(fraction * 100)) & "%").align(4)
  var suffix = if known: percent else: "ctx ?"
  if not known and used > 0: suffix = "ctx " & compactCount(used) & " / ?"
  elif not known and usage.inputTokens > 0:
    suffix = "tokens " & compactCount(usage.inputTokens)
  let meterWidth = if not known or width < 32: 0
    elif width < 64: 4 else: 8
  let detail = if known and width >= 100:
      "ctx " & compactCount(used) & "/" & compactCount(status.contextLimit) & " "
    elif known and width >= 24: "ctx " else: ""
  suffix = suffix.truncateCells(width, true)
  let rightWidth = detail.cellWidth + meterWidth +
    (if meterWidth > 0: 1 else: 0) + suffix.cellWidth
  let rightX = max(0, width - rightWidth)
  let leftWidth = max(0, rightX - 2)
  let effort = cleanLabel(if status.reasoningEffort.len > 0:
    status.reasoningEffort else: "default")
  let reasoning = if status.model.len > 0 or status.reasoningEffort.len > 0:
      "✦ " & effort else: ""
  var notice = ""
  var noticeStyle = colors.base.muted
  if status.offline or status.message == "offline":
    notice = "! offline"
    noticeStyle = colors.base.error
  elif status.message == "save failed":
    notice = "! save failed"
    noticeStyle = colors.base.error
  elif status.saving:
    notice = "↻ saving"
  elif rateLimit.limit > 0 and rateLimit.remaining <= 0:
    notice = "! rate limit"
    noticeStyle = colors.base.warning
  elif status.message.len > 0 and status.message notin ["ready", "idle",
      "saved", "streaming", "streaming · context estimate", "signed in"]:
    notice = cleanLabel(status.message)
  elif status.mode.len > 0 and status.mode != "agent":
    notice = cleanLabel(status.mode)
  # Keep the selected effort and exceptional state visible before budgeting
  # identity text. Ordinary provider/mode/ready labels repeat known state.
  let noticeWidth = min(notice.cellWidth, leftWidth)
  let noticeSpace = noticeWidth + (if noticeWidth > 0: 2 else: 0)
  let reasoningWidth = min(reasoning.cellWidth, max(0, leftWidth - noticeSpace))
  let reasoningSpace = reasoningWidth + (if reasoningWidth > 0: 2 else: 0)
  let identityWidth = max(0, leftWidth - reasoningSpace - noticeSpace)
  var xLeft = 0
  proc part(label: string, style: Style, budget: int) =
    if label.len == 0 or budget <= 0: return
    let clipped = label.truncateCells(budget, true)
    if xLeft > 0:
      xLeft += 2
    frame.write(xLeft, 0, clipped, style)
    xLeft += clipped.cellWidth
  if status.directory.len > 0:
    let budget = if status.model.len > 0: identityWidth div 2
      else: identityWidth
    if budget >= 3:
      part("⌂ " & directoryLabel(status.directory, budget - 2),
        colors.base.muted, budget)
  if status.model.len > 0:
    let budget = identityWidth - xLeft - (if xLeft > 0: 2 else: 0)
    if budget >= 3:
      part("◇ " & cleanLabel(status.model), colors.base.text.bold, budget)
  part(reasoning, colors.base.accent, reasoningWidth)
  part(notice, noticeStyle, noticeWidth)
  frame.write(rightX, 0, detail, colors.base.muted)
  var x = rightX + detail.cellWidth
  if meterWidth > 0:
    let marker = int(fraction * float(meterWidth - 1))
    for index in 0 ..< meterWidth:
      let glyph = if index == marker: "●" elif index <
          marker: "━" else: "─"
      let style = if index <= marker:
          colors.contextStyle(float(index) / float(meterWidth - 1))
        else: colors.base.muted.dimmed
      frame.write(x + index, 0, glyph, style)
    x += meterWidth + 1
  frame.write(x, 0, suffix,
    if known: colors.contextStyle(fraction) else: colors.base.muted)
