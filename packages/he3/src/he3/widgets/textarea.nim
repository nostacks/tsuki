## Multiline grapheme editor with selection, undo/redo, paste, and scrolling.

import std/unicode
import ../[event, geometry, graphemes, render, scroll, text, theme]
import display

type
  TextareaAction* = enum
    taIgnored
    taChanged
    taMoved
    taSubmit
    taCopy

  EditSnapshot = object
    content: string
    cursor: int
    anchor: int

  SnapshotHistory = object
    items: seq[EditSnapshot]
    start: int
    count: int

  TextareaState* = object
    content*: string
    cursor*: int
    selectionAnchor*: int
    preferredColumn*: int
    scroll*: ScrollState
    undoStack: SnapshotHistory
    redoStack: SnapshotHistory
    maxUndo*: int
    history*: seq[string]
    historyIndex*: int

func initTextareaState*(content = "", maxUndo = 100): TextareaState =
  ## Creates sanitized multiline state with no active selection.
  TextareaState(content: sanitizeText(content), selectionAnchor: -1,
    preferredColumn: -1, maxUndo: max(1, maxUndo), historyIndex: -1)

type Cluster = Slice[int]
  ## Inclusive byte range of one grapheme cluster inside the content.

func clusters(value: string): seq[Cluster] =
  for span in value.graphemeSpans:
    result.add span

func clusterCount(value: string): int =
  for unused in value.graphemeSpans: inc result

func isNewline(value: string, cluster: Cluster): bool {.inline.} =
  cluster.a == cluster.b and value[cluster.a] == '\n'

func width(value: string, cluster: Cluster): int {.inline.} =
  clusterWidth(value.toOpenArray(cluster.a, cluster.b))

func startsWithSpace(value: string, cluster: Cluster): bool {.inline.} =
  value.runeAt(cluster.a).isWhiteSpace

func byteAt(value: string, items: openArray[Cluster], index: int): int =
  ## Byte offset where cluster `index` starts, or the length past the end.
  if index < items.len: items[index].a else: value.len

func splice(value: string, first, last: int, insertion: string): string =
  let items = value.clusters
  let a = value.byteAt(items, clamp(first, 0, items.len))
  let b = max(a, value.byteAt(items, clamp(last, 0, items.len)))
  result = newStringOfCap(a + insertion.len + value.len - b)
  result.addChars value.toOpenArray(0, a - 1)
  result.add insertion
  result.addChars value.toOpenArray(b, value.len - 1)

func hasSelection*(state: TextareaState): bool =
  ## True when anchor and cursor delimit a nonempty range.
  state.selectionAnchor >= 0 and state.selectionAnchor != state.cursor

func selectionRange*(state: TextareaState): tuple[first, last: int] =
  ## Returns the ordered half-open selected grapheme range.
  if not state.hasSelection:
    return (state.cursor, state.cursor)
  (min(state.cursor, state.selectionAnchor),
    max(state.cursor, state.selectionAnchor))

func selectedText*(state: TextareaState): string =
  ## Returns the selected safe text for an explicit host copy action.
  let selection = state.selectionRange
  let items = state.content.clusters
  let a = state.content.byteAt(items, clamp(selection.first, 0, items.len))
  let b = state.content.byteAt(items, clamp(selection.last, 0, items.len))
  if b > a:
    result = state.content[a ..< b]

proc push(history: var SnapshotHistory, snapshot: sink EditSnapshot,
    capacity: int) =
  let capacity = max(1, capacity)
  if history.items.len != capacity:
    history.items = newSeq[EditSnapshot](capacity)
    history.start = 0
    history.count = 0
  let index = (history.start + history.count) mod capacity
  history.items[index] = move(snapshot)
  if history.count < capacity:
    inc history.count
  else:
    history.start = (history.start + 1) mod capacity

