## Virtualized, bottom-anchored coding-agent transcript.

import std/[strutils, unicode]
import ../[event, geometry, graphemes, render, scroll, style, text]
import ../widgets/display
import diffview, markdown, model, theme, toolcall

type
  TranscriptCacheEntry = object
    version: uint64
    width: int
    height: int
    document: Text

  TranscriptState* = object
    ## Layout and interaction state. Cached offsets make visible-range lookup
    ## logarithmic and rendering proportional to the visible page.
    scroll*: ScrollState
    selected*: int
    search*: string
    matches*: seq[int]
    matchIndex*: int
    selectAnchor*: int
    selectHead*: int
    selecting*: bool
    offsets: seq[int]
    cache: seq[TranscriptCacheEntry]
    revision: uint64
    width: int

func hasSelection*(state: TranscriptState): bool =
  ## True when a nonempty row range is selected.
  state.selectAnchor >= 0 and state.selectHead >= 0 and
    state.selectAnchor != state.selectHead

func clearSelection*(state: var TranscriptState) =
  state.selectAnchor = -1
  state.selectHead = -1
  state.selecting = false

func selectionRange(state: TranscriptState): tuple[lo, hi: int] =
  (min(state.selectAnchor, state.selectHead),
    max(state.selectAnchor, state.selectHead))

func selectionText*(state: TranscriptState, chat: AgentChat): string =
  ## Content of every item intersecting the selected row range, in transcript
  ## order, for a host-controlled copy operation.
  if not state.hasSelection or state.offsets.len != chat.items.len + 1:
    return ""
  let lo = min(state.selectAnchor, state.selectHead)
  let hi = max(state.selectAnchor, state.selectHead)
  for index in 0 ..< chat.items.len:
    let start = state.offsets[index]
    let finish = state.offsets[index + 1] - 1
    if start <= hi and finish >= lo:
      if result.len > 0: result.add "\n"
      result.add chat.items[index].content

const itemGap = 1

func thinkingColors(colors: AgentTheme): AgentTheme =
  ## Muted, italic presentation for streamed reasoning.
  result = colors
  result.base.text = colors.base.muted.italic
  result.base.code = colors.base.muted.italic
  result.base.accent = colors.base.muted.italic
  result.base.success = colors.base.muted.italic

func userDocument(content: string, colors: AgentTheme): Text =
  ## User text stays plain and quiet; the violet cue carries the identity.
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

func wrappedRows(value: string, width: int): int =
  ## Counts grapheme-wrapped visual rows exactly as `richText` produces them.
  if width <= 0: return 0
  for line in value.splitLines:
    var used = 0
    var rows = 1
    for cluster in line.graphemes:
      let clusterWidth = cluster.clusterWidth
      if used > 0 and used + clusterWidth > width:
        inc rows
        used = 0
      if clusterWidth <= width:
        inc used, clusterWidth
    result += rows

func trimNewlines(value: string): string =
  result = value
  while result.endsWith("\n"):
    result.setLen(result.len - 1)

func visualRows(value: string, width: int): seq[string] =
  ## Cell-width-wrapped visual rows for multi-line content. Row counts match
  ## `wrappedRows` exactly, so cached heights stay correct.
  for line in value.splitLines:
    var used = 0
    var current = ""
    for cluster in line.graphemes:
      let clusterWidth = cluster.clusterWidth
      if used > 0 and used + clusterWidth > width:
        result.add current
        current = ""
        used = 0
      if clusterWidth <= width:
        current.add cluster
        inc used, clusterWidth
    result.add current

func outputRows(item: TranscriptItem, width: int): int =
  ## Visual rows of one expanded tool body at the given frame width.
  let bodyWidth = max(1, width - 4)
  let body = item.content.trimNewlines
  if item.looksLikeDiff:
    for line in body.splitLines: inc result
  else:
    result = body.wrappedRows(bodyWidth)

proc itemHeight(item: TranscriptItem, width, documentHeight: int): int =
  ## Total frame rows for one item, including the trailing breathing gap.
  ## `documentHeight` is the measured rendered body height at the same width.
  let inner = max(1, width - 2)
  case item.kind
  of transcriptMessage:
    if item.role == roleUser:
      max(1, item.content.wrappedRows(inner)) + itemGap
    else:
      max(1, documentHeight) + itemGap
  of transcriptThinking:
    max(1, documentHeight) + itemGap
  of transcriptTool:
    if item.expanded and item.content.len > 0:
      1 + item.outputRows(width) + itemGap
    else:
      1 + itemGap
  of transcriptNotice, transcriptError, transcriptApproval:
    max(1, item.content.wrappedRows(width)) + itemGap

