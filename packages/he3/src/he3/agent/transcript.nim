## Virtualized, bottom-anchored coding-agent transcript.

import std/[strutils, unicode]
import ../[event, geometry, graphemes, render, scroll, style, text]
import ../widgets/display
import diffview, markdown, model, theme, toolcall

type
  TranscriptCacheEntry = object
    id: string
    version: uint64
    width: int
    height: int
    bodyRows: int
    document: Text
    markdown: MarkdownState
    streaming: bool
    fedBytes: int
    lineRows: seq[int]
    stableMeasured: int
    stableRows: int
    extra: Text
    extraRows: seq[int]

  TranscriptState* = object
    ## Layout and interaction state. Cached offsets make visible-range lookup
    ## logarithmic and rendering proportional to the visible page.
    scroll*: ScrollState
    selected*: int
    search*: string
    matches*: seq[int]
    matchIndex*: int
    offsets: seq[int]
    cache: seq[TranscriptCacheEntry]
    revision: uint64
    width: int
    topControl, bottomControl: Rect

const
  itemGap = 1
  unboundedMarkdown = high(int) div 4

func thinkingColors(colors: AgentTheme): AgentTheme =
  result = colors
  result.base.text = colors.base.muted.italic
  result.base.code = colors.base.muted.italic
  result.base.accent = colors.base.muted.italic
  result.base.success = colors.base.muted.italic

func userDocument(content: string, colors: AgentTheme): Text =
  for line in content.splitLines:
    var row = Line()
    row.spans.add Span(text: line, style: colors.base.text)
    result.lines.add row

func looksLikeDiff(item: TranscriptItem): bool =
  if item.language == "diff": return true
  if item.language.len > 0: return false
  var header = 0
  for line in item.content.splitLines:
    if line.len == 0: continue
    if line.startsWith("--- ") and header == 0: header = 1
    elif line.startsWith("+++ ") and header == 1: return true
    else: return false
  false

func trimmedEnd(value: string): int =
  result = value.len
  while result > 0 and value[result - 1] == '\n':
    dec result

func rowsFor(value: openArray[char], width: int): int =
  ## Visual rows of one logical line, wrapped exactly as `drawLine` draws.
  if width <= 0: return 0
  result = 1
  var used = 0
  for cluster in value.graphemeSpans:
    let clusterWidth = clusterWidth(value.toOpenArray(cluster.a, cluster.b))
    if used > 0 and used + clusterWidth > width:
      inc result
      used = 0
    if clusterWidth <= width:
      inc used, clusterWidth

func lineHeight(line: Line, width: int): int =
  if width <= 0: return 0
  result = 1
  var used = 0
  for span in line.spans:
    for cluster in span.text.graphemeSpans:
      let clusterWidth = clusterWidth(
        span.text.toOpenArray(cluster.a, cluster.b))
      if used > 0 and used + clusterWidth > width:
        inc result
        used = 0
      if clusterWidth <= width:
        inc used, clusterWidth

iterator contentLines(content: string): tuple[start, stop: int] =
  let finish = content.trimmedEnd
  var start = 0
  while start <= finish:
    var stop = if start < content.len: content.find('\n', start) else: -1
    if stop < 0 or stop > finish: stop = finish
    yield (start, stop)
    start = stop + 1

func hasPrefix(value, prefix: string, length: int): bool =
  if length > value.len or length > prefix.len: return false
  length == 0 or cmpMem(unsafeAddr value[0], unsafeAddr prefix[0], length) == 0

proc measureLines(entry: var TranscriptCacheEntry, lines: seq[Line],
    stable, width: int): int =
  if entry.stableMeasured > stable or entry.lineRows.len < entry.stableMeasured:
    entry.stableMeasured = 0
    entry.stableRows = 0
  entry.lineRows.setLen(lines.len)
  while entry.stableMeasured < stable:
    let rows = lines[entry.stableMeasured].lineHeight(width)
    entry.lineRows[entry.stableMeasured] = rows
    inc entry.stableRows, rows
    inc entry.stableMeasured
  result = entry.stableRows
  for index in stable ..< lines.len:
    let rows = lines[index].lineHeight(width)
    entry.lineRows[index] = rows
    inc result, rows

proc extraText(item: TranscriptItem): string =
  for citation in item.citations:
    result.add "[" & citation.label & "](" & citation.uri & ")\n"
  for attachment in item.attachments:
    result.add "Attachment: " & attachment.name & " (" &
      attachment.mediaType & ", " & $attachment.sizeBytes & " bytes)\n"
  if item.partial: result.add "… interrupted\n"
  if result.len > 0: result.setLen(result.len - 1)

