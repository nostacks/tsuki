## LaTeX math rendered as plain Unicode for terminal cells.
##
## Terminals cannot typeset, so the renderer maps what has a Unicode form
## (Greek letters, operators, relations, super- and subscripts, vulgar
## fractions, radicals with overlines, blackboard and script alphabets,
## accents) and falls back to readable ASCII notation for everything else.
## The output is ordinary safe text: it never contains control bytes.

import std/[strutils, unicode]
import ../text

const
  maxMathBytes = 4096
  overline = "\xCC\x85"

type MathParser = object
  src: string
  pos: int
  depth: int

const symbols = [
  ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("delta", "δ"),
  ("epsilon", "ε"), ("varepsilon", "ε"), ("zeta", "ζ"), ("eta", "η"),
  ("theta", "θ"), ("vartheta", "ϑ"), ("iota", "ι"), ("kappa", "κ"),
  ("lambda", "λ"), ("mu", "μ"), ("nu", "ν"), ("xi", "ξ"), ("pi", "π"),
  ("varpi", "ϖ"), ("rho", "ρ"), ("varrho", "ϱ"), ("sigma", "σ"),
  ("varsigma", "ς"), ("tau", "τ"), ("upsilon", "υ"), ("phi", "φ"),
  ("varphi", "ϕ"), ("chi", "χ"), ("psi", "ψ"), ("omega", "ω"),
  ("Gamma", "Γ"), ("Delta", "Δ"), ("Theta", "Θ"), ("Lambda", "Λ"),
  ("Xi", "Ξ"), ("Pi", "Π"), ("Sigma", "Σ"), ("Upsilon", "Υ"), ("Phi", "Φ"),
  ("Psi", "Ψ"), ("Omega", "Ω"),
  ("sum", "∑"), ("prod", "∏"), ("coprod", "∐"), ("int", "∫"),
  ("iint", "∬"), ("iiint", "∭"), ("oint", "∮"), ("infty", "∞"),
  ("partial", "∂"), ("nabla", "∇"), ("pm", "±"), ("mp", "∓"),
  ("times", "×"), ("div", "÷"), ("cdot", "·"), ("cdots", "⋯"),
  ("ldots", "…"), ("dots", "…"), ("vdots", "⋮"), ("ddots", "⋱"),
  ("le", "≤"), ("leq", "≤"), ("ge", "≥"), ("geq", "≥"), ("ne", "≠"),
  ("neq", "≠"), ("ll", "≪"), ("gg", "≫"), ("approx", "≈"),
  ("equiv", "≡"), ("sim", "∼"), ("simeq", "≃"), ("cong", "≅"),
  ("propto", "∝"), ("to", "→"), ("rightarrow", "→"), ("leftarrow", "←"),
  ("Rightarrow", "⇒"), ("Leftarrow", "⇐"), ("leftrightarrow", "↔"),
  ("Leftrightarrow", "⇔"), ("iff", "⇔"), ("implies", "⇒"),
  ("mapsto", "↦"), ("uparrow", "↑"), ("downarrow", "↓"),
  ("longrightarrow", "⟶"), ("longleftarrow", "⟵"), ("hookrightarrow", "↪"),
  ("in", "∈"), ("notin", "∉"), ("ni", "∋"), ("subset", "⊂"),
  ("subseteq", "⊆"), ("supset", "⊃"), ("supseteq", "⊇"), ("cup", "∪"),
  ("cap", "∩"), ("setminus", "∖"), ("emptyset", "∅"), ("varnothing", "∅"),
  ("forall", "∀"), ("exists", "∃"), ("nexists", "∄"), ("neg", "¬"),
  ("lnot", "¬"), ("land", "∧"), ("wedge", "∧"), ("lor", "∨"),
  ("vee", "∨"), ("oplus", "⊕"), ("otimes", "⊗"), ("odot", "⊙"),
  ("circ", "∘"), ("bullet", "•"), ("star", "⋆"), ("ast", "∗"),
  ("perp", "⊥"), ("parallel", "∥"), ("angle", "∠"), ("triangle", "△"),
  ("square", "□"), ("diamond", "◇"), ("hbar", "ℏ"), ("ell", "ℓ"),
  ("Re", "ℜ"), ("Im", "ℑ"), ("aleph", "ℵ"), ("prime", "′"),
  ("degree", "°"), ("langle", "⟨"), ("rangle", "⟩"), ("lfloor", "⌊"),
  ("rfloor", "⌋"), ("lceil", "⌈"), ("rceil", "⌉"), ("lvert", "|"),
  ("rvert", "|"), ("lVert", "‖"), ("rVert", "‖"), ("vert", "|"),
  ("Vert", "‖"), ("mid", "|"), ("therefore", "∴"), ("because", "∵"),
  ("top", "⊤"), ("bot", "⊥"), ("vdash", "⊢"), ("models", "⊨"),
  ("dagger", "†"), ("ddagger", "‡"), ("checkmark", "✓"),
  ("quad", "  "), ("qquad", "    "), ("colon", ":"),
  ("sin", "sin"), ("cos", "cos"), ("tan", "tan"), ("cot", "cot"),
  ("sec", "sec"), ("csc", "csc"), ("arcsin", "arcsin"),
  ("arccos", "arccos"), ("arctan", "arctan"), ("sinh", "sinh"),
  ("cosh", "cosh"), ("tanh", "tanh"), ("log", "log"), ("ln", "ln"),
  ("lg", "lg"), ("exp", "exp"), ("lim", "lim"), ("limsup", "lim sup"),
  ("liminf", "lim inf"), ("max", "max"), ("min", "min"), ("sup", "sup"),
  ("inf", "inf"), ("det", "det"), ("dim", "dim"), ("ker", "ker"),
  ("gcd", "gcd"), ("deg", "deg"), ("arg", "arg"), ("Pr", "Pr"),
  ("hom", "hom"), ("mod", " mod "), ("bmod", " mod "),
  ("displaystyle", ""),
  ("textstyle", ""), ("scriptstyle", ""), ("nonumber", ""),
  ("notag", ""), ("limits", ""), ("nolimits", ""), ("left", ""),
  ("right", ""), ("big", ""), ("Big", ""), ("bigg", ""), ("Bigg", "")]

