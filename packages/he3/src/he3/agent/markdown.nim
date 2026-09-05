## Safe incremental streaming Markdown-to-rich-text rendering.
##
## Every construct is decided from one line plus the block state carried
## from the lines before it, so committed lines are parsed exactly once and
## streaming output equals one-shot parsing byte for byte.

import std/[strutils, unicode]
import ../[graphemes, style, text]
import highlight, mathtext, theme

type
  MarkdownBlock = object
    ## Block-level state that crosses line boundaries.
    inFence: bool
    fenceChar: char
    fenceLen: int
    language: string
    code: HighlightState
    inMath: bool

  MarkdownState* = object
    ## Complete source plus an incrementally parsed stable-line prefix. Only
    ## the current incomplete line is reparsed as arbitrary chunks arrive; the
    ## document's first `stableLines` lines never change afterwards.
    source*: string
    document*: Text
    version*: uint64
    maxBytes*: int
    committedBytes: int
    committedLines: int
    blocks: MarkdownBlock

const
  bullets = ["•", "◦", "▪", "▫"]
  imageCue = "▣ "
  maxInlineDepth = 8

proc addSpan(line: var Line, value: string, style: Style, uri = "") =
  if value.len == 0: return
  if line.spans.len > 0 and line.spans[^1].style == style and
      line.spans[^1].hyperlink.uri.len == 0 and uri.len == 0:
    line.spans[^1].text.add value
    return
  var span = Span(text: value, style: style)
  if uri.len > 0 and uri.safeUri: span.hyperlink = Hyperlink(uri: uri)
  line.spans.add span

func isWordChar(ch: char): bool =
  ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'} or ord(ch) >= 0x80

func findClosing(value: string, marker: string, start: int): int =
  ## Finds `marker` at or after `start` with content before it and, for
  ## emphasis markers, no whitespace directly before the close.
  var index = start
  while index < value.len:
    let found = value.find(marker, index)
    if found < 0 or found == start:
      return -1
    if value[found - 1] != ' ':
      return found
    index = found + 1
  -1

func urlEnd(value: string, start: int): int =
  ## Extent of a bare URL starting at `start`, trailing punctuation excluded.
  result = start
  while result < value.len and value[result] notin {' ', '\t', '<', '>',
      '"', '\'', '`', ')', ']'}:
    inc result
  while result > start and value[result - 1] in {'.', ',', ';', ':', '!',
      '?'}:
    dec result

func mathClose(value: string, start: int): int =
  ## Closing `$` of an inline formula opened just before `start`, or -1.
  if start >= value.len or value[start] in {' ', '\t', '$'}:
    return -1
  var index = start
  while index < value.len:
    let found = value.find('$', index)
    if found < 0:
      return -1
    if found > start and value[found - 1] notin {' ', '\\'} and
        (found + 1 >= value.len or value[found + 1] notin {'0' .. '9'}):
      return found
    index = found + 1
  -1

proc parseInlineInto(line: var Line, value: string, base: Style,
    colors: AgentTheme, depth: int)

proc emphasis(line: var Line, value: string, marker: string,
    index: var int, plainStart: var int, base, style: Style,
    colors: AgentTheme, depth: int): bool =
  ## Handles one emphasis run delimited by `marker`, recursing into it.
  let start = index + marker.len
  if start >= value.len or value[start] in {' ', '\t'}:
    return false
  let finish = value.findClosing(marker, start)
  if finish < 0:
    return false
  if marker[0] == '_' and finish + marker.len < value.len and
      value[finish + marker.len].isWordChar:
    return false
  if index > plainStart:
    line.addSpan(value[plainStart ..< index], base)
  line.parseInlineInto(value[start ..< finish], style, colors, depth + 1)
  index = finish + marker.len
  plainStart = index
  true

