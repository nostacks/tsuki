import std/unicode
import common
import tsuki/tui/event
import tsuki/tui/style
import tsuki/tui/buffer
import tsuki/tui/layout
import tsuki/tui/render
import tsuki/tui/widgets/editor

func key(code: KeyCode): Key =
  initKey(code)

func charKey(r: Rune): Key =
  initKey(kcChar, r)

func ctrlKey(r: Rune): Key =
  initKey(kcChar, r, {modCtrl})

proc testInsert =
  var st = initEditorState()
  check st.editorKey(charKey(Rune(ord('a')))) == eaConsumed, "insert consumed"
  check st.content == "a", "insert into empty"
  check st.cursor == 1, "cursor after insert"
  st.content = "abcd"
  st.cursor = 2
  discard st.editorKey(charKey(Rune(ord('X'))))
  check st.content == "abXcd", "insert at middle"
  check st.cursor == 3, "cursor after middle insert"
  st.content = "abcd"
  st.cursor = 4
  discard st.editorKey(charKey(Rune(ord('Z'))))
  check st.content == "abcdZ", "insert at end"
  check st.cursor == 5, "cursor after end insert"
  st.content = "bc"
  st.cursor = 0
  discard st.editorKey(charKey(Rune(ord('a'))))
  check st.content == "abc", "insert at start"
  check st.cursor == 1, "cursor after start insert"

proc testBackspaceDelete =
  var st = initEditorState()
  st.content = "abc"
  st.cursor = 0
  check st.editorKey(key(kcBackspace)) == eaConsumed, "backspace at 0 consumed"
  check st.content == "abc", "backspace at 0 keeps content"
  check st.cursor == 0, "backspace at 0 keeps cursor"
  st.cursor = 3
  discard st.editorKey(key(kcBackspace))
  check st.content == "ab", "backspace deletes before cursor"
  check st.cursor == 2, "cursor after backspace"
  st.content = "abc"
  st.cursor = 3
  check st.editorKey(key(kcDelete)) == eaConsumed, "delete at end consumed"
  check st.content == "abc", "delete at end keeps content"
  check st.cursor == 3, "delete at end keeps cursor"
  st.cursor = 1
  discard st.editorKey(key(kcDelete))
  check st.content == "ac", "delete removes at cursor"
  check st.cursor == 1, "cursor after delete"

proc testMovement =
  var st = initEditorState()
  st.content = "abc"
  st.cursor = 1
  discard st.editorKey(key(kcRight))
  check st.cursor == 2, "right moves"
  discard st.editorKey(key(kcRight))
  check st.cursor == 3, "right to end"
  discard st.editorKey(key(kcRight))
  check st.cursor == 3, "right clamped at end"
  discard st.editorKey(key(kcLeft))
  check st.cursor == 2, "left moves"
  st.cursor = 0
  discard st.editorKey(key(kcLeft))
  check st.cursor == 0, "left clamped at 0"
  discard st.editorKey(key(kcHome))
  check st.cursor == 0, "home to start"
  discard st.editorKey(key(kcEnd))
  check st.cursor == 3, "end to finish"
  st.cursor = 2
  discard st.editorKey(ctrlKey(Rune(ord('a'))))
  check st.cursor == 0, "ctrl+a to start"
  st.cursor = 1
  discard st.editorKey(ctrlKey(Rune(ord('e'))))
  check st.cursor == 3, "ctrl+e to finish"

proc testCtrlKUW =
  var st = initEditorState()
  st.content = "abcdef"
  st.cursor = 2
  check st.editorKey(ctrlKey(Rune(ord('k')))) == eaConsumed, "ctrl+k consumed"
  check st.content == "ab", "ctrl+k kills to end"
  check st.cursor == 2, "cursor after ctrl+k"
  st.content = "abcdef"
  st.cursor = 2
  check st.editorKey(ctrlKey(Rune(ord('u')))) == eaConsumed, "ctrl+u consumed"
  check st.content == "cdef", "ctrl+u kills start to cursor"
  st.content = "foo bar  baz"
  st.cursor = 12
  discard st.editorKey(ctrlKey(Rune(ord('w'))))
  check st.content == "foo bar  ", "ctrl+w kills word"
  check st.cursor == 9, "cursor after ctrl+w"
  discard st.editorKey(ctrlKey(Rune(ord('w'))))
  check st.content == "foo ", "ctrl+w kills word and spaces"
  check st.cursor == 4, "cursor after second ctrl+w"
  discard st.editorKey(ctrlKey(Rune(ord('w'))))
  check st.content == "", "ctrl+w kills to empty"
  check st.cursor == 0, "cursor after third ctrl+w"
  st.content = "   "
  st.cursor = 3
  discard st.editorKey(ctrlKey(Rune(ord('w'))))
  check st.content == "", "ctrl+w kills only spaces"
  check st.cursor == 0, "cursor after killing spaces"
  st.content = "abc"
  st.cursor = 0
  discard st.editorKey(ctrlKey(Rune(ord('w'))))
  check st.content == "abc", "ctrl+w at 0 no-op"
  check st.cursor == 0, "cursor stays 0"