const vulgarFractions = [
  ("1", "2", "½"), ("1", "3", "⅓"), ("2", "3", "⅔"), ("1", "4", "¼"),
  ("3", "4", "¾"), ("1", "5", "⅕"), ("2", "5", "⅖"), ("3", "5", "⅗"),
  ("4", "5", "⅘"), ("1", "6", "⅙"), ("5", "6", "⅚"), ("1", "7", "⅐"),
  ("1", "8", "⅛"), ("3", "8", "⅜"), ("5", "8", "⅝"), ("7", "8", "⅞"),
  ("1", "9", "⅑"), ("1", "10", "⅒")]

const superscripts = [
  ("0", "⁰"), ("1", "¹"), ("2", "²"), ("3", "³"), ("4", "⁴"), ("5", "⁵"),
  ("6", "⁶"), ("7", "⁷"), ("8", "⁸"), ("9", "⁹"), ("+", "⁺"), ("-", "⁻"),
  ("−", "⁻"), ("=", "⁼"), ("(", "⁽"), (")", "⁾"), ("a", "ᵃ"), ("b", "ᵇ"),
  ("c", "ᶜ"), ("d", "ᵈ"), ("e", "ᵉ"), ("f", "ᶠ"), ("g", "ᵍ"), ("h", "ʰ"),
  ("i", "ⁱ"), ("j", "ʲ"), ("k", "ᵏ"), ("l", "ˡ"), ("m", "ᵐ"), ("n", "ⁿ"),
  ("o", "ᵒ"), ("p", "ᵖ"), ("r", "ʳ"), ("s", "ˢ"), ("t", "ᵗ"), ("u", "ᵘ"),
  ("v", "ᵛ"), ("w", "ʷ"), ("x", "ˣ"), ("y", "ʸ"), ("z", "ᶻ"), ("A", "ᴬ"),
  ("B", "ᴮ"), ("D", "ᴰ"), ("E", "ᴱ"), ("G", "ᴳ"), ("H", "ᴴ"), ("I", "ᴵ"),
  ("J", "ᴶ"), ("K", "ᴷ"), ("L", "ᴸ"), ("M", "ᴹ"), ("N", "ᴺ"), ("O", "ᴼ"),
  ("P", "ᴾ"), ("R", "ᴿ"), ("T", "ᵀ"), ("U", "ᵁ"), ("V", "ⱽ"), ("W", "ᵂ"),
  ("β", "ᵝ"), ("γ", "ᵞ"), ("δ", "ᵟ"), ("φ", "ᵠ"), ("χ", "ᵡ"), (
      "θ", "ᶿ"),
  ("′", "′"), (" ", "")]

