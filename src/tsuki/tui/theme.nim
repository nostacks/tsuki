## Semantic, capability-independent interface themes.

import style

type
  ThemeKind* = enum
    themeDark
    themeLight
    themeMonochrome
    themeNoColor
    themeHighContrast

  Theme* = object
    ## Semantic roles consumed by widgets. Widgets never borrow a color from an
    ## unrelated role merely because its current value looks suitable.
    background*: Style
    text*: Style
    muted*: Style
    accent*: Style
    border*: Style
    selection*: Style
    error*: Style
    warning*: Style
    success*: Style
    code*: Style
    diffAdd*: Style
    diffRemove*: Style
    focus*: Style
    disabled*: Style

func darkTheme*(): Theme =
  ## Dark theme using a neutral ramp, one violet interactive accent, and
  ## distinct status hues.
  let base = rgb(17, 19, 24)
  let surface = rgb(31, 35, 43)
  Theme(
    background: bg(base).withFg(rgb(230, 232, 239)),
    text: fg(rgb(230, 232, 239)).withBg(base),
    muted: fg(rgb(163, 169, 184)).withBg(base),
    accent: fg(rgb(180, 142, 255)).withBg(base).bold,
    border: fg(rgb(91, 98, 116)).withBg(base),
    selection: fg(rgb(255, 255, 255)).withBg(rgb(94, 61, 153)),
    error: fg(rgb(255, 121, 120)).withBg(base).bold,
    warning: fg(rgb(247, 199, 92)).withBg(base).bold,
    success: fg(rgb(93, 211, 158)).withBg(base).bold,
    code: fg(rgb(215, 219, 230)).withBg(surface),
    diffAdd: fg(rgb(113, 224, 171)).withBg(rgb(21, 52, 41)),
    diffRemove: fg(rgb(255, 146, 143)).withBg(rgb(65, 31, 35)),
    focus: fg(rgb(255, 255, 255)).withBg(rgb(94, 61, 153)).bold,
    disabled: fg(rgb(111, 117, 132)).withBg(base))

func lightTheme*(): Theme =
  ## Light theme with independently tuned surfaces and semantic roles.
  let base = rgb(250, 250, 252)
  let surface = rgb(239, 240, 245)
  Theme(
    background: bg(base).withFg(rgb(31, 34, 42)),
    text: fg(rgb(31, 34, 42)).withBg(base),
    muted: fg(rgb(87, 93, 109)).withBg(base),
    accent: fg(rgb(91, 45, 155)).withBg(base).bold,
    border: fg(rgb(145, 150, 164)).withBg(base),
    selection: fg(rgb(255, 255, 255)).withBg(rgb(91, 45, 155)),
    error: fg(rgb(157, 36, 45)).withBg(base).bold,
    warning: fg(rgb(121, 77, 0)).withBg(base).bold,
    success: fg(rgb(13, 105, 66)).withBg(base).bold,
    code: fg(rgb(37, 41, 51)).withBg(surface),
    diffAdd: fg(rgb(10, 91, 56)).withBg(rgb(219, 245, 231)),
    diffRemove: fg(rgb(145, 28, 37)).withBg(rgb(252, 226, 228)),
    focus: fg(rgb(255, 255, 255)).withBg(rgb(91, 45, 155)).bold,
    disabled: fg(rgb(126, 131, 145)).withBg(base))

func monochromeTheme*(): Theme =
  ## Attribute-led monochrome theme. Status remains redundant in widget text.
  let normal = styleDefault()
  Theme(background: normal, text: normal, muted: normal.dimmed,
    accent: normal.bold, border: normal.dimmed,
    selection: normal.reversed, error: normal.bold,
    warning: normal.underlined, success: normal.bold,
    code: normal, diffAdd: normal.bold, diffRemove: normal.underlined,
    focus: normal.reversed.bold, disabled: normal.dimmed)

func noColorTheme*(): Theme =
  ## Theme containing no color values while retaining restrained attributes.
  monochromeTheme()

func highContrastTheme*(): Theme =
  ## High-contrast theme based on terminal named black/white plus redundant
  ## attributes, avoiding reliance on a terminal's custom RGB palette.
  let black = named(ncBlack)
  let white = named(ncBrightWhite)
  let normal = fg(white).withBg(black)
  Theme(background: bg(black).withFg(white), text: normal,
    muted: normal, accent: normal.bold.underlined,
    border: normal, selection: fg(black).withBg(white).bold,
    error: normal.bold, warning: normal.bold.underlined,
    success: normal.bold, code: normal, diffAdd: normal.bold,
    diffRemove: normal.underlined, focus: fg(black).withBg(white).bold,
    disabled: normal.dimmed)

func theme*(kind = themeDark): Theme =
  ## Selects a built-in semantic theme.
  case kind
  of themeDark: darkTheme()
  of themeLight: lightTheme()
  of themeMonochrome: monochromeTheme()
  of themeNoColor: noColorTheme()
  of themeHighContrast: highContrastTheme()

func downgrade*(value: Theme, depth: ColorDepth): Theme =
  ## Downgrades every role consistently for a terminal color capability.
  result = value
  result.background = value.background.downgrade(depth)
  result.text = value.text.downgrade(depth)
  result.muted = value.muted.downgrade(depth)
  result.accent = value.accent.downgrade(depth)
  result.border = value.border.downgrade(depth)
  result.selection = value.selection.downgrade(depth)
  result.error = value.error.downgrade(depth)
  result.warning = value.warning.downgrade(depth)
  result.success = value.success.downgrade(depth)
  result.code = value.code.downgrade(depth)
  result.diffAdd = value.diffAdd.downgrade(depth)
  result.diffRemove = value.diffRemove.downgrade(depth)
  result.focus = value.focus.downgrade(depth)
  result.disabled = value.disabled.downgrade(depth)
