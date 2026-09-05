import std/random
import common
import he3/layout

proc testSplits =
  let r = initRect(0, 0, 80, 24)
  let h = r.splitH(fixed(20), fill(), percent(50))
  check h.len == 3, "three rects"
  check h[0].width == 20, "fixed col"
  check h[0].x == 0 and h[1].x == 20, "adjacent x"
  check h[1].width == 20 and h[2].width == 40, "fill and percent"
  check h[2].x == 40, "third x"
  let v = r.splitV(fixed(2), fill(), fill(3))
  check v[0].height == 2, "fixed row"
  check v[1].height == 5 and v[2].height == 17, "1:3 fill of 22"
  check v[1].y == 2 and v[2].y == 7, "adjacent y"

proc testOverflow =
  let r = initRect(0, 0, 10, 5)
  let h = r.splitH(fixed(8), fixed(8), fill())
  check h[0].width == 8, "first fixed ok"
  check h[1].width == 2, "second clamped"
  check h[2].width == 0, "no negative"
  let v = r.splitV(fixed(3), fixed(3))
  check v[1].height == 2, "clamped row"
  let empty = r.splitH(fixed(10), fixed(5))
  check empty[0].width == 10 and empty[1].width == 0, "exact fit overflow"

proc testPercentDeterminism =
  let r = initRect(0, 0, 100, 10)
  let a = r.splitH(percent(33), percent(33), percent(34))
  check a[0].width == 33 and a[1].width == 33 and a[2].width == 34,
    "percent split"
  let r2 = initRect(0, 0, 10, 10)
  let b = r2.splitH(percent(33), percent(33), percent(34))
  check b[0].width == 3 and b[1].width == 3 and b[2].width == 4,
    "small percent deterministic"

proc testTrimBottomLine =
  let r = initRect(1, 1, 20, 10)
  let t = r.trim(1, 1, 2, 3)
  check t.x == 3 and t.y == 2 and t.width == 15 and t.height == 8, "trim"
  let over = r.trim(0, 0, 25, 0)
  check over.width == 0, "trim clamped"
  let bl = r.bottomLine(3)
  check bl.y == 8 and bl.height == 3 and bl.width == 20, "bottom line"
  check r.bottomLine(0).height == 0, "bottom line zero"
  check r.contains(1, 1) and not r.contains(21, 1), "contains"

proc testProperty =
  randomize(777)
  for i in 0 ..< 200:
    let w = rand(0 .. 40)
    let h = rand(0 .. 20)
    let r = initRect(rand(-2 .. 5), rand(-2 .. 5), w, h)
    let parts = r.splitV(fixed(rand(0 .. 8)), fill(), percent(rand(0 .. 100)))
    var total = 0
    for p in parts:
      check p.width == r.width, "width preserved"
      check p.height >= 0, "no negative heights"
      total += p.height
    check total == max(0, r.height), "heights sum to rect"

proc main =
  testSplits()
  testOverflow()
  testPercentDeterminism()
  testTrimBottomLine()
  testProperty()
  echo "layout ok"

main()
