import common
import tsuki/tui/style
import tsuki/tui/private/ansi

proc testConstructors =
  check rgb(1, 2, 3) == Color(kind: ckRgb, rgb: [1, 2, 3]), "rgb ctor"
  check indexed(42) == Color(kind: ckIndexed, index: 42), "indexed ctor"
  check named(ncRed) == Color(kind: ckNamed, name: ncRed), "named ctor"
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
  check ansiFg(Color(kind: ckDefault)) == "", "default fg empty"
  check ansiBg(Color(kind: ckDefault)) == "", "default bg empty"
  check ansiAttrsOn({attrBold, attrUnderline}) == "\x1b[1m\x1b[4m", "attrs on"
  check ansiAttrsOff({attrBold}) == "\x1b[22m", "attrs off bold"
  check ansiAttrsOff({attrItalic}) == "\x1b[23m", "attrs off italic"
  check ansiReset() == "\x1b[0m", "reset"
  let s = styleDefault().withFg(named(ncGreen)).withAttrs({attrBold})
  check s.styleDiffToSeq == "\x1b[0m\x1b[32m\x1b[1m", "diff seq"

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