func lineHeight(line: Line, width: int): int =
  if width <= 0: return 0
  result = 1
  var used = 0
  for span in line.spans:
    for cluster in span.text.graphemes:
      let clusterWidth = cluster.clusterWidth
      if used > 0 and used + clusterWidth > width:
        inc result
        used = 0
      if clusterWidth <= width:
        inc used, clusterWidth

func documentHeight(document: Text, width: int): int =
  for line in document.lines:
    result += line.lineHeight(width)

proc syncLayout*(state: var TranscriptState, chat: AgentChat,
    width, viewportHeight: int, colors = agentTheme()) =
  ## Updates only the changed suffix. Appending or streaming into the newest
  ## item is O(changed visible content), while unchanged frames are O(1).
  let safeWidth = max(1, width)
  var firstChanged = chat.items.len
  let journalAvailable = chat.changesSince(state.revision, firstChanged)
  if state.width != safeWidth or state.offsets.len != chat.items.len + 1 or
      not journalAvailable:
    firstChanged = 0
  if state.revision == chat.transcriptRevision and state.width == safeWidth and
      state.offsets.len == chat.items.len + 1:
    state.scroll.update(width, viewportHeight, width,
      if state.offsets.len > 0: state.offsets[^1] else: 0)
    return
  state.cache.setLen(chat.items.len)
  state.offsets.setLen(chat.items.len + 1)
  if firstChanged <= 0:
    state.offsets[0] = 0
  else:
    firstChanged = min(firstChanged, chat.items.len)
  for index in firstChanged ..< chat.items.len:
    let item = chat.items[index]
    if state.cache[index].version != item.version or
        state.cache[index].width != safeWidth:
      var displayContent = item.content
      for citation in item.citations:
        displayContent.add "\n[" & citation.label & "](" & citation.uri & ")"
      for attachment in item.attachments:
        displayContent.add "\nAttachment: " & attachment.name & " (" &
          attachment.mediaType & ", " & $attachment.sizeBytes & " bytes)"
      if item.partial: displayContent.add "\n… interrupted"
      case item.kind
      of transcriptMessage:
        state.cache[index].document = if item.role == roleUser:
          userDocument(displayContent, colors)
        else:
          parseMarkdown(displayContent, colors)
      of transcriptThinking:
        state.cache[index].document = parseMarkdown(displayContent,
          thinkingColors(colors))
      else:
        state.cache[index].document = Text()
      state.cache[index].version = item.version
      state.cache[index].width = safeWidth
      let inner = max(1, safeWidth - 2)
      let measured = case item.kind
        of transcriptMessage, transcriptThinking:
          documentHeight(state.cache[index].document,
            if item.kind == transcriptMessage and item.role == roleUser: inner
            elif item.kind == transcriptMessage: safeWidth
            else: inner)
        else: 0
      state.cache[index].height = item.itemHeight(safeWidth, measured)
    state.offsets[index + 1] = state.offsets[index] +
      state.cache[index].height
  state.revision = chat.transcriptRevision
  state.width = safeWidth
  state.selected = clamp(state.selected, 0, max(0, chat.items.len - 1))
  state.scroll.update(width, viewportHeight, width,
    if state.offsets.len > 0: state.offsets[^1] else: 0)

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
  ## Handles scrolling, selection, expansion, search navigation, and end jump.
  if event.kind == evMouse:
    case event.mouse.action
    of maScroll:
      state.scroll.scrollBy(0, if event.mouse.button == 0: -3 else: 3)
      return true
    of maPress, maDrag, maRelease:
      if event.mouse.button != 0 or
          event.mouse.y >= state.scroll.viewportHeight:
        return false
      let contentRows = if state.offsets.len > 0: state.offsets[^1] else: 0
      let row = clamp(state.scroll.offsetY + event.mouse.y, 0,
        max(0, contentRows - 1))
      case event.mouse.action
      of maPress:
        state.selectAnchor = row
        state.selectHead = row
        state.selecting = true
        return true
      of maDrag:
        if not state.selecting: return false
        state.selectHead = row
        return true
      of maRelease:
        state.selecting = false
        return true
      else:
        return false
    else:
      return false
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

proc drawMessage(frame: Frame, item: TranscriptItem, document: Text,
    colors: AgentTheme) =
  ## Draws one message body with an optional leading identity cue. The cue
  ## column is the stable inner edge; user and thinking bodies align after it.
  let indented = item.role == roleUser or item.kind == transcriptThinking
  let cue = if item.role == roleUser: "›"
    elif item.kind == transcriptThinking: "✻"
    else: ""
  let cueStyle = if item.role == roleUser: colors.userLabel
    else: colors.thinkingLabel
  if cue.len > 0:
    frame.write(0, 0, cue, cueStyle)
  let bodyX = if indented: 2 else: 0
  let body = frame.sub(rect(bodyX, 0, max(1, frame.rect.width - bodyX),
    frame.rect.height))
  body.richText(document)

