## Terminal identity hints and capability negotiation values.

import std/[os, strutils]
import graphemes
import style

type
  TerminalIdentity* = object
    term*: string
    colorTerm*: string
    program*: string
    multiplexer*: string

  TerminalCapabilities* = object
    ## Capability-gated optional behavior. False always selects a cell/text
    ## fallback and never emits the corresponding protocol.
    colorDepth*: ColorDepth
    kittyKeyboard*: bool
    sgrMouse*: bool
    focusEvents*: bool
    synchronizedOutput*: bool
    hyperlinks*: bool
    clipboard*: bool
    kittyGraphics*: bool
    sixelGraphics*: bool
    itermImages*: bool
    unicode*: bool
    widthPolicy*: WidthPolicy
    identity*: TerminalIdentity

proc envIdentity*(): TerminalIdentity =
  ## Reads non-authoritative identity hints. Runtime probes may refine them.
  result.term = getEnv("TERM")
  result.colorTerm = getEnv("COLORTERM")
  result.program = getEnv("TERM_PROGRAM")
  if getEnv("TMUX").len > 0: result.multiplexer = "tmux"
  elif getEnv("STY").len > 0: result.multiplexer = "screen"

proc detectCapabilities*(identity = envIdentity(),
    noColor = getEnv("NO_COLOR").len > 0,
    unicodeLocale = getEnv("LANG").toLowerAscii notin ["", "c", "posix"]):
    TerminalCapabilities =
  ## Produces conservative startup capabilities without blocking probes.
  ## Explicit environment-derived parameters make fake-terminal tests and
  ## embedded hosts deterministic.
  let term = identity.term.toLowerAscii
  let colorTerm = identity.colorTerm.toLowerAscii
  let program = identity.program.toLowerAscii
  result.identity = identity
  result.unicode = unicodeLocale
  if noColor or term == "dumb":
    result.colorDepth = colorNone
  elif "truecolor" in colorTerm or "24bit" in colorTerm:
    result.colorDepth = colorTrue
  elif "256color" in term:
    result.colorDepth = color256
  else:
    result.colorDepth = color16
  result.sgrMouse = term != "dumb"
  result.kittyKeyboard = "kitty" in term or "wezterm" in term or
    program == "ghostty"
  result.focusEvents = result.kittyKeyboard or "xterm" in term
  result.synchronizedOutput = "kitty" in term or "wezterm" in term or
    program in ["ghostty", "iterm.app"]
  result.hyperlinks = result.colorDepth != colorNone and
    (program in ["iterm.app", "wezterm", "ghostty"] or "kitty" in term)
  # External effects remain disabled until an application explicitly opts in.
  result.clipboard = false
  result.kittyGraphics = "kitty" in term or program == "ghostty"
  result.sixelGraphics = "sixel" in term
  result.itermImages = program == "iterm.app"
  result.widthPolicy = WidthPolicy(ambiguous: awNarrow)

func monochromeCapabilities*(): TerminalCapabilities =
  ## Returns a deterministic lowest-common-denominator profile.
  TerminalCapabilities(colorDepth: colorNone, unicode: false,
    widthPolicy: WidthPolicy(ambiguous: awNarrow))
