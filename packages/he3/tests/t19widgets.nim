import std/[monotimes, random, strutils, times, unicode]
import common
import he3

proc key(code: KeyCode, value = Rune(0), mods: set[Mod] = {}): Event =
  Event(kind: evKey, key: initKey(code, value, mods))

proc testLayoutAndRouting =
  randomize(19)
  for unused in 0 ..< 500:
    let area = rect(0, 0, rand(0 .. 160), rand(0 .. 80))
    let columns = area.splitH(gap = rand(0 .. 3), constraints = [
      intrinsic(rand(0 .. 30), 2, 40), minmax(3, 60), fill(2)])
    for index, column in columns:
      check column.width >= 0 and column.height >= 0,
        "layout areas never become negative"
      if index > 0:
        check columns[index - 1].x + columns[index - 1].width <= column.x,
          "layout areas do not overlap"

  var focus: FocusState
  focus.beginFrame()
  focus.register(widgetId(1), rect(0, 0, 4, 1))
  focus.register(widgetId(2), rect(0, 2, 4, 1))
  focus.finishFrame()
  check focus.current == widgetId(1), "first eligible widget receives focus"
  check focus.move(focusDown) and focus.current == widgetId(2),
    "directional focus follows geometry"

  var hits: HitMap
  hits.beginFrame()
  hits.register(widgetId(1), rect(0, 0, 10, 10), layer = 0)
  hits.register(widgetId(2), rect(2, 2, 4, 4), parent = widgetId(1), layer = 1)
  check hits.hitTest(point(3, 3)) == widgetId(2), "later layer wins hit test"
  let route = hits.route(MouseEvent(action: maPress, x: 3, y: 3))
  check route == @[widgetId(2), widgetId(1)], "target bubbles to parent"

proc testTextareaAndWidgets =
  var textareaState = initTextareaState("A👨‍👩‍👧‍👦é")
  textareaState.cursor = 3
  check textareaState.textareaEvent(key(kcBackspace)) == taChanged,
    "textarea deletes a whole grapheme"
  check textareaState.content == "A👨‍👩‍👧‍👦", "combining cluster was atomic"
  check textareaState.textareaEvent(key(kcChar, Rune(ord('z')), {modCtrl})) ==
    taChanged, "textarea undo restores prior state"
  check textareaState.content == "A👨‍👩‍👧‍👦é", "undo restored Unicode text"
  textareaState.cursor = 0
  check textareaState.textareaEvent(key(kcBackspace)) == taIgnored,
    "backspace at the beginning is a true no-op"
  textareaState.cursor = 3
  check textareaState.textareaEvent(key(kcDelete)) == taIgnored,
    "delete at the end is a true no-op"

  var logs = initLogViewState(capacity = 3)
  for index in 0 ..< 10: logs.add("line " & $index)
  check logs.count == 3 and logs.entries.len == 3,
    "log viewer retains a bounded ring"

  var harness = initHeadlessTui(32, 6)
  var buttonState: ButtonState
  var choice = ChoiceState(checked: true)
  harness.draw proc (frame: var Frame) =
    frame.sub(rect(0, 0, 20, 1)).button("Save", buttonState, focused = true)
    frame.sub(rect(0, 2, 20, 1)).checkbox("Safe mode", choice)
    frame.sub(rect(0, 4, 32, 1)).progress(0.5, "Indexing")
  let output = harness.snapshot
  check "[ Save ]" in output and "[x] Safe mode" in output and "50%" in output,
    "interactive/status widgets retain non-color cues"

  var nonFinite = initHeadlessTui(24, 3)
  nonFinite.draw proc (frame: var Frame) =
    frame.sub(rect(0, 0, 24, 1)).progress(NaN, "Loading")
    frame.sub(rect(0, 2, 24, 1)).sparkline(
      [0.0, NaN, Inf, NegInf, 1.0], ascii = true)
  check "0%" in nonFinite.snapshot and ".???@" in nonFinite.snapshot,
    "progress and charts render non-finite host data without defects"

proc referenceTruncate(value: string, width: int, ellipsis: bool): string =
  if width <= 0: return ""
  if value.cellWidth <= width: return value
  let reserve = if ellipsis: 1 else: 0
  var used = 0
  for cluster in value.graphemes:
    let clusterWidth = cluster.clusterWidth
    if used + clusterWidth > width - reserve: break
    result.add cluster
    inc used, clusterWidth
  if ellipsis: result.add "…"

proc testTextFitting =
  let samples = ["", "abc", "你好世界", "a👨‍👩‍👧b",
    "e\u0301 accent",
    "wide 終端 mix", "x".repeat(50), "tab\tstop", "🇺🇸 flag"]
  for sample in samples:
    for width in -1 .. 14:
      for ellipsis in [true, false]:
        check sample.truncateCells(width, ellipsis) ==
          referenceTruncate(sample, width, ellipsis),
          "truncateCells matches the allocating reference for " & sample &
          " at " & $width
  check "你好".cellWidth == 4 and "".cellWidth == 0, "cellWidth measures cells"
  var harness = initHeadlessTui(10, 4)
  var used = 0
  harness.draw proc (frame: var Frame) =
    frame.sub(rect(0, 0, 10, 1)).text("hello world", align = textEnd,
      ellipsis = true)
    frame.sub(rect(0, 1, 10, 1)).text("hi", align = textCenter)
    frame.sub(rect(0, 2, 10, 1)).text("hello world", align = textEnd)
    used = frame.sub(rect(0, 3, 10, 1)).writeFit(1, 0, "abcdef", 4,
      styleDefault())
  check harness.snapshot == "hello wor…\n    hi\nhello worl\n abc…",
    "text and writeFit clip at grapheme boundaries with alignment"
  check used == 4, "writeFit reports the cells it used"

proc testRichTextRows =
  var styled = initText("")
  styled.lines.setLen 0
  var line = initLine(initSpan("hello", styleDefault().bold),
    initSpan(" world"))
  styled.add line
  styled.add initLine(initSpan("tail"))
  var narrow = initHeadlessTui(5, 2)
  narrow.draw proc (frame: var Frame) =
    frame.richText(styled, scroll = 1)
  check narrow.snapshot == " worl\nd", "scrolled rows wrap per cluster"
  var aligned = initHeadlessTui(6, 3)
  aligned.draw proc (frame: var Frame) =
    frame.richText(styled, align = textEnd)
  check aligned.snapshot == "hello\n world\n  tail",
    "end alignment positions every visible row"
  check aligned.cells[0].style == styleDefault().bold and
    aligned.cells[6 + 1].style == styleDefault(),
    "span styles survive the row split"

proc testMouseHelpers =
  let press = Event(kind: evMouse, mouse: MouseEvent(action: maPress,
    button: 0, x: 4, y: 7))
  check press.isClick and not press.isHover, "mouse press helper matches click"
  let scroll = Event(kind: evMouse, mouse: MouseEvent(action: maScroll,
    button: 1, x: 4, y: 7))
  check scroll.wheelDelta == -1, "wheel helper preserves direction"
  var tracker: MouseClickTracker
  let first = getMonoTime()
  check not tracker.isDoubleClick(press, first), "first click arms tracker"
  check tracker.isDoubleClick(press,
    first + initDuration(milliseconds = 100)), "second click is recognized"

testLayoutAndRouting()
testTextareaAndWidgets()
testTextFitting()
testRichTextRows()
testMouseHelpers()
echo "widgets ok"