const subscripts = [
  ("0", "₀"), ("1", "₁"), ("2", "₂"), ("3", "₃"), ("4", "₄"), ("5", "₅"),
  ("6", "₆"), ("7", "₇"), ("8", "₈"), ("9", "₉"), ("+", "₊"), ("-", "₋"),
  ("−", "₋"), ("=", "₌"), ("(", "₍"), (")", "₎"), ("a", "ₐ"), ("e", "ₑ"),
  ("h", "ₕ"), ("i", "ᵢ"), ("j", "ⱼ"), ("k", "ₖ"), ("l", "ₗ"), ("m", "ₘ"),
  ("n", "ₙ"), ("o", "ₒ"), ("p", "ₚ"), ("r", "ᵣ"), ("s", "ₛ"), ("t", "ₜ"),
  ("u", "ᵤ"), ("v", "ᵥ"), ("x", "ₓ"), ("β", "ᵦ"), ("γ", "ᵧ"), ("ρ", "ᵨ"),
  ("φ", "ᵩ"), ("χ", "ᵪ"), (" ", "")]

const doubleStruck = [
  ("A", "𝔸"), ("B", "𝔹"), ("C", "ℂ"), ("D", "𝔻"), ("E", "𝔼"), (
      "F", "𝔽"),
  ("G", "𝔾"), ("H", "ℍ"), ("I", "𝕀"), ("J", "𝕁"), ("K", "𝕂"), (
      "L", "𝕃"),
  ("M", "𝕄"), ("N", "ℕ"), ("O", "𝕆"), ("P", "ℙ"), ("Q", "ℚ"), ("R", "ℝ"),
  ("S", "𝕊"), ("T", "𝕋"), ("U", "𝕌"), ("V", "𝕍"), ("W", "𝕎"), (
      "X", "𝕏"),
  ("Y", "𝕐"), ("Z", "ℤ"), ("0", "𝟘"), ("1", "𝟙"), ("2", "𝟚")]

const scriptLetters = [
  ("A", "𝒜"), ("B", "ℬ"), ("C", "𝒞"), ("D", "𝒟"), ("E", "ℰ"), ("F", "ℱ"),
  ("G", "𝒢"), ("H", "ℋ"), ("I", "ℐ"), ("J", "𝒥"), ("K", "𝒦"), ("L", "ℒ"),
  ("M", "ℳ"), ("N", "𝒩"), ("O", "𝒪"), ("P", "𝒫"), ("Q", "𝒬"), (
      "R", "ℛ"),
  ("S", "𝒮"), ("T", "𝒯"), ("U", "𝒰"), ("V", "𝒱"), ("W", "𝒲"), (
      "X", "𝒳"),
  ("Y", "𝒴"), ("Z", "𝒵")]

const accents = [
  ("hat", "\xCC\x82"), ("widehat", "\xCC\x82"), ("bar", "\xCC\x84"),
  ("overline", overline), ("vec", "\xE2\x83\x97"), ("dot", "\xCC\x87"),
  ("ddot", "\xCC\x88"), ("tilde", "\xCC\x83"), ("widetilde", "\xCC\x83"),
  ("check", "\xCC\x8C"), ("breve", "\xCC\x86"), ("acute", "\xCC\x81"),
  ("grave", "\xCC\x80"), ("underline", "\xCC\xB2")]