proc pop(history: var SnapshotHistory, snapshot: var EditSnapshot): bool =
  if history.count == 0 or history.items.len == 0:
    return false
  let index = (history.start + history.count - 1) mod history.items.len
  snapshot = move(history.items[index])
  history.items[index] = EditSnapshot()
  dec history.count
  true

proc clear(history: var SnapshotHistory) =
  history.start = 0
  history.count = 0

proc remember(state: var TextareaState) =
  state.undoStack.push(EditSnapshot(content: state.content,
    cursor: state.cursor, anchor: state.selectionAnchor), state.maxUndo)
  state.redoStack.clear()

proc restore(state: var TextareaState, source: var SnapshotHistory,
    destination: var SnapshotHistory): bool =
  var snapshot: EditSnapshot
  if not source.pop(snapshot): return false
  destination.push(EditSnapshot(content: state.content, cursor: state.cursor,
    anchor: state.selectionAnchor), state.maxUndo)
  state.content = snapshot.content
  state.cursor = snapshot.cursor
  state.selectionAnchor = snapshot.anchor
  true

proc deleteSelection(state: var TextareaState): bool =
  if not state.hasSelection: return false
  let selection = state.selectionRange
  state.content = splice(state.content, selection.first, selection.last, "")
  state.cursor = selection.first
  state.selectionAnchor = -1
  true

proc replaceSelection(state: var TextareaState, insertion: string) =
  let safe = sanitizeText(insertion)
  let selection = state.selectionRange
  state.content = splice(state.content, selection.first, selection.last, safe)
  state.cursor = selection.first + safe.clusterCount
  state.selectionAnchor = -1

func lineColumn(value: string, items: openArray[Cluster],
    cursor: int): tuple[row, column: int] =
  for index in 0 ..< min(cursor, items.len):
    if value.isNewline(items[index]):
      inc result.row
      result.column = 0
    else:
      inc result.column, value.width(items[index])

func indexAt(value: string, items: openArray[Cluster],
    wantedRow, wantedColumn: int): int =
  var row = 0
  var column = 0
  for index, cluster in items:
    let newline = value.isNewline(cluster)
    if row == wantedRow and (column >= wantedColumn or newline):
      return index
    if newline:
      if row == wantedRow: return index
      inc row
      column = 0
    else:
      let clusterWidth = value.width(cluster)
      if row == wantedRow and column + clusterWidth > wantedColumn:
        return index
      inc column, clusterWidth
  items.len

proc prepareSelection(state: var TextareaState, shift: bool, oldCursor: int) =
  if shift:
    if state.selectionAnchor < 0: state.selectionAnchor = oldCursor
  else:
    state.selectionAnchor = -1