proc parseInlineInto(line: var Line, value: string, base: Style,
    colors: AgentTheme, depth: int) =
  var index = 0
  var plainStart = 0
  template flushPlain(until: int) =
    if until > plainStart:
      line.addSpan(value[plainStart ..< until], base)
  if depth > maxInlineDepth:
    line.addSpan(value, base)
    return
  while index < value.len:
    let ch = value[index]
    case ch
    of '\\':
      if index + 1 < value.len and value[index + 1] in {'\\', '`', '*', '_',
          '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '|', '$',
          '~', '<', '>'}:
        flushPlain(index)
        line.addSpan($value[index + 1], base)
        index += 2
        plainStart = index
        continue
      if index + 1 < value.len and value[index + 1] == '(':
        let finish = value.find("\\)", index + 2)
        if finish >= 0:
          flushPlain(index)
          line.addSpan(renderMath(value[index + 2 ..< finish]), colors.math)
          index = finish + 2
          plainStart = index
          continue
    of '`':
      var run = index
      while run < value.len and value[run] == '`': inc run
      let ticks = value[index ..< run]
      var finish = value.find(ticks, run)
      while finish >= 0 and finish + ticks.len < value.len and
          value[finish + ticks.len] == '`':
        var after = finish
        while after < value.len and value[after] == '`': inc after
        finish = value.find(ticks, after)
      if finish >= 0:
        flushPlain(index)
        var code = value[run ..< finish]
        if code.len >= 2 and code[0] == ' ' and code[^1] == ' ' and
            code.strip.len > 0:
          code = code[1 ..< code.len - 1]
        line.addSpan(code, colors.base.code)
        index = finish + ticks.len
        plainStart = index
        continue
    of '$':
      let finish = value.mathClose(index + 1)
      if finish >= 0:
        flushPlain(index)
        line.addSpan(renderMath(value[index + 1 ..< finish]), colors.math)
        index = finish + 1
        plainStart = index
        continue
    of '*', '_':
      let triple = repeat(ch, 3)
      let double = repeat(ch, 2)
      if value.continuesWith(triple, index):
        if line.emphasis(value, triple, index, plainStart, base,
            base.bold.italic, colors, depth):
          continue
      if value.continuesWith(double, index):
        if line.emphasis(value, double, index, plainStart, base, base.bold,
            colors, depth):
          continue
      if ch == '*' or index == 0 or not value[index - 1].isWordChar:
        if index + 1 < value.len and value[index + 1] != ch and
            line.emphasis(value, $ch, index, plainStart, base, base.italic,
              colors, depth):
          continue
    of '~':
      if value.continuesWith("~~", index):
        if line.emphasis(value, "~~", index, plainStart, base,
            base.withAttrs({attrStrikethrough}), colors, depth):
          continue
    of '!':
      if index + 1 < value.len and value[index + 1] == '[':
        let labelEnd = value.find("](", index + 2)
        if labelEnd >= 0:
          let uriEnd = value.find(')', labelEnd + 2)
          if uriEnd >= 0:
            flushPlain(index)
            let alt = value[index + 2 ..< labelEnd]
            line.addSpan(imageCue & (if alt.len > 0: alt else: "image"),
              colors.caption)
            index = uriEnd + 1
            plainStart = index
            continue
    of '[':
      let labelEnd = value.find("](", index + 1)
      if labelEnd >= 0:
        let uriEnd = value.find(')', labelEnd + 2)
        if uriEnd >= 0:
          flushPlain(index)
          let label = value[index + 1 ..< labelEnd]
          var uri = value[labelEnd + 2 ..< uriEnd]
          let title = uri.find(" \"")
          if title >= 0: uri = uri[0 ..< title]
          let before = line.spans.len
          line.parseInlineInto(label, colors.link, colors, depth + 1)
          if uri.safeUri:
            for position in before ..< line.spans.len:
              line.spans[position].hyperlink = Hyperlink(uri: uri)
          index = uriEnd + 1
          plainStart = index
          continue
    of '<':
      let close = value.find('>', index + 1)
      if close > index + 1:
        let inner = value[index + 1 ..< close]
        if inner.safeUri and ' ' notin inner:
          flushPlain(index)
          line.addSpan(inner, colors.link, inner)
          index = close + 1
          plainStart = index
          continue
    of 'h', 'm':
      if (index == 0 or not value[index - 1].isWordChar) and
          (value.continuesWith("https://", index) or
          value.continuesWith("http://", index) or
          value.continuesWith("mailto:", index)):
        let finish = value.urlEnd(index)
        let uri = value[index ..< finish]
        if uri.safeUri and finish > index + 8:
          flushPlain(index)
          line.addSpan(uri, colors.link, uri)
          index = finish
          plainStart = index
          continue
    else:
      discard
    inc index
  flushPlain(value.len)

proc parseInline(value: string, base: Style, colors: AgentTheme): Line =
  result.parseInlineInto(value, base, colors, 0)

func leadingSpaces(line: string): int =
  while result < line.len and line[result] == ' ':
    inc result

func trimBounds(line: string): tuple[a, b: int] =
  ## Byte range of `line` without surrounding blanks, so block checks can
  ## look at the trimmed text without copying it.
  var a = 0
  while a < line.len and line[a] in {' ', '\t', '\r'}:
    inc a
  var b = line.len
  while b > a and line[b - 1] in {' ', '\t', '\r'}:
    dec b
  (a, b)

