## Foundational display widgets and grapheme-aware text utilities.

import std/strutils
import ../[geometry, graphemes, render, style, text, theme]
import border

type TextAlign* = enum
  textStart
  textCenter
  textEnd

func cellWidth*(value: string): int =
  ## Measures a safe UTF-8 string in terminal cells.
  for cluster in value.graphemes:
    result += cluster.clusterWidth

func truncateCells*(value: string, width: int,
    ellipsis = true): string =
  ## Clips at grapheme boundaries. A single U+2026 advertises hidden content.
  if width <= 0:
    return ""
  if value.cellWidth <= width:
    return value
  let reserve = if ellipsis: 1 else: 0
  var used = 0
  for cluster in value.graphemes:
    let clusterWidth = cluster.clusterWidth
    if used + clusterWidth > width - reserve:
      break
    result.add cluster
    inc used, clusterWidth
  if ellipsis:
    result.add "…"

func alignedX(width, contentWidth: int, align: TextAlign): int =
  case align
  of textStart: 0
  of textCenter: max(0, (width - contentWidth) div 2)
  of textEnd: max(0, width - contentWidth)

proc text*(frame: Frame, value: string, style = styleDefault(),
    align = textStart, ellipsis = false) =
  ## Renders one grapheme-safe line with optional alignment and ellipsis.
  let shown = value.truncateCells(frame.rect.width, ellipsis)
  frame.write(alignedX(frame.rect.width, shown.cellWidth, align), 0,
    shown, style)

proc richText*(frame: Frame, value: Text, scroll = 0,
    wrap = true, align = textStart) =
  ## Renders styled spans with explicit lines and grapheme-aware wrapping.
  ## The full `Text` remains application-owned, so truncated content can be
  ## exposed by a scroll/expanded view.
  if frame.rect.isEmpty:
    return
  type StyledCluster = tuple[value: string, style: Style]
  var rows: seq[seq[StyledCluster]]
  for line in value.lines:
    var row: seq[StyledCluster]
    var used = 0
    for span in line.spans:
      for cluster in span.text.graphemes:
        let width = cluster.clusterWidth
        if wrap and used > 0 and used + width > frame.rect.width:
          rows.add move(row)
          row = @[]
          used = 0
        if width <= frame.rect.width:
          row.add (cluster, span.style)
          inc used, width
    rows.add move(row)
  let first = clamp(max(0, scroll), 0, rows.len)
  let last = min(rows.len, first + frame.rect.height)
  for rowIndex in first ..< last:
    var rowWidth = 0
    for cluster in rows[rowIndex]:
      inc rowWidth, cluster.value.clusterWidth
    var x = alignedX(frame.rect.width, rowWidth, align)
    for cluster in rows[rowIndex]:
      frame.write(x, rowIndex - first, cluster.value, cluster.style)
      inc x, cluster.value.clusterWidth

proc `block`*(frame: Frame, title = "", style = styleDefault(),
    rounded = false): Frame =
  ## Draws a structural border and returns its clipped one-cell inset.
  frame.border(style, title, rounded)
  frame.sub(rect(1, 1, max(0, frame.rect.width - 2),
    max(0, frame.rect.height - 2)), frame.style)

proc rule*(frame: Frame, label = "", style = styleDefault()) =
  ## Draws a horizontal rule; spacing should remain the primary group cue.
  if frame.rect.width <= 0:
    return
  let shown = label.truncateCells(max(0, frame.rect.width - 4), true)
  var output = repeat("─", frame.rect.width)
  if shown.len > 0:
    output = "─ " & shown & " "
    let used = output.cellWidth
    if used < frame.rect.width:
      output.add repeat("─", frame.rect.width - used)
  frame.write(0, 0, output, style)

proc help*(frame: Frame, bindings: openArray[(string, string)],
    colors = darkTheme()) =
  ## Renders shortcut/name pairs with restrained semantic emphasis.
  var x = 0
  for index, binding in bindings:
    if index > 0:
      frame.write(x, 0, " · ", colors.muted)
      inc x, 3
    let key = binding[0].truncateCells(max(0, frame.rect.width - x), true)
    frame.write(x, 0, key, colors.accent)
    inc x, key.cellWidth
    if x < frame.rect.width:
      frame.write(x, 0, " " & binding[1], colors.muted)
      inc x, 1 + binding[1].cellWidth
    if x >= frame.rect.width:
      break

proc spacer*(frame: Frame) =
  ## Explicitly occupies layout space without drawing.
  discard