proc testIgnoredAndSubmit =
  var st = initEditorState()
  st.content = "abc"
  st.cursor = 1
  check st.editorKey(key(kcEscape)) == eaIgnored, "escape ignored"
  check st.editorKey(key(kcTab)) == eaIgnored, "tab ignored"
  check st.editorKey(key(kcPageUp)) == eaIgnored, "page up ignored"
  check st.editorKey(key(kcNone)) == eaIgnored, "none ignored"
  check st.editorKey(ctrlKey(Rune(ord('x')))) == eaIgnored, "ctrl+x ignored"
  check st.content == "abc", "ignored keys keep content"
  check st.cursor == 1, "ignored keys keep cursor"
  check st.editorKey(key(kcEnter)) == eaSubmit, "enter submits"
  check st.content == "abc", "enter keeps content"
  check st.cursor == 1, "enter keeps cursor"

proc testHistory =
  var st = initEditorState()
  st.history = @["one", "two", "three"]
  check st.editorKey(key(kcUp)) == eaConsumed, "history up consumed"
  check st.content == "three", "up loads newest"
  check st.cursor == 5, "cursor at end of loaded entry"
  check st.historyIdx == 2, "historyIdx at newest"
  discard st.editorKey(key(kcUp))
  check st.content == "two" and st.historyIdx == 1, "up walks back"
  discard st.editorKey(key(kcUp))
  check st.content == "one" and st.historyIdx == 0, "up to oldest"
  discard st.editorKey(key(kcUp))
  check st.content == "one" and st.historyIdx == 0, "up clamped at oldest"
  discard st.editorKey(key(kcDown))
  check st.content == "two" and st.historyIdx == 1, "down walks forward"
  discard st.editorKey(key(kcDown))
  check st.content == "three" and st.historyIdx == 2, "down to newest"
  discard st.editorKey(key(kcDown))
  check st.content == "", "down past newest empties draft"
  check st.cursor == 0, "cursor reset past newest"
  check st.historyIdx == 3, "historyIdx past end"
  check st.editorKey(key(kcDown)) == eaIgnored, "down ignored past end"
  discard st.editorKey(key(kcUp))
  check st.content == "three" and st.historyIdx == 2, "up reenters history"
  var empty = initEditorState()
  check empty.editorKey(key(kcUp)) == eaIgnored, "up ignored with no history"
  check empty.editorKey(key(kcDown)) == eaIgnored, "down ignored with no history"
  st.content = "draft"
  st.cursor = 3
  discard st.editorKey(key(kcEnter))
  check st.content == "draft", "enter keeps draft"

proc testWide =
  var st = initEditorState()
  st.content = "你好"
  st.cursor = 2
  check st.editorKey(key(kcLeft)) == eaConsumed, "wide left consumed"
  check st.cursor == 1, "left moves one grapheme"
  discard st.editorKey(key(kcLeft))
  check st.cursor == 0, "left reaches 0 in two steps"
  st.content = "你好"
  st.cursor = 2
  discard st.editorKey(key(kcBackspace))
  check st.content == "你", "backspace deletes one wide grapheme"
  check st.cursor == 1, "cursor after wide backspace"
  discard st.editorKey(key(kcBackspace))
  check st.content == "", "backspace empties wide content"
  check st.cursor == 0, "cursor after emptying"
  st.content = "你好"
  st.cursor = 0
  discard st.editorKey(key(kcDelete))
  check st.content == "好", "delete removes first wide grapheme"
  check st.cursor == 0, "cursor after wide delete"
  st.content = "ab"
  st.cursor = 1
  discard st.editorKey(charKey(Rune(0x4F60)))
  check st.content == "a你b", "insert wide char"
  check st.cursor == 2, "cursor after wide insert"
  discard st.editorKey(key(kcLeft))
  check st.cursor == 1, "left over wide char"
  discard st.editorKey(key(kcRight))
  check st.cursor == 2, "right over wide char"
  discard st.editorKey(ctrlKey(Rune(ord('a'))))
  check st.cursor == 0, "ctrl+a over wide char"
  discard st.editorKey(ctrlKey(Rune(ord('e'))))
  check st.cursor == 3, "ctrl+e counts wide graphemes"
  st.content = "你好 世界"
  st.cursor = 5
  discard st.editorKey(ctrlKey(Rune(ord('w'))))
  check st.content == "你好 ", "ctrl+w kills wide word"
  check st.cursor == 3, "cursor after wide ctrl+w"