func trimmedIs(line: string, bounds: tuple[a, b: int], value: string): bool =
  if bounds.b - bounds.a != value.len:
    return false
  for index in 0 ..< value.len:
    if line[bounds.a + index] != value[index]:
      return false
  true

func listMarker(line: string, start: int, marker: var string): int =
  ## Length of a bullet or ordered marker at `start`, zero when absent.
  ## `marker` receives the ordered label such as "3." or "" for bullets.
  marker.setLen 0
  if start >= line.len:
    return 0
  if line[start] in {'-', '*', '+'} and start + 1 < line.len and
      line[start + 1] == ' ':
    return 2
  var index = start
  while index < line.len and line[index] in {'0' .. '9'} and
      index - start < 9:
    inc index
  if index > start and index + 1 < line.len and line[index] in {'.', ')'} and
      line[index + 1] == ' ':
    marker = line[start ..< index] & "."
    return index + 2 - start
  0

func fenceRun(line: string, ch: char): int =
  var index = line.leadingSpaces
  if index > 3:
    return 0
  let start = index
  while index < line.len and line[index] == ch:
    inc index
  if index - start >= 3: index - start else: 0

type TableAlign = enum
  alignLeft
  alignCenter
  alignRight

func isTableRow(text: string, a, b: int): bool =
  ## True when `text[a ..< b]` is a table row: non-blank with a leading pipe
  ## or at least two pipes.
  var start = a
  while start < b and text[start] in {' ', '\t', '\r'}:
    inc start
  var stop = b
  while stop > start and text[stop - 1] in {' ', '\t', '\r'}:
    dec stop
  if stop <= start:
    return false
  var pipes = 0
  for index in start ..< stop:
    if text[index] == '|': inc pipes
  pipes > 0 and (text[start] == '|' or pipes >= 2)

func lineEnd(text: string, start: int): int =
  let found = text.find('\n', start)
  if found < 0: text.len else: found

func tableExtent(text: string, start, limit: int): int =
  ## Offset of the newline (or `limit`) ending the run of table rows that
  ## starts at `start`, looking no further than `limit`.
  var pos = start
  result = start
  while pos < limit:
    let stop = min(text.lineEnd(pos), limit)
    if not text.isTableRow(pos, stop):
      break
    result = stop
    if stop >= limit:
      break
    pos = stop + 1

proc splitCells(line: string): seq[string] =
  let trimmed = line.strip
  let inner = if trimmed.len > 0 and trimmed[0] == '|':
    trimmed[1 ..< trimmed.len] else: trimmed
  let body = if inner.len > 0 and inner[^1] == '|':
    inner[0 ..< inner.len - 1] else: inner
  for cell in body.split('|'):
    if result.len > 0 and result[^1].endsWith("\\"):
      result[^1].add "|" & cell
    else:
      result.add cell
  for cell in result.mitems:
    cell = cell.strip

func separatorAlign(cell: string, align: var TableAlign): bool =
  if cell.len == 0 or '-' notin cell:
    return false
  for ch in cell:
    if ch notin {'-', ':'}:
      return false
  let left = cell[0] == ':'
  let right = cell[^1] == ':'
  align = if left and right: alignCenter
    elif right: alignRight
    else: alignLeft
  true

func lineWidth(line: Line): int =
  for span in line.spans:
    result += span.text.textWidth

proc renderTable(text: string, destination: var Text, colors: AgentTheme) =
  ## Lays out one complete table: the first row is the header, a separator
  ## row sets column alignment and becomes a rule, and every column is padded
  ## to its widest rendered cell.
  var rows: seq[seq[Line]]
  var aligns: seq[TableAlign]
  var hasSeparator = false
  var pos = 0
  while true:
    let stop = text.lineEnd(pos)
    let cells = text[pos ..< stop].splitCells
    var separator = rows.len == 1 and cells.len > 0
    var rowAligns: seq[TableAlign]
    if separator:
      for cell in cells:
        var align = alignLeft
        if not cell.separatorAlign(align):
          separator = false
          break
        rowAligns.add align
    if separator:
      aligns = rowAligns
      hasSeparator = true
    else:
      var rendered: seq[Line]
      for cell in cells:
        var line = Line()
        line.parseInlineInto(cell, if rows.len == 0: colors.tableHeader
          else: colors.base.text, colors, 0)
        rendered.add line
      rows.add rendered
    if stop >= text.len:
      break
    pos = stop + 1
  var widths: seq[int]
  for row in rows:
    for index, cell in row:
      let width = cell.lineWidth
      if index >= widths.len: widths.add width
      elif width > widths[index]: widths[index] = width
  for rowIndex, row in rows:
    var line = Line()
    for index in 0 ..< widths.len:
      if index > 0: line.addSpan(" │ ", colors.base.border)
      let used = if index < row.len: row[index].lineWidth else: 0
      let pad = max(0, widths[index] - used)
      let align = if index < aligns.len: aligns[index] else: alignLeft
      let left = case align
        of alignLeft: 0
        of alignRight: pad
        of alignCenter: pad div 2
      if left > 0: line.addSpan(repeat(' ', left), colors.base.text)
      if index < row.len:
        for span in row[index].spans:
          line.addSpan(span.text, span.style, span.hyperlink.uri)
      if pad - left > 0:
        line.addSpan(repeat(' ', pad - left), colors.base.text)
    destination.lines.add line
    if rowIndex == 0 and hasSeparator:
      var rule = Line()
      for index, width in widths:
        if index > 0: rule.addSpan("─┼─", colors.base.border)
        rule.addSpan(repeat("─", max(1, width)), colors.base.border)
      destination.lines.add rule

