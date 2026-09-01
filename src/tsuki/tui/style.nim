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
    case kind*: ColorKind
    of ckDefault:
      discard
    of ckNamed:
      name*: NamedColor
    of ckIndexed:
      index*: range[0..255]
    of ckRgb:
      rgb*: array[3, range[0..255]]
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
func `==`*(a, b: Color): bool =
  ## Compares two colors by kind and kind-specific payload.
  if a.kind != b.kind:
    return false
  case a.kind
  of ckDefault:
    true
  of ckNamed:
    a.name == b.name
  of ckIndexed:
    a.index == b.index
  of ckRgb:
    a.rgb == b.rgb


func styleDefault*(): Style =
  ## Returns a style with default colors and no attributes.
  Style()

func rgb*(r, g, b: range[0..255]): Color =
  ## Creates an RGB color.
  Color(kind: ckRgb, rgb: [r, g, b])

func indexed*(i: range[0..255]): Color =
  ## Creates a 256-palette indexed color.
  Color(kind: ckIndexed, index: i)

func named*(n: NamedColor): Color =
  ## Creates a named color.
  Color(kind: ckNamed, name: n)

func fg*(c: Color): Style =
  ## Creates a style setting only the foreground color.
  var s: Style
  s.fg = c
  s

func bg*(c: Color): Style =
  ## Creates a style setting only the background color.
  var s: Style
  s.bg = c
  s

func withFg*(s: Style, c: Color): Style =
  ## Returns `s` with the foreground color replaced.
  var r = s
  r.fg = c
  r

func withBg*(s: Style, c: Color): Style =
  ## Returns `s` with the background color replaced.
  var r = s
  r.bg = c
  r

func withAttrs*(s: Style, attrs: set[Attr]): Style =
  ## Returns `s` with attributes added.
  var r = s
  r.attrs = r.attrs + attrs
  r

func withoutAttrs*(s: Style, attrs: set[Attr]): Style =
  ## Returns `s` with attributes removed.
  var r = s
  r.attrs = r.attrs - attrs
  r

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