proc textareaEvent*(state: var TextareaState, event: Event,
    submitOnEnter = false, readOnly = false): TextareaAction =
  ## Handles grapheme navigation, selection, editing, paste, undo/redo, and
  ## configurable multiline submit. Copy returns `taCopy`; the host decides
  ## whether and where to write clipboard data.
  let items = state.content.clusters
  state.cursor = clamp(state.cursor, 0, items.len)
  if event.kind == evPaste:
    if readOnly: return taIgnored
    if event.text.len == 0 and not state.hasSelection: return taIgnored
    state.remember()
    state.replaceSelection(event.text)
    return taChanged
  if event.kind != evKey or event.key.released:
    return taIgnored
  let key = event.key
  let ctrl = modCtrl in key.mods
  let shift = modShift in key.mods
  if ctrl and key.code == kcChar:
    case key.char
    of Rune(ord('a')):
      state.selectionAnchor = 0
      state.cursor = items.len
      return taMoved
    of Rune(ord('c')):
      if state.hasSelection: return taCopy else: return taIgnored
    of Rune(ord('x')):
      if readOnly or not state.hasSelection: return taIgnored
      state.remember()
      discard state.deleteSelection()
      return taChanged
    of Rune(ord('u')):
      # Readline unix-line-discard: clears the whole draft, undoable.
      if readOnly or state.content.len == 0: return taIgnored
      state.remember()
      state.content = ""
      state.cursor = 0
      state.selectionAnchor = -1
      state.preferredColumn = -1
      return taChanged
    of Rune(ord('k')):
      # Readline kill-to-end.
      if readOnly or state.cursor >= items.len: return taIgnored
      state.remember()
      discard state.deleteSelection()
      state.content = splice(state.content, state.cursor, items.len, "")
      state.selectionAnchor = -1
      return taChanged
    of Rune(ord('w')):
      # Readline backward-kill-word.
      if readOnly or state.cursor <= 0: return taIgnored
      state.remember()
      if not state.deleteSelection() and state.cursor > 0:
        var cut = state.cursor
        while cut > 0 and state.content.startsWithSpace(items[cut - 1]):
          dec cut
        while cut > 0 and not state.content.startsWithSpace(items[cut - 1]):
          dec cut
        state.content = splice(state.content, cut, state.cursor, "")
        state.cursor = cut
      state.selectionAnchor = -1
      return taChanged
    of Rune(ord('z')):
      if readOnly: return taIgnored
      return if state.restore(state.undoStack, state.redoStack): taChanged
        else: taIgnored
    of Rune(ord('y')):
      if readOnly: return taIgnored
      return if state.restore(state.redoStack, state.undoStack): taChanged
        else: taIgnored
    else: discard
  if key.code == kcEnter:
    # Shift-Enter and Alt/Option-Enter insert a newline: kitty-capable
    # terminals report Shift-Enter distinctly, while legacy terminals that
    # cannot distinguish it still offer the Alt-Enter path.
    if submitOnEnter and not (shift or modAlt in key.mods): return taSubmit
    if readOnly: return taIgnored
    state.remember()
    state.replaceSelection("\n")
    return taChanged
  if key.code == kcChar and not ctrl:
    if readOnly: return taIgnored
    state.remember()
    state.replaceSelection($key.char)
    return taChanged
  let oldCursor = state.cursor
  case key.code
  of kcLeft:
    if ctrl:
      while state.cursor > 0 and
          state.content.startsWithSpace(items[state.cursor - 1]):
        dec state.cursor
      while state.cursor > 0 and
          not state.content.startsWithSpace(items[state.cursor - 1]):
        dec state.cursor
    else: state.cursor = max(0, state.cursor - 1)
  of kcRight:
    if ctrl:
      while state.cursor < items.len and
          not state.content.startsWithSpace(items[state.cursor]):
        inc state.cursor
      while state.cursor < items.len and
          state.content.startsWithSpace(items[state.cursor]):
        inc state.cursor
    else: state.cursor = min(items.len, state.cursor + 1)
  of kcUp, kcDown:
    let position = state.content.lineColumn(items, state.cursor)
    if state.preferredColumn < 0: state.preferredColumn = position.column
    let targetRow = max(0, position.row + (if key.code == kcUp: -1 else: 1))
    state.cursor = state.content.indexAt(items, targetRow,
      state.preferredColumn)
  of kcHome:
    let position = state.content.lineColumn(items, state.cursor)
    state.cursor = state.content.indexAt(items, position.row, 0)
  of kcEnd:
    let position = state.content.lineColumn(items, state.cursor)
    state.cursor = state.content.indexAt(items, position.row, high(int))
  of kcBackspace:
    if readOnly: return taIgnored
    if not state.hasSelection and state.cursor <= 0: return taIgnored
    state.remember()
    if not state.deleteSelection() and state.cursor > 0:
      state.content = splice(state.content, state.cursor - 1, state.cursor, "")
      dec state.cursor
    return taChanged
  of kcDelete:
    if readOnly: return taIgnored
    if not state.hasSelection and state.cursor >= items.len: return taIgnored
    state.remember()
    if not state.deleteSelection() and state.cursor < items.len:
      state.content = splice(state.content, state.cursor, state.cursor + 1, "")
    return taChanged
  else: return taIgnored
  state.prepareSelection(shift, oldCursor)
  if key.code notin {kcUp, kcDown}: state.preferredColumn = -1
  if state.cursor != oldCursor: taMoved else: taIgnored