func lookup(table: openArray[(string, string)], key: string): int =
  for index, entry in table:
    if entry[0] == key:
      return index
  -1

func mapRunes(value: string, table: openArray[(string, string)],
    mapped: var string): bool =
  ## Rewrites every rune through `table`; false when one has no form.
  for rune in value.runes:
    let index = table.lookup($rune)
    if index < 0:
      return false
    mapped.add table[index][1]
  true

func isSimple(value: string): bool =
  ## Content short enough to sit beside a fraction slash or under a radical
  ## without parentheses.
  if value.len == 0 or ' ' in value:
    return false
  var count = 0
  for rune in value.runes:
    inc count
    if count > 3 or $rune in ["+", "−", "-", "=", "/", "⁄"]:
      return false
  true

func withCombining(value, mark: string): string =
  for rune in value.runes:
    result.add $rune
    if rune != Rune(' '):
      result.add mark

proc sequence(p: var MathParser, untilBrace: bool): string
proc command(p: var MathParser): string

proc skipSpaces(p: var MathParser) =
  while p.pos < p.src.len and p.src[p.pos] in {' ', '\t'}:
    inc p.pos

proc group(p: var MathParser): string =
  ## Parses one brace group when present, otherwise one atom.
  p.skipSpaces()
  if p.pos < p.src.len and p.src[p.pos] == '{':
    inc p.pos
    inc p.depth
    result = p.sequence(untilBrace = true)
    dec p.depth
    return
  if p.pos >= p.src.len:
    return ""
  if p.src[p.pos] == '\\':
    inc p.pos
    return p.command()
  let size = max(1, runeLenAt(p.src, p.pos))
  result = p.src[p.pos ..< min(p.src.len, p.pos + size)]
  inc p.pos, size

proc optional(p: var MathParser): string =
  ## Parses a `[...]` option when present.
  p.skipSpaces()
  if p.pos < p.src.len and p.src[p.pos] == '[':
    let close = p.src.find(']', p.pos + 1)
    if close > p.pos:
      result = p.src[p.pos + 1 ..< close]
      p.pos = close + 1

proc script(p: var MathParser, table: openArray[(string, string)],
    marker: string): string =
  let content = p.group()
  if content.len == 0:
    return ""
  var mapped: string
  if content.mapRunes(table, mapped):
    return mapped
  if content.runeLen == 1:
    return marker & content
  marker & "(" & content & ")"

proc environment(p: var MathParser, name: string): string =
  ## Renders matrix-like environments row by row inside their brackets.
  var body: string
  let close = p.src.find("\\end{" & name & "}", p.pos)
  let stop = if close < 0: p.src.len else: close
  var inner = MathParser(src: p.src[p.pos ..< stop], depth: p.depth + 1)
  body = inner.sequence(untilBrace = false)
  p.pos = if close < 0: p.src.len else: close + name.len + 6
  let rows = body.split(";")
  var rendered: seq[string]
  for row in rows:
    let trimmed = row.strip()
    if trimmed.len > 0:
      rendered.add trimmed
  let joined = rendered.join("; ")
  case name
  of "pmatrix", "pmatrix*": "(" & joined & ")"
  of "bmatrix", "bmatrix*": "[" & joined & "]"
  of "Bmatrix": "{" & joined & "}"
  of "vmatrix": "|" & joined & "|"
  of "Vmatrix": "‖" & joined & "‖"
  of "cases": "{ " & joined
  else: joined

