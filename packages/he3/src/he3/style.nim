type
  NamedColor* = enum
    ncBlack
    ncRed
    ncGreen
    ncYellow
    ncBlue
    ncMagenta
    ncCyan
    ncWhite
    ncBrightBlack
    ncBrightRed
    ncBrightGreen
    ncBrightYellow
    ncBrightBlue
    ncBrightMagenta
    ncBrightCyan
    ncBrightWhite
  ColorKind* = enum
    ckDefault
    ckNamed
    ckIndexed
    ckRgb
  Color* = object
    ## A four-byte terminal color. The payload bytes are meaningful only for
    ## the active `kind` and are always zero otherwise, so plain object
    ## equality is exact. Use `named`, `indexed`, and `rgb` to construct
    ## values and `name`, `index`, and `rgb` to read them.
    kind*: ColorKind
    c0: uint8
    c1: uint8
    c2: uint8
  Attr* = enum
    attrBold
    attrDim
    attrItalic
    attrUnderline
    attrBlink
    attrReverse
    attrStrikethrough
  Style* = object
    fg*: Color
    bg*: Color
    attrs*: set[Attr]
  ColorDepth* = enum
    colorNone
    color16
    color256
    colorTrue

static:
  doAssert sizeof(Color) == 4, "Color must stay a packed four-byte value"

func styleDefault*(): Style {.inline.} =
  ## Returns a style with default colors and no attributes.
  Style()

func rgb*(r, g, b: range[0..255]): Color {.inline.} =
  ## Creates an RGB color.
  Color(kind: ckRgb, c0: uint8(r), c1: uint8(g), c2: uint8(b))

func indexed*(i: range[0..255]): Color {.inline.} =
  ## Creates a 256-palette indexed color.
  Color(kind: ckIndexed, c0: uint8(i))

func named*(n: NamedColor): Color {.inline.} =
  ## Creates a named color.
  Color(kind: ckNamed, c0: uint8(ord(n)))

func name*(c: Color): NamedColor {.inline.} =
  ## Returns the named palette entry; meaningful only when `kind == ckNamed`.
  NamedColor(int(c.c0) and 15)

func index*(c: Color): range[0..255] {.inline.} =
  ## Returns the palette index; meaningful only when `kind == ckIndexed`.
  range[0..255](int(c.c0))

func rgb*(c: Color): array[3, range[0..255]] {.inline.} =
  ## Returns the RGB channels; meaningful only when `kind == ckRgb`.
  [range[0..255](int(c.c0)), range[0..255](int(c.c1)),
    range[0..255](int(c.c2))]

func packed*(c: Color): uint32 {.inline.} =
  ## Returns the color as one integer for hashing and fast comparison.
  uint32(ord(c.kind)) or (uint32(c.c0) shl 8) or (uint32(c.c1) shl 16) or
    (uint32(c.c2) shl 24)

func fg*(c: Color): Style {.inline.} =
  ## Creates a style setting only the foreground color.
  Style(fg: c)

func bg*(c: Color): Style {.inline.} =
  ## Creates a style setting only the background color.
  Style(bg: c)

func withFg*(s: Style, c: Color): Style {.inline.} =
  ## Returns `s` with the foreground color replaced.
  result = s
  result.fg = c

func withBg*(s: Style, c: Color): Style {.inline.} =
  ## Returns `s` with the background color replaced.
  result = s
  result.bg = c

func withAttrs*(s: Style, attrs: set[Attr]): Style {.inline.} =
  ## Returns `s` with attributes added.
  result = s
  result.attrs = s.attrs + attrs

func withoutAttrs*(s: Style, attrs: set[Attr]): Style {.inline.} =
  ## Returns `s` with attributes removed.
  result = s
  result.attrs = s.attrs - attrs

func bold*(s: Style): Style =
  ## Returns a bold variant.
  s.withAttrs({attrBold})

