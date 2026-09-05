## Unified and side-by-side safe diff views.

import std/strutils
import ../[geometry, render, scroll, style, text]
import ../widgets/display
import theme

type
  DiffMode* = enum
    diffUnified
    diffSideBySide

  DiffViewState* = object
    scroll*: ScrollState
    mode*: DiffMode

func diffStyle*(line: string, colors: AgentTheme): tuple[cue: string,
    style: Style] =
  ## Redundant symbol cue and style for one unified-diff line.
  if line.startsWith("+++") or line.startsWith("---") or
      line.startsWith("@@"):
    ("·", colors.base.accent)
  elif line.startsWith("+"):
    ("+", colors.base.diffAdd)
  elif line.startsWith("-"):
    ("−", colors.base.diffRemove)
  else:
    (" ", colors.base.text)

proc diffRows*(source: string, colors = agentTheme()): seq[Line] =
  ## Shared unified-diff rows used by the diff view and the transcript. Each
  ## row keeps a redundant symbol cue so status never depends on color alone.
  for line in sanitizeText(source).splitLines:
    let styled = line.diffStyle(colors)
    let body = if line.len > 0 and line[0] in {'+', '-'}:
      line[1 ..< line.len] else: line
    var row = Line()
    row.spans.add Span(text: styled.cue & " ", style: styled.style)
    row.spans.add Span(text: body, style: styled.style)
    result.add row

proc unified(frame: Frame, lines: seq[string], state: var DiffViewState,
    colors: AgentTheme) =
  state.scroll.update(frame.rect.width, frame.rect.height,
    frame.rect.width, lines.len)
  let first = state.scroll.offsetY
  let last = min(lines.len, first + frame.rect.height)
  for index in first ..< last:
    let styled = lines[index].diffStyle(colors)
    let body = if lines[index].len > 0 and lines[index][0] in {'+', '-'}:
      lines[index][1 ..< lines[index].len] else: lines[index]
    frame.write(0, index - first,
      (styled.cue & " " & body).truncateCells(frame.rect.width, true),
      styled.style)

proc sideBySide(frame: Frame, lines: seq[string], state: var DiffViewState,
    colors: AgentTheme) =
  type Pair = tuple[oldLine, newLine: string, oldNo, newNo: int]
  var rows: seq[Pair]
  var oldNo = 0
  var newNo = 0
  var pending = ""
  var pendingNo = 0
  for line in lines:
    if line.startsWith("-") and not line.startsWith("---"):
      inc oldNo
      if pending.len > 0: rows.add (pending, "", pendingNo, 0)
      pending = line[1 ..< line.len]
      pendingNo = oldNo
    elif line.startsWith("+") and not line.startsWith("+++"):
      inc newNo
      rows.add (pending, line[1 ..< line.len], pendingNo, newNo)
      pending.setLen 0
      pendingNo = 0
    else:
      if pending.len > 0:
        rows.add (pending, "", pendingNo, 0)
        pending.setLen 0
      if not line.startsWith("@@") and not line.startsWith("---") and
          not line.startsWith("+++"):
        inc oldNo
        inc newNo
        rows.add (line, line, oldNo, newNo)
  if pending.len > 0: rows.add (pending, "", pendingNo, 0)
  let half = max(1, (frame.rect.width - 1) div 2)
  state.scroll.update(frame.rect.width, frame.rect.height,
    frame.rect.width, rows.len)
  let first = state.scroll.offsetY
  let last = min(rows.len, first + frame.rect.height)
  for index in first ..< last:
    let row = rows[index]
    let left = (if row.oldNo > 0: align($row.oldNo, 4) &
        " − " else: "      ") &
      row.oldLine
    let right = (if row.newNo > 0: align($row.newNo, 4) &
        " + " else: "      ") &
      row.newLine
    let y = index - first
    frame.write(0, y, left.truncateCells(half, true),
      if row.oldLine != row.newLine: colors.base.diffRemove else: colors.base.text)
    frame.write(half, y, "│", colors.base.border)
    frame.write(half + 1, y, right.truncateCells(half, true),
      if row.oldLine != row.newLine: colors.base.diffAdd else: colors.base.text)

proc diffView*(frame: Frame, source: string, state: var DiffViewState,
    colors = agentTheme()) =
  ## Renders a sanitized unified diff. Side-by-side automatically falls back on
  ## terminals narrower than 100 cells.
  let lines = sanitizeText(source).splitLines
  if state.mode == diffSideBySide and frame.rect.width >= 100:
    frame.sideBySide(lines, state, colors)
  else:
    frame.unified(lines, state, colors)
