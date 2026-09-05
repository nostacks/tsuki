## Terminal-style cell selection over the rendered frame.

import std/strutils
import ../[buffer, geometry, render, style]

type
  CellSelection* = object
    ## Anchor and head are screen cells; the range is inclusive and ordered
    ## like a terminal selection, so a head above the anchor selects upward.
    anchorX*: int
    anchorY*: int
    headX*: int
    headY*: int
    present*: bool
    dragging*: bool

func hasSelection*(selection: CellSelection): bool =
  ## True once the head has moved away from the anchor.
  selection.present and (selection.anchorX != selection.headX or
    selection.anchorY != selection.headY)

func clearSelection*(selection: var CellSelection) =
  selection = CellSelection()

func beginSelection*(selection: var CellSelection, x, y: int) =
  selection = CellSelection(anchorX: x, anchorY: y, headX: x, headY: y,
    present: true, dragging: true)

func extendSelection*(selection: var CellSelection, x, y: int): bool =
  ## Moves the head while a drag is in progress; returns whether it moved.
  if not selection.dragging: return false
  if selection.headX == x and selection.headY == y: return false
  selection.headX = x
  selection.headY = y
  true

func endSelection*(selection: var CellSelection) =
  selection.dragging = false

func bounds(selection: CellSelection): tuple[x0, y0, x1, y1: int] =
  if selection.anchorY < selection.headY or
      (selection.anchorY == selection.headY and
        selection.anchorX <= selection.headX):
    (selection.anchorX, selection.anchorY, selection.headX, selection.headY)
  else:
    (selection.headX, selection.headY, selection.anchorX, selection.anchorY)

iterator selectedRows*(selection: CellSelection,
    width: int): tuple[y, x0, x1: int] =
  ## Yields each selected row with its inclusive cell range, clipped to
  ## `width` columns. Middle rows span the full width.
  if selection.hasSelection:
    let (x0, y0, x1, y1) = selection.bounds
    for y in y0 .. y1:
      let first = if y == y0: max(0, x0) else: 0
      let last = if y == y1: min(width - 1, x1) else: width - 1
      if last >= first:
        yield (y, first, last)

proc highlightSelection*(frame: Frame, selection: CellSelection,
    style: Style) =
  ## Restyles the selected cells after everything else has been drawn.
  for row in selection.selectedRows(frame.rect.width):
    frame.tint(rect(row.x0, row.y, row.x1 - row.x0 + 1, 1), style)

proc selectionText*(buffer: Buffer, selection: CellSelection): string =
  ## Copies the glyphs under the selection, one line per row with trailing
  ## blanks trimmed, so the result reads exactly like the screen.
  var first = true
  for row in selection.selectedRows(buffer.width):
    if row.y < 0 or row.y >= buffer.height: continue
    if not first: result.add '\n'
    first = false
    var line: string
    for x in row.x0 .. row.x1:
      let cell = buffer.cellAt(x, row.y)
      if cell.wideTail: continue
      line.add buffer.glyphString(cell)
    result.add line.strip(leading = false)
