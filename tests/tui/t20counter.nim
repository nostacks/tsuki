import std/[strutils, unicode]
import ../../examples/counter
import tsuki/tui
import common

proc testCounterExample =
  var value = 0
  check updateCounter(Event(kind: evKey, key: initKey(kcRight)), value).kind ==
      ukRedraw and value == 1,
    "right increments the counter"
  check updateCounter(Event(kind: evKey, key: initKey(kcLeft)), value).kind ==
      ukRedraw and value == 0,
    "left decrements the counter"
  value = 7
  check updateCounter(Event(kind: evKey,
      key: initKey(kcChar, Rune(ord('R')))), value).kind == ukRedraw and
      value == 0,
    "R resets the counter"

  var harness = initHeadlessTui(41, 15)
  harness.draw proc (frame: var Frame) =
    frame.drawCounter(0)
  let rows = harness.snapshot().split('\n')
  check rows[6].find("0") == 20,
    "the counter value is centered in an odd-width terminal"
  check rows[4].contains("COUNTER") and rows[8].contains("decrease") and
      rows[10].contains("reset"),
    "the counter keeps a clear title, control, and help hierarchy"
  let canvas = rgb(232, 234, 238)
  for cell in harness.cells:
    check cell.style.bg == canvas,
      "every counter cell paints the solid light-gray canvas"

testCounterExample()
echo "counter ok"
