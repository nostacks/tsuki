## Safe incremental streaming Markdown-to-rich-text rendering.

import std/strutils
import ../[style, text]
import theme

type MarkdownState* = object
  ## Complete source plus an incrementally parsed stable-line prefix. Only the
  ## current incomplete line is reparsed as arbitrary chunks arrive; the
  ## document's first `stableLines` lines never change afterwards.
  source*: string
  document*: Text
  version*: uint64
  maxBytes*: int
  committedBytes: int
  committedLines: int
  inFence: bool
  language: string

proc addSpan(line: var Line, value: string, style: Style, uri = "") =
  if value.len == 0: return
  var span = Span(text: value, style: style)
  if uri.safeUri: span.hyperlink = Hyperlink(uri: uri)
  line.spans.add span

proc parseInline(value: string, base: Style, colors: AgentTheme): Line =
  var index = 0
  var plainStart = 0
  template flushPlain(until: int) =
    if until > plainStart:
      result.addSpan(value[plainStart ..< until], base)
  while index < value.len:
    if index + 1 < value.len and value[index] == '*' and
        value[index + 1] == '*':
      let finish = value.find("**", index + 2)
      if finish >= 0:
        flushPlain(index)
        result.addSpan(value[index + 2 ..< finish], base.bold)
        index = finish + 2
        plainStart = index
        continue
    if value[index] == '`':
      let finish = value.find('`', index + 1)
      if finish >= 0:
        flushPlain(index)
        result.addSpan(value[index + 1 ..< finish], colors.base.code)
        index = finish + 1
        plainStart = index
        continue
    if value[index] == '[':
      let labelEnd = value.find("](", index + 1)
      if labelEnd >= 0:
        let uriEnd = value.find(')', labelEnd + 2)
        if uriEnd >= 0:
          flushPlain(index)
          let label = value[index + 1 ..< labelEnd]
          let uri = value[labelEnd + 2 ..< uriEnd]
          result.addSpan(label, colors.base.accent.underlined, uri)
          index = uriEnd + 1
          plainStart = index
          continue
    if value[index] == '*' and (index == 0 or value[index - 1] != '*'):
      let finish = value.find('*', index + 1)
      if finish >= 0:
        flushPlain(index)
        result.addSpan(value[index + 1 ..< finish], base.italic)
        index = finish + 1
        plainStart = index
        continue
    inc index
  flushPlain(value.len)

proc parseLine(rawLine: string, inFence: var bool, language: var string,
    destination: var Text, colors: AgentTheme) =
  var line = rawLine
  if line.startsWith("```"):
    inFence = not inFence
    if inFence:
      language = line[3 ..< line.len].strip
      var header = Line()
      header.addSpan(if language.len > 0: "Code · " & language else: "Code",
        colors.base.muted)
      destination.lines.add header
    else:
      language.setLen 0
    return
  if inFence:
    destination.lines.add parseInline(line, colors.base.code, colors)
    return
  var prefix = ""
  var base = colors.base.text
  if line.startsWith("### "):
    line = line[4 ..< line.len]
    base = colors.base.accent.bold
  elif line.startsWith("## "):
    line = line[3 ..< line.len]
    base = colors.base.accent.bold
  elif line.startsWith("# "):
    line = line[2 ..< line.len]
    base = colors.base.accent.bold.underlined
  elif line.startsWith("> "):
    line = line[2 ..< line.len]
    prefix = "│ "
    base = colors.base.muted.italic
  elif line.startsWith("- [x] ") or line.startsWith("- [X] "):
    line = line[6 ..< line.len]
    prefix = "☑ "
    base = colors.base.success
  elif line.startsWith("- [ ] "):
    line = line[6 ..< line.len]
    prefix = "☐ "
  elif line.startsWith("- ") or line.startsWith("* "):
    line = line[2 ..< line.len]
    prefix = "• "
  elif line.len >= 3 and line.allCharsInSet({'-', ' ', '*'}) and
      ('-' in line or '*' in line):
    destination.lines.add Line(spans: @[Span(
      text: "────────────────",
      style: colors.base.border)])
    return
  elif '|' in line:
    let cells = line.strip(chars = {' ', '|'}).split('|')
    var tableLine = Line()
    for index, cell in cells:
      if index > 0: tableLine.addSpan(" │ ", colors.base.border)
      tableLine.addSpan(cell.strip, base)
    destination.lines.add tableLine
    return
  var parsed = parseInline(line, base, colors)
  if prefix.len > 0:
    parsed.spans.insert(Span(text: prefix, style: base), 0)
  destination.lines.add parsed

proc parseMarkdown*(source: string, colors = agentTheme()): Text =
  ## Parses headings, emphasis, code, links, lists, task lists, quotes, rules,
  ## tables, and fenced blocks. HTML and terminal controls remain plain text.
  let safe = sanitizeText(source)
  var inFence = false
  var language = ""
  var start = 0
  for index, value in safe:
    if value == '\n':
      parseLine(safe[start ..< index], inFence, language, result, colors)
      start = index + 1
  if start < safe.len or safe.len == 0 or safe.endsWith("\n"):
    parseLine(safe[start ..< safe.len], inFence, language, result, colors)
  result.version = 1

func initMarkdownState*(maxBytes = 4_194_304): MarkdownState =
  ## Creates bounded streaming Markdown state.
  MarkdownState(maxBytes: max(1024, maxBytes))

func stableLines*(state: MarkdownState): int =
  ## Count of leading document lines that later feeds never rewrite.
  state.committedLines

proc buildDocument(state: var MarkdownState, colors: AgentTheme) =
  state.document.lines.setLen(state.committedLines)
  var inFence = state.inFence
  var language = state.language
  let pending = if state.committedBytes < state.source.len:
    state.source[state.committedBytes ..< state.source.len] else: ""
  let safe = sanitizeText(pending)
  var start = 0
  for index, value in safe:
    if value == '\n':
      parseLine(safe[start ..< index], inFence, language, state.document,
        colors)
      start = index + 1
  if start < safe.len or safe.len == 0 or safe.endsWith("\n"):
    parseLine(safe[start ..< safe.len], inFence, language, state.document,
      colors)
  inc state.version
  state.document.version = state.version

proc feed*(state: var MarkdownState, chunk: openArray[char],
    colors = agentTheme()) =
  ## Accepts arbitrary byte boundaries. Completed lines are parsed exactly once
  ## in place; only the current incomplete line is rebuilt, preserving
  ## one-shot equality without copying the stable prefix.
  let room = max(0, state.maxBytes - state.source.len)
  if room > 0 and chunk.len > 0:
    state.source.addChars chunk.toOpenArray(0, min(room, chunk.len) - 1)
  if chunk.len > room and not state.source.endsWith("\n… markdown truncated"):
    state.source.add "\n… markdown truncated"
  var newline = state.source.find('\n', state.committedBytes)
  if newline >= 0:
    state.document.lines.setLen(state.committedLines)
    while newline >= 0:
      var rawLine = state.source[state.committedBytes ..< newline]
      if rawLine.endsWith("\r"): rawLine.setLen(rawLine.len - 1)
      parseLine(sanitizeText(rawLine), state.inFence, state.language,
        state.document, colors)
      state.committedBytes = newline + 1
      newline = state.source.find('\n', state.committedBytes)
    state.committedLines = state.document.lines.len
  state.buildDocument(colors)

proc finish*(state: var MarkdownState, colors = agentTheme()): Text =
  ## Finalizes and returns the current safe document.
  if state.version == 0: state.buildDocument(colors)
  state.document
