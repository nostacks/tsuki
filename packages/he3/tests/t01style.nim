import common
import he3/style
import he3/private/ansi

proc testConstructors =
  let channels = rgb(1, 2, 3).rgb
  check rgb(1, 2, 3).kind == ckRgb and channels[0] == 1 and channels[1] == 2 and
    channels[2] == 3, "rgb ctor"
  check indexed(42).kind == ckIndexed and indexed(42).index == 42,
    "indexed ctor"
  check named(ncRed).kind == ckNamed and named(ncRed).name == ncRed,
    "named ctor"
  check sizeof(Color) == 4 and sizeof(Style) <= 12, "styles stay compact"
  check styleDefault().fg.kind == ckDefault, "default fg"
  check styleDefault().bg.kind == ckDefault, "default bg"
  check styleDefault().attrs == {}, "default attrs"
  check fg(named(ncRed)) == Style(fg: named(ncRed)), "fg ctor"
  check bg(rgb(0, 0, 255)) == Style(bg: rgb(0, 0, 255)), "bg ctor"
  let s = styleDefault().withFg(named(ncGreen)).withBg(named(ncBlue))
    .withAttrs({attrBold, attrItalic})
  check s.attrs == {attrBold, attrItalic}, "withAttrs"
  check s.withoutAttrs({attrBold}).attrs == {attrItalic}, "withoutAttrs"

proc testAnsi =
  check ansiFg(named(ncRed)) == "\x1b[31m", "named fg red"
  check ansiFg(named(ncBrightRed)) == "\x1b[91m", "bright fg red"
  check ansiBg(named(ncRed)) == "\x1b[41m", "named bg red"
  check ansiBg(named(ncBrightWhite)) == "\x1b[107m", "bright bg white"
  check ansiFg(indexed(200)) == "\x1b[38;5;200m", "indexed fg"
  check ansiBg(indexed(17)) == "\x1b[48;5;17m", "indexed bg"
  check ansiFg(rgb(255, 0, 0)) == "\x1b[38;5;196m", "rgb fg red"
  check ansiFg(Color()) == "", "default fg empty"
  check ansiBg(Color()) == "", "default bg empty"
  check ansiAttrsOn({attrBold, attrUnderline}) == "\x1b[1m\x1b[4m", "attrs on"
  check ansiAttrsOff({attrBold}) == "\x1b[22m", "attrs off bold"
  check ansiAttrsOff({attrItalic}) == "\x1b[23m", "attrs off italic"
  check ansiReset() == "\x1b[0m", "reset"
  let s = styleDefault().withFg(named(ncGreen)).withAttrs({attrBold})
  check s.styleDiffToSeq == "\x1b[0;32;1m", "diff seq"
  var frame: seq[byte]
  frame.addStyleTransition(fg(named(ncRed)), fg(named(ncGreen)))
  check cast[string](frame) == "\x1b[32m", "color change emits only the color"
  frame.setLen 0
  frame.addStyleTransition(fg(named(ncRed)), fg(named(ncRed)).bold)
  check cast[string](frame) == "\x1b[1m", "attribute add emits only the attr"
  frame.setLen 0
  frame.addStyleTransition(fg(named(ncRed)).bold, fg(named(ncRed)))
  check cast[string](frame) == "\x1b[0;31m", "attribute removal resets"
  frame.setLen 0
  frame.addStyleTransition(fg(named(ncRed)), styleDefault())
  check cast[string](frame) == "\x1b[0m", "return to default resets"
  frame.setLen 0
  frame.addStyleTransition(fg(named(ncRed)), fg(named(ncRed)))
  check frame.len == 0, "identical styles emit nothing"
  frame.setLen 0
  frame.addStyleTransition(styleDefault(), bg(rgb(1, 2, 3)).withFg(
    indexed(9)), truecolor = true)
  check cast[string](frame) == "\x1b[48;2;1;2;3;38;5;9m",
    "combined bg and fg change is one sequence"

proc testClosestIndex =
  check closestIndex(0, 0, 0) == 16, "black to cube origin"
  check closestIndex(255, 255, 255) == 231, "white to cube top"
  check closestIndex(95, 135, 175) == 67, "exact cube point"
  check closestIndex(255, 0, 0) == 196, "pure red"
  check closestIndex(0, 255, 0) == 46, "pure green"
  check closestIndex(0, 0, 255) == 21, "pure blue"
  check closestIndex(128, 128, 128) == 244, "mid gray to gray ramp"
  check closestIndex(250, 250, 250) == 231, "near white"
  check closestIndex(100, 100, 100) == 241, "gray 100"
  check closestIndex(low(int), high(int), 0) == closestIndex(0, 255, 0),
    "public palette conversion clamps hostile component values"

proc main =
  testConstructors()
  testAnsi()
  testClosestIndex()
  echo "style ok"

main()