proc rebuildMessage(entry: var TranscriptCacheEntry, item: TranscriptItem,
    width: int, colors: AgentTheme) =
  let user = item.role == roleUser and item.kind == transcriptMessage
  let bodyWidth = if item.kind == transcriptMessage and not user: width
    else: max(1, width - 2)
  let theme = if item.kind == transcriptThinking: thinkingColors(colors)
    else: colors
  let sameLayout = entry.id == item.id and entry.width == width
  var bodyRows = 0
  if user:
    entry.streaming = false
    entry.document = userDocument(item.content, theme)
    entry.stableMeasured = 0
    entry.stableRows = 0
    bodyRows = entry.measureLines(entry.document.lines, 0, bodyWidth)
  else:
    let appended = entry.streaming and sameLayout and
      item.content.len >= entry.fedBytes and
      item.content.hasPrefix(entry.markdown.source, entry.fedBytes)
    if appended:
      if item.content.len > entry.fedBytes:
        entry.markdown.feed(item.content[entry.fedBytes ..< item.content.len],
          theme)
    else:
      entry.markdown = initMarkdownState(maxBytes = unboundedMarkdown)
      entry.markdown.feed(item.content, theme)
      entry.stableMeasured = 0
      entry.stableRows = 0
    entry.fedBytes = item.content.len
    entry.streaming = true
    if not sameLayout:
      entry.stableMeasured = 0
      entry.stableRows = 0
    bodyRows = entry.measureLines(entry.markdown.document.lines,
      entry.markdown.stableLines, bodyWidth)
  let extras = item.extraText
  entry.extra = if extras.len > 0: parseMarkdown(extras, theme) else: Text()
  entry.extraRows.setLen(entry.extra.lines.len)
  for index, line in entry.extra.lines:
    entry.extraRows[index] = line.lineHeight(bodyWidth)
    inc bodyRows, entry.extraRows[index]
  entry.bodyRows = max(1, bodyRows)
  entry.height = entry.bodyRows + itemGap

proc rebuildTool(entry: var TranscriptCacheEntry, item: TranscriptItem,
    width: int) =
  entry.streaming = false
  entry.lineRows.setLen 0
  var bodyRows = 0
  if item.expanded and item.content.len > 0:
    let diff = item.looksLikeDiff
    let bodyWidth = if diff: width else: max(1, width - 2)
    for span in item.content.contentLines:
      let rows = if diff: 1
        else: rowsFor(item.content.toOpenArray(span.start, span.stop - 1),
          bodyWidth)
      entry.lineRows.add rows
      inc bodyRows, rows
  entry.bodyRows = 1 + bodyRows
  entry.height = entry.bodyRows + itemGap

proc rebuildPlain(entry: var TranscriptCacheEntry, item: TranscriptItem,
    width: int) =
  entry.streaming = false
  entry.lineRows.setLen 0
  var bodyRows = 0
  for span in item.content.contentLines:
    let rows = rowsFor(item.content.toOpenArray(span.start, span.stop - 1),
      width)
    entry.lineRows.add rows
    inc bodyRows, rows
  entry.bodyRows = max(1, bodyRows)
  entry.height = entry.bodyRows + itemGap

proc updateViewport(state: var TranscriptState, width, height: int,
    scrollControls: bool) =
  let contentHeight = if state.offsets.len > 0: state.offsets[^1] else: 0
  # Reserve both edges while overflowing so crossing either end never
  # changes the page size or hides a content row beneath a button.
  let controls = scrollControls and height >= 3 and contentHeight > height
  state.scroll.update(width, height - (if controls: 2 else: 0),
    width, contentHeight)