proc testDrawCursor =
  var b = initBuffer(20, 1)
  var f = initFrame(b, initRect(0, 0, 10, 1))
  var st = initEditorState()
  st.content = "abc"
  st.cursor = 1
  f.editor(st)
  check b.cellAt(1, 0).rune == Rune(ord('b')), "cursor cell keeps rune"
  check attrReverse in b.cellAt(1, 0).style.attrs, "cursor cell reversed"
  check b.cellAt(0, 0).rune == Rune(ord('a')), "content drawn"
  check attrReverse notin b.cellAt(0, 0).style.attrs, "other cells plain"
  check b.cellAt(2, 0).rune == Rune(ord('c')), "trailing content drawn"

proc testDrawPlaceholder =
  var b = initBuffer(20, 1)
  var f = initFrame(b, initRect(0, 0, 10, 1))
  var st = initEditorState()
  f.editor(st, true, "hi")
  check b.cellAt(0, 0).rune == Rune(ord('h')), "placeholder drawn"
  check b.cellAt(1, 0).rune == Rune(ord('i')), "placeholder continues"
  check attrDim in b.cellAt(0, 0).style.attrs, "placeholder dimmed"
  check attrReverse notin b.cellAt(0, 0).style.attrs, "no cursor on placeholder"
  check attrReverse notin b.cellAt(1, 0).style.attrs, "no cursor on placeholder 2"
  f.editor(st, true, "")
  check b.cellAt(0, 0).rune == Rune(0x0020), "empty editor cursor cell blank"
  check attrReverse in b.cellAt(0, 0).style.attrs, "cursor on blank cell"
  var b2 = initBuffer(20, 1)
  var f2 = initFrame(b2, initRect(0, 0, 10, 1))
  var st2 = initEditorState()
  st2.content = "abc"
  st2.cursor = 1
  f2.editor(st2, false)
  check b2.cellAt(0, 0).rune == Rune(ord('a')), "unfocused draws content"
  check attrReverse notin b2.cellAt(0, 0).style.attrs, "unfocused no cursor 0"
  check attrReverse notin b2.cellAt(1, 0).style.attrs, "unfocused no cursor 1"
  check attrReverse notin b2.cellAt(2, 0).style.attrs, "unfocused no cursor 2"

proc testDrawScroll =
  var b = initBuffer(20, 1)
  var f = initFrame(b, initRect(0, 0, 10, 1))
  var st = initEditorState()
  st.content = "abcdefghijklmnopqrst"
  discard st.editorKey(key(kcEnd))
  f.editor(st)
  check st.scrollOffset == 11, "scroll follows cursor to end"
  check b.cellAt(0, 0).rune == Rune(ord('l')), "left slice at offset"
  check b.cellAt(8, 0).rune == Rune(ord('t')), "last content cell"
  check b.cellAt(9, 0).rune == Rune(0x0020), "cursor past content blank"
  check attrReverse in b.cellAt(9, 0).style.attrs, "end cursor reversed"
  discard st.editorKey(key(kcHome))
  f.editor(st)
  check st.scrollOffset == 0, "scroll back to 0 at start"
  check b.cellAt(0, 0).rune == Rune(ord('a')), "start cursor cell"
  check attrReverse in b.cellAt(0, 0).style.attrs, "start cursor reversed"
  check b.cellAt(1, 0).rune == Rune(ord('b')), "start content follows"

proc testDrawWide =
  var b = initBuffer(8, 1)
  var f = initFrame(b, initRect(0, 0, 8, 1))
  var st = initEditorState()
  st.content = "你好"
  st.cursor = 1
  f.editor(st)
  check b.cellAt(0, 0).rune == Rune(0x4F60), "first wide rune"
  check attrReverse notin b.cellAt(0, 0).style.attrs, "first cell plain"
  check b.cellAt(2, 0).rune == Rune(0x597D), "cursor on second wide rune"
  check attrReverse in b.cellAt(2, 0).style.attrs, "wide cursor reversed"
  check b.cellAt(3, 0).wideTail, "wide cursor tail"
  check attrReverse in b.cellAt(3, 0).style.attrs, "tail reversed"

proc testDrawCentered =
  var b = initBuffer(10, 3)
  var f = initFrame(b, initRect(0, 0, 10, 3))
  var st = initEditorState()
  st.content = "ab"
  st.cursor = 1
  f.editor(st)
  check b.cellAt(1, 1).rune == Rune(ord('b')), "row centered in tall rect"
  check attrReverse in b.cellAt(1, 1).style.attrs, "centered cursor reversed"
  check b.cellAt(0, 0).rune == Rune(0x0020), "top row untouched"
  check b.cellAt(0, 2).rune == Rune(0x0020), "bottom row untouched"

proc main =
  testInsert()
  testBackspaceDelete()
  testMovement()
  testCtrlKUW()
  testIgnoredAndSubmit()
  testHistory()
  testWide()
  testDrawCursor()
  testDrawPlaceholder()
  testDrawScroll()
  testDrawWide()
  testDrawCentered()
  echo "editor ok"

main()