proc parseLine(rawLine: string, blocks: var MarkdownBlock,
    destination: var Text, colors: AgentTheme) =
  var line = rawLine
  if blocks.inFence:
    let closing = line.fenceRun(blocks.fenceChar)
    if closing >= blocks.fenceLen and line.strip.len == closing:
      blocks.inFence = false
      blocks.language.setLen 0
      return
    destination.lines.add highlightLine(line, blocks.language, blocks.code,
      colors, colors.base.code)
    return
  for fenceChar in ['`', '~']:
    let opening = line.fenceRun(fenceChar)
    if opening > 0:
      blocks.inFence = true
      blocks.fenceChar = fenceChar
      blocks.fenceLen = opening
      blocks.code = HighlightState()
      let info = line.strip.strip(chars = {fenceChar}).strip
      blocks.language = if ' ' in info: info.split(' ')[0] else: info
      var header = Line()
      header.addSpan(if blocks.language.len > 0:
        "Code · " & blocks.language else: "Code", colors.base.muted)
      destination.lines.add header
      return
  let bounds = line.trimBounds
  let trimmedLen = bounds.b - bounds.a
  if line.trimmedIs(bounds, "$$") or line.trimmedIs(bounds, "\\[") or
      line.trimmedIs(bounds, "\\]"):
    blocks.inMath = not blocks.inMath
    return
  if blocks.inMath:
    var math = Line()
    math.addSpan("  " & renderMath(line), colors.math)
    destination.lines.add math
    return
  if trimmedLen > 4 and line.continuesWith("$$", bounds.a) and
      line.continuesWith("$$", bounds.b - 2):
    var math = Line()
    math.addSpan("  " & renderMath(line[bounds.a + 2 ..< bounds.b - 2]),
      colors.math)
    destination.lines.add math
    return
  if trimmedLen == 0:
    destination.lines.add Line()
    return
  if line.continuesWith("![", bounds.a) and line[bounds.b - 1] == ')' and
      line.find("](", bounds.a) > 0 and line.find(')', bounds.a) == bounds.b - 1:
    let labelEnd = line.find("](", bounds.a)
    let alt = line[bounds.a + 2 ..< labelEnd]
    var source = line[labelEnd + 2 ..< bounds.b - 1].strip
    let title = source.find(" \"")
    if title >= 0: source = source[0 ..< title]
    var image = Line(image: ImageRef(source: source, alt: alt))
    image.addSpan(imageCue & (if alt.len > 0: alt else: source),
      colors.caption)
    destination.lines.add image
    return
  var prefix = ""
  var prefixStyle = colors.base.text
  var base = colors.base.text
  var level = 0
  while level < 6 and level < line.len and line[level] == '#':
    inc level
  if level > 0 and level < line.len and line[level] == ' ':
    line = line[level + 1 ..< line.len].strip
    base = case level
      of 1: colors.base.accent.bold.underlined
      of 2, 3: colors.base.accent.bold
      else: colors.base.accent
    destination.lines.add parseInline(line, base, colors)
    return
  var quoteDepth = 0
  var cursor = 0
  while cursor < line.len and line[cursor] == '>':
    inc quoteDepth
    inc cursor
    if cursor < line.len and line[cursor] == ' ': inc cursor
  if quoteDepth > 0:
    line = line[cursor ..< line.len]
    prefix = repeat("│ ", quoteDepth)
    prefixStyle = colors.base.border
    base = colors.base.muted.italic
  let indent = line.leadingSpaces
  var marker: string
  let markerLen = line.listMarker(indent, marker)
  if markerLen > 0:
    let depth = min(bullets.high, indent div 2)
    var rest = line[indent + markerLen ..< line.len]
    var cue: string
    var cueStyle = base
    if rest.startsWith("[x] ") or rest.startsWith("[X] "):
      rest = rest[4 ..< rest.len]
      cue = "☑ "
      base = colors.base.success
      cueStyle = base
    elif rest.startsWith("[ ] "):
      rest = rest[4 ..< rest.len]
      cue = "☐ "
    elif marker.len > 0:
      cue = marker & " "
      cueStyle = colors.base.accent.withoutAttrs({attrBold})
    else:
      cue = bullets[depth] & " "
      cueStyle = colors.base.accent.withoutAttrs({attrBold})
    var parsed = parseInline(rest, base, colors)
    parsed.spans.insert(Span(text: cue, style: cueStyle), 0)
    if depth > 0:
      parsed.spans.insert(Span(text: repeat("  ", depth), style: base), 0)
    if prefix.len > 0:
      parsed.spans.insert(Span(text: prefix, style: prefixStyle), 0)
    destination.lines.add parsed
    return
  var ruleChars = 0
  var ruleOnly = trimmedLen >= 3
  for index in bounds.a ..< bounds.b:
    if line[index] notin {'-', ' ', '*', '_'}:
      ruleOnly = false
      break
    if line[index] != ' ': inc ruleChars
  if quoteDepth == 0 and ruleOnly and ruleChars >= 3:
    destination.lines.add Line(spans: @[Span(
      text: "────────────────",
      style: colors.base.border)])
    return
  var parsed = parseInline(line, base, colors)
  if prefix.len > 0:
    parsed.spans.insert(Span(text: prefix, style: prefixStyle), 0)
  destination.lines.add parsed