func dimmed*(s: Style): Style =
  ## Returns a dimmed variant.
  s.withAttrs({attrDim})

func italic*(s: Style): Style =
  ## Returns an italic variant.
  s.withAttrs({attrItalic})

func underlined*(s: Style): Style =
  ## Returns an underlined variant.
  s.withAttrs({attrUnderline})

func reversed*(s: Style): Style =
  ## Returns a reverse-video variant.
  s.withAttrs({attrReverse})

const cubeLevels = [0, 95, 135, 175, 215, 255]

func sqDist(a, b: int): int {.inline.} =
  let d = a - b
  d * d

func closestIndex*(r, g, b: int): range[0..255] =
  ## Maps an RGB triple to the nearest xterm 256 palette index.
  let components = [clamp(r, 0, 255), clamp(g, 0, 255), clamp(b, 0, 255)]
  var cubeIdx: array[3, int]
  var cubeDist = 0
  for i, v in components.toOpenArray(0, 2):
    var best = 0
    var bestD = high(int)
    for j, lv in cubeLevels.toOpenArray(0, 5):
      let d = sqDist(v, lv)
      if d < bestD:
        bestD = d
        best = j
    cubeIdx[i] = best
    cubeDist += bestD
  var grayIdx = 0
  var grayDist = high(int)
  for i in 0 ..< 24:
    let v = 8 + i * 10
    let d = sqDist(components[0], v) + sqDist(components[1], v) +
      sqDist(components[2], v)
    if d < grayDist:
      grayDist = d
      grayIdx = i
  let cubeIndex = 16 + cubeIdx[0] * 36 + cubeIdx[1] * 6 + cubeIdx[2]
  let grayIndex = 232 + grayIdx
  if cubeDist <= grayDist:
    range[0..255](cubeIndex)
  else:
    range[0..255](grayIndex)

const ansiRgb = [
  [0, 0, 0], [205, 49, 49], [13, 188, 121], [229, 229, 16],
  [36, 114, 200], [188, 63, 188], [17, 168, 205], [229, 229, 229],
  [102, 102, 102], [241, 76, 76], [35, 209, 139], [245, 245, 67],
  [59, 142, 234], [214, 112, 214], [41, 184, 219], [255, 255, 255]]

func closestNamed(r, g, b: int): NamedColor =
  var best = high(int)
  for index, candidate in ansiRgb:
    let distance = sqDist(r, candidate[0]) + sqDist(g, candidate[1]) +
      sqDist(b, candidate[2])
    if distance < best:
      best = distance
      result = NamedColor(index)

func downgrade*(color: Color, depth: ColorDepth): Color =
  ## Maps a color to terminal capability without changing its semantic role.
  if depth == colorNone or color.kind == ckDefault:
    return Color()
  if depth == colorTrue or color.kind == ckNamed:
    return color
  case color.kind
  of ckDefault: Color()
  of ckNamed: color
  of ckIndexed:
    if depth == color256:
      color
    elif int(color.index) < 16:
      named(NamedColor(color.index))
    else:
      let index = int(color.index)
      var red, green, blue: int
      if index >= 232:
        red = 8 + (index - 232) * 10
        green = red
        blue = red
      else:
        let cube = index - 16
        red = cubeLevels[cube div 36]
        green = cubeLevels[(cube div 6) mod 6]
        blue = cubeLevels[cube mod 6]
      named(closestNamed(red, green, blue))
  of ckRgb:
    if depth == color256:
      indexed(closestIndex(color.rgb[0], color.rgb[1], color.rgb[2]))
    else:
      named(closestNamed(color.rgb[0], color.rgb[1], color.rgb[2]))

func downgrade*(style: Style, depth: ColorDepth): Style =
  ## Downgrades foreground/background while retaining non-color attributes.
  result = style
  result.fg = style.fg.downgrade(depth)
  result.bg = style.bg.downgrade(depth)
