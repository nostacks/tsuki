## Semantic theme roles for coding-agent components.

import ../[style, theme]

type
  SyntaxTheme* = object
    ## Token roles for highlighted source. Attribute-only themes keep every
    ## role readable without color.
    keyword*: Style
    literal*: Style
    comment*: Style
    number*: Style
    typeName*: Style
    function*: Style
    operator*: Style
    attribute*: Style

  AgentTheme* = object
    base*: Theme
    userLabel*: Style
    userMessage*: Style
      ## Painted band behind a user request so it reads apart from the
      ## unpainted assistant stream. Attribute-only themes fall back to bold.
    thinkingLabel*: Style
    lineNumber*: Style
    link*: Style
    math*: Style
    caption*: Style
    tableHeader*: Style
    syntax*: SyntaxTheme

func onCanvas*(s: Style): Style =
  ## Keeps foreground and attributes but releases the painted background, so
  ## text sits directly on the terminal's own canvas. Painted surfaces stay
  ## reserved for diffs, selection, and focus.
  result = s
  result.bg = Color()

func deriveAgentTheme(base: Theme): AgentTheme =
  var canvas = base
  canvas.background = base.background.onCanvas
  canvas.text = base.text.onCanvas
  canvas.muted = base.muted.onCanvas
  canvas.accent = base.accent.onCanvas
  canvas.border = base.border.onCanvas
  canvas.error = base.error.onCanvas
  canvas.warning = base.warning.onCanvas
  canvas.success = base.success.onCanvas
  canvas.code = base.code.onCanvas
  canvas.disabled = base.disabled.onCanvas
  let colorful = canvas.accent.fg.kind == ckRgb
  let dark = colorful and base == darkTheme()
  var syntax = SyntaxTheme(
    keyword: canvas.accent.withoutAttrs({attrBold}),
    literal: canvas.success.withoutAttrs({attrBold}),
    comment: canvas.muted.italic,
    number: canvas.warning.withoutAttrs({attrBold}),
    typeName: canvas.text.bold,
    function: canvas.text,
    operator: canvas.muted,
    attribute: canvas.accent.withoutAttrs({attrBold}).italic)
  if colorful:
    syntax.typeName = fg(if dark: rgb(97, 196, 232) else: rgb(11, 108, 143))
    syntax.function = fg(if dark: rgb(130, 170, 255) else: rgb(38, 79, 170))
  let band = base.code.bg
  let painted = band.kind != ckDefault
  let userMessage = if painted: canvas.text.withBg(band) else: canvas.text.bold
  let userLabel = if painted: canvas.accent.withBg(band) else: canvas.accent
  AgentTheme(base: canvas, userLabel: userLabel, userMessage: userMessage,
    thinkingLabel: canvas.muted.italic, lineNumber: canvas.muted,
    link: canvas.accent.withoutAttrs({attrBold}).underlined,
    math: canvas.text.italic, caption: canvas.muted,
    tableHeader: canvas.text.bold, syntax: syntax)

const defaultAgentTheme = deriveAgentTheme(darkTheme())

func agentTheme*(base = darkTheme()): AgentTheme =
  ## Derives agent-specific roles from the core semantic theme. Violet remains
  ## the single interaction/activity accent; normal assistant and tool content
  ## uses the primary text and muted roles on the unpainted terminal canvas,
  ## while user requests sit on the theme's code surface so the two sides of
  ## the conversation stay distinguishable at a glance.
  ## Status hues are reserved for actual lifecycle state. Diff, selection, and
  ## focus roles keep their surface colors. The default dark derivation is
  ## built once at compile time.
  if base == darkTheme(): defaultAgentTheme
  else: deriveAgentTheme(base)