proc parseRegion(safe: string, blocks: var MarkdownBlock,
    destination: var Text, colors: AgentTheme) =
  ## Parses a sanitized region line by line, handing each run of table rows
  ## to the table renderer as a whole.
  var pos = 0
  while true:
    let stop = safe.lineEnd(pos)
    if not blocks.inFence and not blocks.inMath and safe.isTableRow(pos, stop):
      let finish = safe.tableExtent(pos, safe.len)
      renderTable(safe[pos ..< finish], destination, colors)
      if finish >= safe.len:
        break
      pos = finish + 1
      continue
    parseLine(safe[pos ..< stop], blocks, destination, colors)
    if stop >= safe.len:
      break
    pos = stop + 1

proc parseMarkdown*(source: string, colors = agentTheme()): Text =
  ## Parses headings, emphasis, strikethrough, code, links, autolinks,
  ## images, nested and ordered lists, task lists, quotes, rules, tables,
  ## inline and display math, and highlighted fenced blocks. HTML and
  ## terminal controls remain plain text.
  let safe = sanitizeText(source)
  var blocks: MarkdownBlock
  parseRegion(safe, blocks, result, colors)
  result.version = 1

func initMarkdownState*(maxBytes = 4_194_304): MarkdownState =
  ## Creates bounded streaming Markdown state.
  MarkdownState(maxBytes: max(1024, maxBytes))

func stableLines*(state: MarkdownState): int =
  ## Count of leading document lines that later feeds never rewrite.
  state.committedLines

proc buildDocument(state: var MarkdownState, colors: AgentTheme) =
  state.document.lines.setLen(state.committedLines)
  var blocks = state.blocks
  let pending = if state.committedBytes < state.source.len:
    state.source[state.committedBytes ..< state.source.len] else: ""
  let safe = sanitizeText(pending)
  parseRegion(safe, blocks, state.document, colors)
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
  let boundary = state.source.rfind('\n')
  if boundary >= state.committedBytes:
    state.document.lines.setLen(state.committedLines)
    var pos = state.committedBytes
    while pos <= boundary:
      let stop = state.source.find('\n', pos)
      if not state.blocks.inFence and not state.blocks.inMath and
          state.source.isTableRow(pos, stop):
        let finish = state.source.tableExtent(pos, boundary + 1)
        if finish >= boundary:
          break
        renderTable(sanitizeText(state.source[pos ..< finish]),
          state.document, colors)
        pos = finish + 1
        continue
      var rawLine = state.source[pos ..< stop]
      if rawLine.endsWith("\r"): rawLine.setLen(rawLine.len - 1)
      parseLine(sanitizeText(rawLine), state.blocks, state.document, colors)
      pos = stop + 1
    state.committedBytes = pos
    state.committedLines = state.document.lines.len
  state.buildDocument(colors)

proc finish*(state: var MarkdownState, colors = agentTheme()): Text =
  ## Finalizes and returns the current safe document.
  if state.version == 0: state.buildDocument(colors)
  state.document