proc syncLayout*(state: var TranscriptState, chat: AgentChat,
    width, viewportHeight: int, colors = agentTheme(),
    scrollControls = false) =
  ## Updates only the changed suffix: streaming into the newest item costs
  ## the appended text plus its unstable tail lines, and unchanged frames are
  ## O(1). Entries are matched by item identity as well as version.
  let safeWidth = max(1, width)
  var firstChanged = chat.items.len
  let journalAvailable = chat.changesSince(state.revision, firstChanged)
  if state.width != safeWidth or state.offsets.len != chat.items.len + 1 or
      not journalAvailable:
    firstChanged = 0
  if not journalAvailable:
    state.cache.setLen 0
  if state.revision == chat.transcriptRevision and state.width == safeWidth and
      state.offsets.len == chat.items.len + 1:
    state.updateViewport(width, viewportHeight, scrollControls)
    return
  state.cache.setLen(chat.items.len)
  state.offsets.setLen(chat.items.len + 1)
  if firstChanged <= 0:
    state.offsets[0] = 0
  else:
    firstChanged = min(firstChanged, chat.items.len)
  for index in firstChanged ..< chat.items.len:
    let item = chat.items[index]
    if state.cache[index].id != item.id or
        state.cache[index].version != item.version or
        state.cache[index].width != safeWidth:
      case item.kind
      of transcriptMessage, transcriptThinking:
        state.cache[index].rebuildMessage(item, safeWidth, colors)
      of transcriptTool:
        state.cache[index].rebuildTool(item, safeWidth)
      of transcriptNotice, transcriptError, transcriptApproval:
        state.cache[index].rebuildPlain(item, safeWidth)
      state.cache[index].id = item.id
      state.cache[index].version = item.version
      state.cache[index].width = safeWidth
    state.offsets[index + 1] = state.offsets[index] +
      state.cache[index].height
  state.revision = chat.transcriptRevision
  state.width = safeWidth
  state.selected = clamp(state.selected, 0, max(0, chat.items.len - 1))
  state.updateViewport(width, viewportHeight, scrollControls)

func itemAtOffset(state: TranscriptState, offset: int): int =
  if state.offsets.len <= 1: return 0
  var low = 0
  var high = state.offsets.len - 1
  while low + 1 < high:
    let middle = (low + high) div 2
    if state.offsets[middle] <= offset: low = middle
    else: high = middle
  clamp(low, 0, state.offsets.len - 2)

proc transcriptEvent*(state: var TranscriptState, chat: AgentChat,
    event: Event): bool =
  ## Handles scrolling, expansion, search navigation, and end jump.
  if event.kind == evMouse:
    if event.mouse.action == maPress and event.mouse.button == 0:
      if state.topControl.contains(event.mouse.x, event.mouse.y) and
          state.scroll.offsetY > 0:
        state.scroll.offsetY = 0
        state.scroll.anchor = anchorStart
        return true
      if state.bottomControl.contains(event.mouse.x, event.mouse.y) and
          not state.scroll.atEnd:
        state.scroll.offsetY = state.scroll.maxOffsetY
        state.scroll.anchor = anchorEnd
        return true
    if event.mouse.action != maScroll: return false
    state.scroll.scrollBy(0, if event.mouse.button == 0: -3 else: 3)
    return true
  if event.kind != evKey or event.key.released: return false
  case event.key.code
  of kcUp:
    state.scroll.scrollBy(0, -1)
  of kcDown:
    state.scroll.scrollBy(0, 1)
  of kcPageUp:
    state.scroll.scrollBy(0, -max(1, state.scroll.viewportHeight - 1))
  of kcPageDown:
    state.scroll.scrollBy(0, max(1, state.scroll.viewportHeight - 1))
  of kcHome:
    state.scroll.offsetY = 0
    state.scroll.anchor = anchorStart
  of kcEnd:
    state.scroll.offsetY = state.scroll.maxOffsetY
    state.scroll.anchor = anchorEnd
  of kcEnter:
    if chat.items.len == 0: return false
    state.selected = state.itemAtOffset(state.scroll.offsetY)
    if chat.items[state.selected].kind == transcriptTool:
      discard chat.toggleExpanded(state.selected)
    else:
      return false
  else:
    return false
  true

proc setSearch*(state: var TranscriptState, chat: AgentChat, query: string) =
  ## Updates case-insensitive transcript search without executing link/content.
  state.search = sanitizeText(query)
  state.matches.setLen(0)
  state.matchIndex = 0
  if state.search.len == 0: return
  let needle = state.search.toLowerAscii
  for index, item in chat.items:
    if (needle in item.content.toLowerAscii) or
        (needle in item.title.toLowerAscii) or
        (needle in item.detail.toLowerAscii):
      state.matches.add index

proc jumpToMatch*(state: var TranscriptState, forward = true): bool =
  ## Moves to the next/previous cached match and reveals it.
  if state.matches.len == 0 or state.offsets.len <= 1: return false
  if forward:
    state.matchIndex = (state.matchIndex + 1) mod state.matches.len
  else:
    state.matchIndex = (state.matchIndex - 1 + state.matches.len) mod
      state.matches.len
  state.selected = state.matches[state.matchIndex]
  state.scroll.ensureVisible(state.offsets[state.selected],
    state.cache[state.selected].height)
  true