proc positionCursor*(state: var TextareaState, row, column: int,
    extendSelection = false) =
  ## Positions the cursor from a mouse-derived logical row/cell column.
  let items = state.content.clusters
  let previous = state.cursor
  state.cursor = state.content.indexAt(items, max(0, row), max(0, column))
  state.prepareSelection(extendSelection, previous)

proc textarea*(frame: Frame, state: var TextareaState, focused = true,
    placeholder = "", masked = false, readOnly = false,
    colors = darkTheme()) =
  ## Draws multiline text with vertical/horizontal scrolling, selection, and a
  ## visible block cursor. A placeholder supplements rather than replaces the
  ## host's persistent field label.
  if frame.rect.isEmpty: return
  let items = state.content.clusters
  state.cursor = clamp(state.cursor, 0, items.len)
  let cursorPosition = state.content.lineColumn(items, state.cursor)
  var rowCount = 1
  var maxWidth = 0
  var rowWidth = 0
  for cluster in items:
    if state.content.isNewline(cluster):
      maxWidth = max(maxWidth, rowWidth)
      rowWidth = 0
      inc rowCount
    else: inc rowWidth, state.content.width(cluster)
  maxWidth = max(maxWidth, rowWidth + 1)
  state.scroll.update(frame.rect.width, frame.rect.height, maxWidth, rowCount)
  if cursorPosition.row < state.scroll.offsetY:
    state.scroll.offsetY = cursorPosition.row
  elif cursorPosition.row >= state.scroll.offsetY + frame.rect.height:
    state.scroll.offsetY = cursorPosition.row - frame.rect.height + 1
  if cursorPosition.column < state.scroll.offsetX:
    state.scroll.offsetX = cursorPosition.column
  elif cursorPosition.column >= state.scroll.offsetX + frame.rect.width:
    state.scroll.offsetX = cursorPosition.column - frame.rect.width + 1
  state.scroll.clamp()
  if items.len == 0 and placeholder.len > 0:
    let shown = placeholder.truncateCells(frame.rect.width, true)
    frame.write(0, 0, shown, colors.muted)
    if focused:
      var cursorGlyph = " "
      for span in shown.graphemeSpans:
        cursorGlyph = shown[span]
        break
      frame.write(0, 0, cursorGlyph, colors.focus)
    return
  let selection = state.selectionRange
  var row = 0
  var column = 0
  for index, cluster in items:
    if state.content.isNewline(cluster):
      inc row
      column = 0
      continue
    let width = state.content.width(cluster)
    let screenY = row - state.scroll.offsetY
    let screenX = column - state.scroll.offsetX
    if screenY >= 0 and screenY < frame.rect.height and screenX >= 0 and
        screenX + width <= frame.rect.width:
      let selected = index >= selection.first and index < selection.last
      let cellStyle = if selected: colors.selection else: colors.text
      if masked:
        frame.write(screenX, screenY, "•", cellStyle)
      else:
        frame.write(screenX, screenY,
          state.content.toOpenArray(cluster.a, cluster.b), cellStyle)
    inc column, width
  if focused:
    let x = cursorPosition.column - state.scroll.offsetX
    let y = cursorPosition.row - state.scroll.offsetY
    if x >= 0 and x < frame.rect.width and y >= 0 and y < frame.rect.height:
      if state.cursor < items.len and
          not state.content.isNewline(items[state.cursor]):
        if masked:
          frame.write(x, y, "•", colors.focus)
        else:
          let cluster = items[state.cursor]
          frame.write(x, y, state.content.toOpenArray(cluster.a, cluster.b),
            colors.focus)
      else:
        frame.write(x, y, " ", colors.focus)
