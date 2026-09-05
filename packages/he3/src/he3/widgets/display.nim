## Foundational display widgets and grapheme-aware text utilities.

import std/strutils
import ../[geometry, graphemes, render, style, text, theme]
import border

type TextAlign* = enum
  textStart
  textCenter
  textEnd

type CellFit = object
  ## The longest prefix of a text that fits a cell budget.
  stop: int
  width: int
  truncated: bool

func cellWidth*(value: openArray[char]): int =
  ## Measures safe UTF-8 text in terminal cells without allocating.
  textWidth(value)

func fitCells(value: openArray[char], width: int, ellipsis: bool): CellFit =
  ## Finds the prefix of `value` that fits `width` cells. When the text does
  ## not fit and `ellipsis` is set, one cell is reserved for the marker and
  ## `width` includes it.
  if width <= 0:
    return CellFit(truncated: value.len > 0)
  let reserve = if ellipsis: 1 else: 0
  var used = 0
  var keep = -1
  var keepWidth = 0
  for span in value.graphemeSpans:
    let clusterWidth = clusterWidth(value.toOpenArray(span.a, span.b))
    if keep < 0 and used + clusterWidth > width - reserve:
      keep = span.a
      keepWidth = used
    if used + clusterWidth > width:
      return CellFit(stop: keep, width: keepWidth + reserve, truncated: true)
    inc used, clusterWidth
  CellFit(stop: value.len, width: used)

func truncateCells*(value: string, width: int,
    ellipsis = true): string =
  ## Clips at grapheme boundaries. A single U+2026 advertises hidden content.
  if width <= 0:
    return ""
  let fit = fitCells(value, width, ellipsis)
  if not fit.truncated:
    return value
  result = value[0 ..< fit.stop]
  if ellipsis:
    result.add "…"

proc writePrefix(frame: Frame, x, y: int, value: openArray[char],
    fit: CellFit, style: Style, ellipsis: bool) =
  if fit.stop > 0:
    frame.write(x, y, value.toOpenArray(0, fit.stop - 1), style)
  if fit.truncated and ellipsis and fit.width > 0:
    frame.write(x + fit.width - 1, y, "…", style)

proc writeFit*(frame: Frame, x, y: int, value: openArray[char], width: int,
    style: Style, ellipsis = true): int =
  ## Writes the prefix of `value` that fits `width` cells, clipping at
  ## grapheme boundaries with an optional ellipsis, and returns the cells
  ## used. Nothing is copied.
  if width <= 0:
    return 0
  let fit = fitCells(value, width, ellipsis)
  frame.writePrefix(x, y, value, fit, style, ellipsis)
  fit.width

func alignedX(width, contentWidth: int, align: TextAlign): int =
  case align
  of textStart: 0
  of textCenter: max(0, (width - contentWidth) div 2)
  of textEnd: max(0, width - contentWidth)

proc text*(frame: Frame, value: string, style = styleDefault(),
    align = textStart, ellipsis = false) =
  ## Renders one grapheme-safe line with optional alignment and ellipsis.
  if frame.rect.width <= 0:
    return
  let fit = fitCells(value, frame.rect.width, ellipsis)
  frame.writePrefix(alignedX(frame.rect.width, fit.width, align), 0, value,
    fit, style, ellipsis)

proc richText*(frame: Frame, value: Text, scroll = 0,
    wrap = true, align = textStart) =
  ## Renders styled spans with explicit lines and grapheme-aware wrapping.
  ## The full `Text` remains application-owned, so truncated content can be
  ## exposed by a scroll/expanded view. Only visible rows are written and
  ## no text is copied.
  if frame.rect.isEmpty:
    return
  type Piece = tuple[line, span, a, b, x, w: int]
  let first = max(0, scroll)
  let last = first + frame.rect.height
  var row: seq[Piece]
  var rowIndex = 0
  var used = 0
  template flushRow() =
    if rowIndex >= first and rowIndex < last:
      let offset = alignedX(frame.rect.width, used, align)
      for piece in row:
        let span = value.lines[piece.line].spans[piece.span]
        frame.write(offset + piece.x, rowIndex - first,
          span.text.toOpenArray(piece.a, piece.b), span.style)
        if span.hyperlink.uri.len > 0:
          frame.linkCells(offset + piece.x, rowIndex - first, piece.w,
            frame.link(span.hyperlink.uri))
    row.setLen 0
    inc rowIndex
    used = 0
  for lineIndex, line in value.lines:
    if rowIndex >= last:
      return
    for spanIndex, span in line.spans:
      for cluster in span.text.graphemeSpans:
        let width = clusterWidth(span.text.toOpenArray(cluster.a, cluster.b))
        if wrap and used > 0 and used + width > frame.rect.width:
          flushRow()
        if width <= 0 or width > frame.rect.width:
          continue
        if row.len > 0 and row[^1].line == lineIndex and
            row[^1].span == spanIndex and row[^1].b + 1 == cluster.a:
          row[^1].b = cluster.b
          row[^1].w += width
        else:
          row.add (lineIndex, spanIndex, cluster.a, cluster.b, used, width)
        inc used, width
    flushRow()

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