proc command(p: var MathParser): string =
  ## Parses `\name` plus its arguments; the backslash is already consumed.
  if p.pos >= p.src.len:
    return "\\"
  let ch = p.src[p.pos]
  if ch notin {'a' .. 'z', 'A' .. 'Z'}:
    inc p.pos
    case ch
    of '\\': return "; "
    of ',', ';', ':': return " "
    of '!': return ""
    of ' ': return " "
    else: return $ch
  var name: string
  while p.pos < p.src.len and p.src[p.pos] in {'a' .. 'z', 'A' .. 'Z'}:
    name.add p.src[p.pos]
    inc p.pos
  case name
  of "frac", "dfrac", "tfrac":
    let top = p.group()
    let bottom = p.group()
    for entry in vulgarFractions:
      if entry[0] == top and entry[1] == bottom:
        return entry[2]
    if top.isSimple and bottom.isSimple:
      return top & "⁄" & bottom
    return (if top.isSimple: top else: "(" & top & ")") & "/" &
      (if bottom.isSimple: bottom else: "(" & bottom & ")")
  of "binom":
    let top = p.group()
    let bottom = p.group()
    return "(" & top & " " & bottom & ")"
  of "sqrt":
    let index = p.optional()
    let content = p.group()
    let radical = case index
      of "": "√"
      of "3": "∛"
      of "4": "∜"
      else:
        var mapped: string
        if index.mapRunes(superscripts, mapped): mapped & "√"
        else: "(" & index & ")√"
    if content.isSimple or content.len == 0:
      return radical & content.withCombining(overline)
    return radical & "(" & content & ")"
  of "mathbb", "Bbb":
    let content = p.group()
    var mapped: string
    return if content.mapRunes(doubleStruck, mapped): mapped else: content
  of "mathcal", "mathscr":
    let content = p.group()
    var mapped: string
    return if content.mapRunes(scriptLetters, mapped): mapped else: content
  of "text", "textrm", "textit", "textbf", "textsf", "texttt", "mathrm",
      "mathit", "mathbf", "mathsf", "mathtt", "operatorname", "mbox",
      "boldsymbol", "bm", "textnormal":
    p.skipSpaces()
    if p.pos < p.src.len and p.src[p.pos] == '{':
      let close = p.src.find('}', p.pos + 1)
      if close > p.pos:
        result = p.src[p.pos + 1 ..< close]
        p.pos = close + 1
        return
    return p.group()
  of "color", "textcolor", "label", "tag", "hspace", "vspace", "phantom":
    discard p.group()
    return ""
  of "begin":
    let env = p.group()
    return p.environment(env)
  of "end":
    discard p.group()
    return ""
  of "left", "right":
    p.skipSpaces()
    if p.pos < p.src.len and p.src[p.pos] == '.':
      inc p.pos
      return ""
    return ""
  else:
    discard
  let accent = accents.lookup(name)
  if accent >= 0:
    return p.group().withCombining(accents[accent][1])
  let symbol = symbols.lookup(name)
  if symbol >= 0:
    return symbols[symbol][1]
  name

proc sequence(p: var MathParser, untilBrace: bool): string =
  ## Renders tokens until the closing brace of the current group or the end.
  while p.pos < p.src.len:
    let ch = p.src[p.pos]
    case ch
    of '}':
      if untilBrace:
        inc p.pos
        return
      inc p.pos
    of '{':
      inc p.pos
      if p.depth < 32:
        inc p.depth
        result.add p.sequence(untilBrace = true)
        dec p.depth
    of '\\':
      inc p.pos
      result.add p.command()
    of '^':
      inc p.pos
      result.add p.script(superscripts, "^")
    of '_':
      inc p.pos
      result.add p.script(subscripts, "_")
    of '&':
      inc p.pos
      result.add "  "
    of '\'':
      inc p.pos
      result.add "′"
    of '*':
      inc p.pos
      result.add "∗"
    of ' ', '\t', '\n', '\r':
      inc p.pos
      if result.len > 0 and result[^1] != ' ':
        result.add ' '
    else:
      let size = max(1, runeLenAt(p.src, p.pos))
      result.add p.src[p.pos ..< min(p.src.len, p.pos + size)]
      inc p.pos, size

proc renderMath*(source: string): string =
  ## Renders a LaTeX math expression as one line of safe Unicode text.
  var p = MathParser(src: sanitizeText(source,
    plainTextPolicy(maxBytes = maxMathBytes)))
  result = p.sequence(untilBrace = false).strip()
  result = sanitizeText(result, plainTextPolicy(maxBytes = maxMathBytes))