proc drawToolOutput(frame: Frame, item: TranscriptItem, colors: AgentTheme) =
  ## Draws one expanded tool body through the shared diff/code presentation.
  let rail = not item.looksLikeDiff
  let bodyX = if rail: 2 else: 0
  if rail and frame.rect.width > 0:
    frame.fill(rect(0, 0, 1, frame.rect.height), Rune(0x2502),
      colors.base.border)
  let body = frame.sub(rect(bodyX, 0, max(1, frame.rect.width - bodyX),
    frame.rect.height))
  if item.looksLikeDiff:
    let rows = item.content.trimNewlines.diffRows(colors)
    for index, row in rows:
      if index >= body.rect.height: break
      let child = body.sub(rect(0, index, body.rect.width, 1))
      child.richText(Text(lines: @[row]), wrap = false)
  else:
    let lines = item.content.trimNewlines.splitLines
    let codeStyle = if item.language.len > 0: colors.base.code
      else: colors.base.muted
    var row = 0
    var pendingRows: seq[string] = @[]
    for line in lines:
      pendingRows.setLen 0
      var used = 0
      var current = ""
      for cluster in line.graphemes:
        let clusterWidth = cluster.clusterWidth
        if used > 0 and used + clusterWidth > body.rect.width:
          pendingRows.add current
          current = ""
          used = 0
        if clusterWidth <= body.rect.width:
          current.add cluster
          inc used, clusterWidth
      pendingRows.add current
      for wrapped in pendingRows:
        if row >= body.rect.height: return
        body.write(0, row, wrapped, codeStyle)
        inc row

proc transcript*(frame: Frame, chat: AgentChat,
    state: var TranscriptState, colors = agentTheme()) =
  ## Draws only items intersecting the viewport, with one-item overscan.
  if frame.rect.isEmpty: return
  state.syncLayout(chat, frame.rect.width, frame.rect.height, colors)
  if chat.items.len == 0:
    frame.write(0, 0, "No messages yet", colors.base.muted)
    return
  var first = state.itemAtOffset(state.scroll.offsetY)
  first = max(0, first - 1)
  let viewportEnd = state.scroll.offsetY + frame.rect.height
  var index = first
  while index < chat.items.len and state.offsets[index] < viewportEnd +
      state.cache[index].height:
    let item = chat.items[index]
    let top = state.offsets[index] - state.scroll.offsetY
    let bodyRows = max(0, state.cache[index].height - itemGap)
    if top >= 0 and top < frame.rect.height:
      case item.kind
      of transcriptMessage, transcriptThinking:
        let body = frame.sub(rect(0, top, frame.rect.width,
          min(bodyRows, frame.rect.height - top)))
        body.drawMessage(item, state.cache[index].document, colors)
      of transcriptTool:
        frame.writeToolHeader(0, top, item, colors)
        if item.expanded and item.content.len > 0:
          let skip = max(0, -(top + 1))
          let drawTop = max(0, top + 1)
          let available = min(frame.rect.height - drawTop,
            bodyRows - 1 - skip)
          if available > 0:
            let output = frame.sub(rect(0, drawTop, frame.rect.width,
              available))
            output.drawToolOutput(item, colors)
      of transcriptNotice:
        # Notices keep their line structure so multi-line welcome cards and
        # subdued system rows wrap instead of truncating.
        var offset = 0
        for text in item.content.trimNewlines.visualRows(frame.rect.width):
          if top + offset >= frame.rect.height: break
          let style = if item.banner and offset == 0: colors.base.accent
            else: colors.base.muted
          frame.write(0, top + offset, text, style)
          inc offset
      of transcriptError:
        var offset = 0
        for text in item.content.trimNewlines.visualRows(frame.rect.width):
          if top + offset >= frame.rect.height: break
          frame.write(0, top + offset, text, colors.base.error)
          inc offset
      of transcriptApproval:
        var offset = 0
        for text in item.content.trimNewlines.visualRows(frame.rect.width):
          if top + offset >= frame.rect.height: break
          frame.write(0, top + offset, text, colors.base.warning)
          inc offset
    inc index
  if state.hasSelection:
    let (lo, hi) = state.selectionRange
    let top = max(0, lo - state.scroll.offsetY)
    let bottom = min(frame.rect.height - 1, hi - state.scroll.offsetY)
    if bottom >= top and top < frame.rect.height:
      frame.tint(rect(0, top, frame.rect.width, bottom - top + 1),
        colors.base.selection)
