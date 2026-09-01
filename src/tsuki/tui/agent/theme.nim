## Semantic theme roles for coding-agent components.

import ../[style, theme]

type AgentTheme* = object
  base*: Theme
  userLabel*: Style
  thinkingLabel*: Style
  lineNumber*: Style

func onCanvas*(s: Style): Style =
  ## Keeps foreground and attributes but releases the painted background, so
  ## text sits directly on the terminal's own canvas. Painted surfaces stay
  ## reserved for diffs, selection, and focus.
  result = s
  result.bg = Color(kind: ckDefault)

func agentTheme*(base = darkTheme()): AgentTheme =
  ## Derives agent-specific roles from the core semantic theme. Violet remains
  ## the single interaction/activity accent; normal assistant and tool content
  ## uses the primary text and muted roles on the unpainted terminal canvas.
  ## Status hues are reserved for actual lifecycle state. Diff, selection, and
  ## focus roles keep their surface colors.
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
  AgentTheme(base: canvas, userLabel: canvas.accent,
    thinkingLabel: canvas.muted.italic, lineNumber: canvas.muted)