func selectedText*(state: TranscriptState, chat: AgentChat): string =
  ## Returns sanitized selected content for a host-controlled copy operation.
  if state.selected >= 0 and state.selected < chat.items.len:
    chat.items[state.selected].content
  else:
    ""

proc drawSegment(frame: Frame, x, y: int, value: string, a, b: int,
    style: Style) =
  if b > a and y >= 0 and y < frame.rect.height:
    frame.write(x, y, value[a ..< b], style)

proc drawLine(frame: Frame, line: Line, skip: var int, y: var int) =
  ## Draws one logical line wrapped to the frame width, omitting the first
  ## `skip` visual rows. Wrapping matches `lineHeight` cluster for cluster.
  let width = frame.rect.width
  var used = 0
  var row = 0
  for span in line.spans:
    var segmentStart = 0
    var segmentX = used
    for cluster in span.text.graphemeSpans:
      let clusterWidth = clusterWidth(
        span.text.toOpenArray(cluster.a, cluster.b))
      if used > 0 and used + clusterWidth > width:
        if row >= skip:
          frame.drawSegment(segmentX, y + row - skip, span.text,
            segmentStart, cluster.a, span.style)
        inc row
        used = 0
        segmentStart = cluster.a
        segmentX = 0
      if clusterWidth <= width:
        inc used, clusterWidth
      else:
        if row >= skip:
          frame.drawSegment(segmentX, y + row - skip, span.text,
            segmentStart, cluster.a, span.style)
        segmentStart = cluster.b + 1
        segmentX = used
    if row >= skip:
      frame.drawSegment(segmentX, y + row - skip, span.text, segmentStart,
        span.text.len, span.style)
  let rows = row + 1
  if skip >= rows:
    dec skip, rows
  else:
    inc y, rows - skip
    skip = 0

proc drawLines(frame: Frame, lines: seq[Line], rows: seq[int],
    skip: var int, y: var int) =
  var index = 0
  while index < lines.len and index < rows.len and skip >= rows[index]:
    dec skip, rows[index]
    inc index
  while index < lines.len and y < frame.rect.height:
    frame.drawLine(lines[index], skip, y)
    inc index

proc drawMessage(frame: Frame, item: TranscriptItem,
    entry: TranscriptCacheEntry, skipRows: int, colors: AgentTheme) =
  ## Draws one message body after an optional leading identity cue. The cue
  ## column is the stable inner edge; user and thinking bodies align after it.
  let indented = item.role == roleUser or item.kind == transcriptThinking
  let cue = if item.role == roleUser: "›"
    elif item.kind == transcriptThinking: "✻"
    else: ""
  let cueStyle = if item.role == roleUser: colors.userLabel
    else: colors.thinkingLabel
  if cue.len > 0 and skipRows == 0:
    frame.write(0, 0, cue, cueStyle)
  let bodyX = if indented: 2 else: 0
  let body = frame.sub(rect(bodyX, 0, max(1, frame.rect.width - bodyX),
    frame.rect.height))
  var skip = skipRows
  var y = 0
  if entry.streaming:
    body.drawLines(entry.markdown.document.lines, entry.lineRows, skip, y)
  else:
    body.drawLines(entry.document.lines, entry.lineRows, skip, y)
  body.drawLines(entry.extra.lines, entry.extraRows, skip, y)

proc drawToolOutput(frame: Frame, item: TranscriptItem,
    entry: TranscriptCacheEntry, skipRows: int, colors: AgentTheme) =
  let diff = item.looksLikeDiff
  let bodyX = if diff: 0 else: 2
  if not diff and frame.rect.width > 0:
    frame.fill(rect(0, 0, 1, frame.rect.height), Rune(0x2502),
      colors.base.border)
  let body = frame.sub(rect(bodyX, 0, max(1, frame.rect.width - bodyX),
    frame.rect.height))
  let codeStyle = if item.language.len > 0: colors.base.code
    else: colors.base.muted
  var skip = skipRows
  var y = 0
  var index = 0
  for span in item.content.contentLines:
    if y >= body.rect.height: break
    let rows = if index < entry.lineRows.len: entry.lineRows[index] else: 1
    inc index
    if skip >= rows:
      dec skip, rows
      continue
    let line = item.content[span.start ..< span.stop]
    if diff:
      let styled = line.diffStyle(colors)
      let text = if line.len > 0 and line[0] in {'+', '-'}:
        line[1 ..< line.len] else: line
      body.write(0, y, (styled.cue & " " & text).truncateCells(
        body.rect.width, true), styled.style)
      inc y
    else:
      body.drawLine(Line(spans: @[Span(text: line, style: codeStyle)]),
        skip, y)

