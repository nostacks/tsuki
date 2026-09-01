import std/unicode
import ../event
import ../graphemes
import ../layout
import ../render
import ../style

type
  EditorAction* = enum
    eaConsumed, ## The key was handled by the editor.
    eaIgnored,  ## The key was not handled.
    eaSubmit    ## Enter confirmed the editor.

  EditorState* = object
    content*: string      ## UTF-8 text, cursor tracked by grapheme index
    cursor*: int          ## grapheme index into content (0 <= cursor <= graphemeCount)
    scrollOffset*: int    ## column offset so the cursor stays visible
    history*: seq[string] ## caller-owned history lines
    historyIdx*: int      ## index into history while navigating, -1 otherwise

func initEditorState*(): EditorState =
  ## Creates an editor state with an empty draft and no history position.
  EditorState(historyIdx: -1)

func toClusters(s: string): seq[string] =
  for g in s.graphemes:
    result.add g

func spliceStr(s: string, a, b: int, ins: string): string =
  let cls = toClusters(s)
  for i in 0 ..< a:
    result.add cls[i]
  result.add ins
  for i in b ..< cls.len:
    result.add cls[i]

func loadHistory(st: var EditorState) =
  st.content = st.history[st.historyIdx]
  st.cursor = toClusters(st.content).len

func editorKey*(st: var EditorState, k: Key): EditorAction =
  ## Handles one key event for `st`, mutating the content and cursor, and
  ## reports the action: eaConsumed for handled keys, eaSubmit for enter and
  ## eaIgnored for unhandled keys.
  let cls = toClusters(st.content)
  let count = cls.len
  st.cursor = max(0, min(st.cursor, count))
  let ctrl = modCtrl in k.mods
  if k.code == kcEnter:
    return eaSubmit
  if k.code == kcChar and not ctrl:
    st.content = spliceStr(st.content, st.cursor, st.cursor, $k.char)
    inc st.cursor
    return eaConsumed
  if k.code == kcChar and ctrl:
    case k.char
    of Rune(ord('a')):
      st.cursor = 0
      return eaConsumed
    of Rune(ord('e')):
      st.cursor = count
      return eaConsumed
    of Rune(ord('k')):
      st.content = spliceStr(st.content, st.cursor, count, "")
      return eaConsumed
    of Rune(ord('u')):
      st.content = spliceStr(st.content, 0, st.cursor, "")
      st.cursor = 0
      return eaConsumed
    of Rune(ord('w')):
      var start = st.cursor
      while start > 0 and cls[start - 1].runeAt(0).isWhiteSpace:
        dec start
      while start > 0 and not cls[start - 1].runeAt(0).isWhiteSpace:
        dec start
      st.content = spliceStr(st.content, start, st.cursor, "")
      st.cursor = start
      return eaConsumed
    else:
      return eaIgnored
  case k.code
  of kcBackspace:
    if st.cursor > 0:
      st.content = spliceStr(st.content, st.cursor - 1, st.cursor, "")
      dec st.cursor
    eaConsumed
  of kcDelete:
    if st.cursor < count:
      st.content = spliceStr(st.content, st.cursor, st.cursor + 1, "")
    eaConsumed
  of kcLeft:
    if st.cursor > 0:
      dec st.cursor
    eaConsumed
  of kcRight:
    if st.cursor < count:
      inc st.cursor
    eaConsumed
  of kcHome:
    st.cursor = 0
    eaConsumed
  of kcEnd:
    st.cursor = count
    eaConsumed
  of kcUp:
    if st.history.len == 0:
      eaIgnored
    else:
      if st.historyIdx == -1:
        st.historyIdx = st.history.len - 1
      else:
        st.historyIdx = max(0, st.historyIdx - 1)
      st.loadHistory()
      eaConsumed
  of kcDown:
    if st.historyIdx == -1 or st.historyIdx >= st.history.len:
      eaIgnored
    else:
      inc st.historyIdx
      if st.historyIdx >= st.history.len:
        st.content = ""
        st.cursor = 0
      else:
        st.loadHistory()
      eaConsumed
  else:
    eaIgnored

proc editor*(f: Frame, st: var EditorState, focused = true, placeholder = "") =
  ## Draws the editor line into the frame rect, vertically centered when the
  ## rect is taller than one row, and updates `st.scrollOffset` so the cursor
  ## stays visible. A focused editor renders the cell under the cursor with
  ## the reverse attribute; an empty editor with a `placeholder` shows the
  ## placeholder dimmed instead and draws no cursor.
  if f.rect.isEmpty:
    return
  let row = if f.rect.height > 1: f.rect.height div 2 else: 0
  let width = f.rect.width
  let cls = toClusters(st.content)
  let count = cls.len
  st.cursor = max(0, min(st.cursor, count))
  var starts = newSeq[int](count)
  var col = 0
  for i in 0 ..< count:
    starts[i] = col
    inc col, cls[i].clusterWidth
  let totalCols = col
  let cursorCol = if st.cursor < count: starts[st.cursor] else: totalCols
  if st.scrollOffset > cursorCol:
    st.scrollOffset = cursorCol
  while cursorCol - st.scrollOffset >= width and st.scrollOffset < totalCols:
    var next = -1
    for i in 0 ..< count:
      if starts[i] > st.scrollOffset:
        next = starts[i]
        break
    if next < 0:
      break
    st.scrollOffset = next
  let showPlaceholder = cls.len == 0 and placeholder.len > 0
  if showPlaceholder:
    f.write(0, row, placeholder, f.style.withAttrs({attrDim}))
  else:
    var slice = ""
    for i in 0 ..< count:
      if starts[i] >= st.scrollOffset and starts[i] < st.scrollOffset + width:
        slice.add cls[i]
    f.write(0, row, slice)
  if focused and not showPlaceholder:
    let cx = cursorCol - st.scrollOffset
    if cx >= 0 and cx < width:
      let under = if st.cursor < count: cls[st.cursor] else: " "
      f.write(cx, row, under, f.style.withAttrs({attrReverse}))
