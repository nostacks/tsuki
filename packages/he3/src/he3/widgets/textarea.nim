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

func clusters(value: string): seq[string] =
  for cluster in value.graphemes:
    result.add cluster

func clusterCount(value: string): int =
  for unused in value.graphemes: inc result

func splice(value: string, first, last: int, insertion: string): string =
  let items = value.clusters
  for index in 0 ..< clamp(first, 0, items.len): result.add items[index]
  result.add insertion
  for index in clamp(last, 0, items.len) ..< items.len: result.add items[index]

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
  for index in selection.first ..< selection.last:
    if index >= 0 and index < items.len: result.add items[index]

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

func lineColumn(items: openArray[string], cursor: int): tuple[row, column: int] =
  for index in 0 ..< min(cursor, items.len):
    if items[index] == "\n":
      inc result.row
      result.column = 0
    else:
      inc result.column, items[index].clusterWidth

func indexAt(items: openArray[string], wantedRow, wantedColumn: int): int =
  var row = 0
  var column = 0
  for index, cluster in items:
    if row == wantedRow and (column >= wantedColumn or cluster == "\n"):
      return index
    if cluster == "\n":
      if row == wantedRow: return index
      inc row
      column = 0
    else:
      if row == wantedRow and column + cluster.clusterWidth > wantedColumn:
        return index
      inc column, cluster.clusterWidth
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
        while cut > 0 and items[cut - 1].runeAt(0).isWhiteSpace: dec cut
        while cut > 0 and not items[cut - 1].runeAt(0).isWhiteSpace: dec cut
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
      while state.cursor > 0 and items[state.cursor - 1].runeAt(0).isWhiteSpace:
        dec state.cursor
      while state.cursor > 0 and not items[state.cursor - 1].runeAt(
          0).isWhiteSpace:
        dec state.cursor
    else: state.cursor = max(0, state.cursor - 1)
  of kcRight:
    if ctrl:
      while state.cursor < items.len and not items[state.cursor].runeAt(
          0).isWhiteSpace:
        inc state.cursor
      while state.cursor < items.len and items[state.cursor].runeAt(
          0).isWhiteSpace:
        inc state.cursor
    else: state.cursor = min(items.len, state.cursor + 1)
  of kcUp, kcDown:
    let position = lineColumn(items, state.cursor)
    if state.preferredColumn < 0: state.preferredColumn = position.column
    let targetRow = max(0, position.row + (if key.code == kcUp: -1 else: 1))
    state.cursor = indexAt(items, targetRow, state.preferredColumn)
  of kcHome:
    let position = lineColumn(items, state.cursor)
    state.cursor = indexAt(items, position.row, 0)
  of kcEnd:
    let position = lineColumn(items, state.cursor)
    state.cursor = indexAt(items, position.row, high(int))
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
  state.cursor = indexAt(items, max(0, row), max(0, column))
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
  let cursorPosition = lineColumn(items, state.cursor)
  var rowCount = 1
  var maxWidth = 0
  var rowWidth = 0
  for cluster in items:
    if cluster == "\n":
      maxWidth = max(maxWidth, rowWidth)
      rowWidth = 0
      inc rowCount
    else: inc rowWidth, cluster.clusterWidth
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
      for cluster in shown.graphemes:
        cursorGlyph = cluster
        break
      frame.write(0, 0, cursorGlyph, colors.focus)
    return
  let selection = state.selectionRange
  var row = 0
  var column = 0
  for index, cluster in items:
    if cluster == "\n":
      inc row
      column = 0
      continue
    let width = cluster.clusterWidth
    let screenY = row - state.scroll.offsetY
    let screenX = column - state.scroll.offsetX
    if screenY >= 0 and screenY < frame.rect.height and screenX >= 0 and
        screenX + width <= frame.rect.width:
      let shown = if masked: "•" else: cluster
      let selected = index >= selection.first and index < selection.last
      let cellStyle = if selected: colors.selection else: colors.text
      frame.write(screenX, screenY, shown, cellStyle)
    inc column, width
  if focused:
    let x = cursorPosition.column - state.scroll.offsetX
    let y = cursorPosition.row - state.scroll.offsetY
    if x >= 0 and x < frame.rect.width and y >= 0 and y < frame.rect.height:
      let under = if state.cursor < items.len and items[state.cursor] != "\n":
        (if masked: "•" else: items[state.cursor]) else: " "
      frame.write(x, y, under, colors.focus)