proc drawPlain(frame: Frame, item: TranscriptItem,
    entry: TranscriptCacheEntry, skipRows: int, colors: AgentTheme) =
  let base = case item.kind
    of transcriptError: colors.base.error
    of transcriptApproval: colors.base.warning
    else: colors.base.muted
  var skip = skipRows
  var y = 0
  var index = 0
  for span in item.content.contentLines:
    if y >= frame.rect.height: break
    let rows = if index < entry.lineRows.len: entry.lineRows[index] else: 1
    let style = if item.banner and index == 0: colors.base.accent else: base
    inc index
    if skip >= rows:
      dec skip, rows
      continue
    frame.drawLine(Line(spans: @[Span(
      text: item.content[span.start ..< span.stop], style: style)]), skip, y)

proc drawScrollControl(frame: Frame, y: int, top: bool,
    colors: AgentTheme): Rect =
  let full = if top: " ↑ Scroll to top " else: " ↓ Scroll to bottom "
  let compact = if top: " ↑ Top " else: " ↓ Bottom "
  let label = if full.cellWidth <= frame.rect.width: full
    elif compact.cellWidth <= frame.rect.width: compact
    elif top: "↑" else: "↓"
  let width = label.cellWidth
  let x = (frame.rect.width - width) div 2
  frame.sub(rect(0, y, frame.rect.width, 1)).rule(style = colors.base.border)
  frame.write(x, y, label, colors.base.accent.bold)
  rect(frame.rect.x + x, frame.rect.y + y, width, 1)

proc transcript*(outer: Frame, chat: AgentChat,
    state: var TranscriptState, colors = agentTheme(),
    scrollControls = false) =
  ## Draws only items intersecting the viewport, including the visible rows
  ## of an item cut by the top edge. Optional scroll controls reserve edge
  ## rows on overflowing viewports at least three rows tall; mouse coordinates
  ## passed to transcriptEvent are absolute terminal cells.
  state.topControl = Rect()
  state.bottomControl = Rect()
  if outer.rect.isEmpty: return
  state.syncLayout(chat, outer.rect.width, outer.rect.height, colors,
    scrollControls)
  var frame = outer
  if state.scroll.viewportHeight < outer.rect.height:
    if state.scroll.offsetY > 0:
      state.topControl = outer.drawScrollControl(0, true, colors)
    if not state.scroll.atEnd:
      state.bottomControl = outer.drawScrollControl(
        outer.rect.height - 1, false, colors)
    frame = outer.sub(rect(0, 1, outer.rect.width,
      state.scroll.viewportHeight))
  if chat.items.len == 0:
    frame.write(0, 0, "No messages yet", colors.base.muted)
    return
  let first = state.itemAtOffset(state.scroll.offsetY)
  var index = first
  while index < chat.items.len:
    let top = state.offsets[index] - state.scroll.offsetY
    if top >= frame.rect.height: break
    let item = chat.items[index]
    let bodyRows = state.cache[index].bodyRows
    let skip = max(0, -top)
    let drawTop = max(0, top)
    let available = min(frame.rect.height - drawTop, bodyRows - skip)
    inc index
    if available <= 0: continue
    case item.kind
    of transcriptMessage, transcriptThinking:
      frame.sub(rect(0, drawTop, frame.rect.width, available)).drawMessage(
        item, state.cache[index - 1], skip, colors)
    of transcriptTool:
      if skip == 0:
        frame.writeToolHeader(0, drawTop, item, colors)
      if item.expanded and item.content.len > 0:
        let bodySkip = max(0, skip - 1)
        let outputTop = if skip == 0: drawTop + 1 else: drawTop
        let outputRows = min(frame.rect.height - outputTop,
          bodyRows - 1 - bodySkip)
        if outputRows > 0:
          frame.sub(rect(0, outputTop, frame.rect.width,
            outputRows)).drawToolOutput(item, state.cache[index - 1],
              bodySkip, colors)
    of transcriptNotice, transcriptError, transcriptApproval:
      frame.sub(rect(0, drawTop, frame.rect.width, available)).drawPlain(
        item, state.cache[index - 1], skip, colors)
