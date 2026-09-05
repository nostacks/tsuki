## Retained terminal cell buffer with buffer-owned complex-grapheme storage.

import std/unicode
import style
import text
import graphemes
import layout

const tailRune = Rune(0x0000)

type
  Cell* = object
    ## One terminal cell. Simple runes remain inline; a complex grapheme head
    ## references UTF-8 bytes in its owning Buffer's reusable glyph arena.
    rune*: Rune
    style*: Style
    wideTail*: bool
    displayWidth*: uint8
    glyphOffset*: uint32
    glyphLen*: uint16
    link*: uint16
      ## One-based index into the owning buffer's link table; zero means the
      ## cell carries no hyperlink.

  ImagePlacement* = object
    ## An image drawn over a block of cells. `rect` is the visible part in
    ## buffer cells; `cols` and `rows` give the whole image's cell box and
    ## `offsetX`/`offsetY` say which corner of that box `rect` starts at, so
    ## a renderer can crop an image cut by an edge.
    imageId*: uint32
    rect*: Rect
    cols*: int
    rows*: int
    offsetX*: int
    offsetY*: int

  ScrollHint* = object
    ## A renderer hint that the rows of `region` moved by `rows` since the
    ## previous frame: positive values scrolled content up. The diff may use
    ## terminal scrolling for the move; it never affects what is drawn.
    region*: Rect
    rows*: int

  Buffer* = object
    ## A rectangular cell grid and its reused complex-glyph arena.
    width*: int
    height*: int
    cells*: seq[Cell]
    glyphArena*: seq[byte]
    widthPolicy*: WidthPolicy
    scrollHint*: ScrollHint
    scrollHintConflict*: bool
    links*: seq[string]
      ## Hyperlink URIs referenced by `Cell.link`. Reset with the buffer.
    images*: seq[ImagePlacement]
      ## Image placements requested for this frame, in drawing order.

const
  maxLinksPerFrame = 1024
  maxLinkBytes = 2048

static:
  doAssert sizeof(Cell) <= 24, "Cell must stay cache-friendly"

func defaultCell*(): Cell {.inline.} =
  ## A blank, one-column cell with default style.
  Cell(rune: Rune(0x0020), displayWidth: 1)

func blankCell(style = styleDefault()): Cell {.inline.} =
  Cell(rune: Rune(0x0020), style: style, displayWidth: 1)

func cellWidth*(cell: Cell): int {.inline.} =
  ## Returns a head cell's display width; tails have width zero.
  if cell.wideTail:
    0
  elif cell.displayWidth != 0:
    int(cell.displayWidth)
  else:
    max(1, cell.rune.runeWidth)

func `==`*(a, b: Cell): bool =
  ## Compares cell metadata. Complex glyph content requires `sameCell` because
  ## arena offsets are meaningful only within the owning buffers.
  a.rune == b.rune and a.style == b.style and a.wideTail == b.wideTail and
    a.displayWidth == b.displayWidth and a.glyphOffset == b.glyphOffset and
    a.glyphLen == b.glyphLen and a.link == b.link

func initBuffer*(w, h: int, widthPolicy = WidthPolicy()): Buffer =
  ## Creates a nonnegative `w` by `h` blank buffer.
  result.width = max(0, w)
  result.height = max(0, h)
  result.widthPolicy = widthPolicy
  result.cells = newSeq[Cell](result.width * result.height)
  for cell in result.cells.mitems:
    cell = defaultCell()

func cellAt*(b: Buffer, x, y: int): Cell =
  ## Returns the cell at the coordinates, or a blank cell when out of bounds.
  if x < 0 or y < 0 or x >= b.width or y >= b.height:
    defaultCell()
  else:
    b.cells[y * b.width + x]

func glyphBytesEqual(a: Buffer, ac: Cell, b: Buffer, bc: Cell): bool =
  if ac.glyphLen != bc.glyphLen:
    return false
  if ac.glyphLen == 0:
    return true
  let n = int(ac.glyphLen)
  let ao = int(ac.glyphOffset)
  let bo = int(bc.glyphOffset)
  if ao + n > a.glyphArena.len or bo + n > b.glyphArena.len:
    return false
  for i in 0 ..< n:
    if a.glyphArena[ao + i] != b.glyphArena[bo + i]:
      return false
  true

func linkUri*(b: Buffer, link: uint16): string =
  ## Returns the URI a cell link refers to, or "" for no link.
  if link == 0 or int(link) > b.links.len: ""
  else: b.links[int(link) - 1]

func sameLink(a: Buffer, al: uint16, b: Buffer, bl: uint16): bool =
  let aValid = al != 0 and int(al) <= a.links.len
  let bValid = bl != 0 and int(bl) <= b.links.len
  if aValid != bValid:
    return false
  not aValid or a.links[int(al) - 1] == b.links[int(bl) - 1]

func sameCellUnchecked*(a: Buffer, ac: Cell, b: Buffer,
    bc: Cell): bool {.inline.} =
  ## Compares two cells that belong to `a` and `b` without index checks.
  ## Links compare by URI because each buffer owns its own link table.
  if ac.rune != bc.rune or ac.style != bc.style or
      ac.wideTail != bc.wideTail:
    return false
  if ac.displayWidth != bc.displayWidth and ac.cellWidth != bc.cellWidth:
    return false
  if (ac.link != 0 or bc.link != 0) and not sameLink(a, ac.link, b, bc.link):
    return false
  if ac.glyphLen == 0 and bc.glyphLen == 0:
    return true
  glyphBytesEqual(a, ac, b, bc)

func sameCell*(a: Buffer, ai: int, b: Buffer, bi: int): bool =
  ## Compares two cells including complex grapheme bytes across arenas.
  if ai < 0 or ai >= a.cells.len or bi < 0 or bi >= b.cells.len:
    return false
  sameCellUnchecked(a, a.cells[ai], b, b.cells[bi])

func firstDifference*(a: Buffer, b: Buffer, y: int): int =
  ## Returns the first column where row `y` differs between two equally wide
  ## buffers, or the width when the rows match. Invalid rows differ at zero.
  if a.width != b.width or y < 0 or y >= a.height or y >= b.height:
    return 0
  let base = y * a.width
  for x in 0 ..< a.width:
    if not sameCellUnchecked(a, a.cells[base + x], b, b.cells[base + x]):
      return x
  a.width

func sameRow*(a: Buffer, b: Buffer, y: int): bool =
  ## Compares one full row of two equally wide buffers, glyph bytes included.
  a.width == b.width and y >= 0 and y < a.height and y < b.height and
    a.firstDifference(b, y) == a.width

func `==`*(a, b: Buffer): bool =
  ## Compares dimensions, styles, and grapheme content, independent of arena
  ## offsets and capacities.
  if a.width != b.width or a.height != b.height or
      a.cells.len != b.cells.len:
    return false
  for i in 0 ..< a.cells.len:
    if not sameCellUnchecked(a, a.cells[i], b, b.cells[i]):
      return false
  true

proc addRuneBytes(dest: var seq[byte], value: uint32) {.inline.} =
  if value < 0x80:
    dest.add byte(value)
  elif value < 0x800:
    dest.add byte(0xC0 or (value shr 6))
    dest.add byte(0x80 or (value and 0x3F))
  elif value < 0x10000:
    dest.add byte(0xE0 or (value shr 12))
    dest.add byte(0x80 or ((value shr 6) and 0x3F))
    dest.add byte(0x80 or (value and 0x3F))
  else:
    dest.add byte(0xF0 or (value shr 18))
    dest.add byte(0x80 or ((value shr 12) and 0x3F))
    dest.add byte(0x80 or ((value shr 6) and 0x3F))
    dest.add byte(0x80 or (value and 0x3F))

proc appendGlyphBytes*(dest: var seq[byte], b: Buffer, cell: Cell) =
  ## Appends a head cell's exact UTF-8 grapheme bytes to `dest`.
  if cell.wideTail:
    return
  if cell.glyphLen == 0:
    dest.addRuneBytes uint32(cell.rune)
  else:
    let first = int(cell.glyphOffset)
    let last = first + int(cell.glyphLen)
    if last <= b.glyphArena.len:
      dest.add b.glyphArena.toOpenArray(first, last - 1)

proc glyphString*(b: Buffer, cell: Cell): string =
  ## Returns a cell head's exact grapheme as UTF-8. Intended for inspection;
  ## renderers should use `appendGlyphBytes` to avoid allocation.
  var bytes: seq[byte]
  bytes.appendGlyphBytes(b, cell)
  result = newString(bytes.len)
  for i, value in bytes:
    result[i] = char(value)

proc repairAt(b: var Buffer, x, y: int) =
  if x < 0 or y < 0 or x >= b.width or y >= b.height:
    return
  let idx = y * b.width + x
  if b.cells[idx].wideTail:
    b.cells[idx] = defaultCell()
    if x > 0:
      let head = idx - 1
      if b.cells[head].cellWidth == 2:
        b.cells[head] = defaultCell()
  elif b.cells[idx].cellWidth == 2:
    b.cells[idx] = defaultCell()
    if x + 1 < b.width and b.cells[idx + 1].wideTail:
      b.cells[idx + 1] = defaultCell()

proc setCell*(b: var Buffer, x, y: int, cell: Cell) =
  ## Writes a simple cell and repairs any wide glyph occupying the target.
  ## Framework renderers use `writeCluster` for atomic wide/complex writes.
  if x < 0 or y < 0 or x >= b.width or y >= b.height:
    return
  b.repairAt(x, y)
  var value = cell
  value.glyphLen = 0
  value.glyphOffset = 0
  if value.wideTail:
    if x == 0 or b.cells[y * b.width + x - 1].cellWidth != 2:
      value = defaultCell()
  elif value.displayWidth == 0:
    value.displayWidth = uint8(min(2, max(1, value.rune.runeWidth)))
  b.cells[y * b.width + x] = value
  if value.cellWidth == 2:
    if x + 1 < b.width:
      b.repairAt(x + 1, y)
      b.cells[y * b.width + x + 1] = Cell(rune: tailRune,
        style: value.style, wideTail: true)
    else:
      b.cells[y * b.width + x] = defaultCell()

proc storeCluster(b: var Buffer, x, y: int, cluster: openArray[char],
    width: int, style: Style) =
  b.repairAt(x, y)
  if width == 2:
    b.repairAt(x + 1, y)
  let base = cluster.runeAt(0)
  var head = Cell(rune: base, style: style, displayWidth: uint8(width))
  if cluster.len != base.size:
    var storedLen = min(cluster.len, int(high(uint16)))
    # A pathological grapheme can exceed the compact cell length field. Keep
    # the largest valid UTF-8 prefix; cutting a continuation byte would later
    # make an otherwise safe frame emit malformed terminal text.
    if storedLen < cluster.len:
      while storedLen > base.size and
          (uint8(cluster[storedLen]) and 0xC0) == 0x80:
        dec storedLen
    head.glyphOffset = uint32(b.glyphArena.len)
    head.glyphLen = uint16(storedLen)
    let first = b.glyphArena.len
    b.glyphArena.setLen first + storedLen
    for i in 0 ..< storedLen:
      b.glyphArena[first + i] = byte(cluster[i])
  b.cells[y * b.width + x] = head
  if width == 2:
    b.cells[y * b.width + x + 1] = Cell(rune: tailRune, style: style,
      wideTail: true)

proc writeAscii*(b: var Buffer, x, y: int, ch: char,
    style = styleDefault()) {.inline.} =
  ## Writes one printable ASCII cell, repairing any wide glyph it overlaps.
  ## Callers guarantee bounds and that `ch` is in the printable range.
  b.repairAt(x, y)
  b.cells[y * b.width + x] = Cell(rune: Rune(ch), style: style,
    displayWidth: 1)

proc writeAsciiRun*(b: var Buffer, x, y: int, run: openArray[char],
    style = styleDefault()) =
  ## Writes printable ASCII bytes as consecutive one-cell glyphs, clipping to
  ## the buffer and repairing wide glyphs cut at either end. Callers
  ## guarantee every byte is in the printable range.
  if y < 0 or y >= b.height or run.len == 0:
    return
  let first = max(0, x)
  let last = min(b.width, x + run.len)
  if first >= last:
    return
  b.repairAt(first, y)
  b.repairAt(last - 1, y)
  let base = y * b.width
  for column in first ..< last:
    b.cells[base + column] = Cell(rune: Rune(run[column - x]), style: style,
      displayWidth: 1)

proc writeCluster*(b: var Buffer, x, y: int, cluster: openArray[char],
    width: int, style = styleDefault()): int =
  ## Writes one already-sanitized, already-measured grapheme atomically and
  ## returns its width. `width` must come from `clusterWidth` with this
  ## buffer's width policy.
  result = width
  if result <= 0 or result > 2 or cluster.len == 0 or x < 0 or y < 0 or
      x >= b.width or y >= b.height or x + result > b.width:
    return 0
  if cluster.len == 1 and result == 1 and cluster[0] >= ' ' and
      cluster[0] < '\x7F':
    b.writeAscii(x, y, cluster[0], style)
  else:
    b.storeCluster(x, y, cluster, result, style)

proc writeCluster*(b: var Buffer, x, y: int, cluster: string,
    style = styleDefault()): int =
  ## Writes one already-sanitized grapheme atomically and returns its width.
  b.writeCluster(x, y, cluster.toOpenArray(0, cluster.len - 1),
    cluster.clusterWidth(b.widthPolicy), style)

proc writeSpans(b: var Buffer, x, y: int, safe: openArray[char],
    style: Style) =
  var cx = x
  var cy = y
  for span in safe.graphemeSpans:
    let first = safe[span.a]
    if span.len == 1 and first == '\n':
      inc cy
      cx = x
      continue
    if span.len == 1 and first == '\t':
      let advance = 4 - ((max(0, cx - x)) mod 4)
      if cy >= 0 and cy < b.height:
        for unused in 0 ..< advance:
          if cx >= 0 and cx < b.width:
            b.storeCluster(cx, cy, " ", 1, style)
          inc cx
      else:
        inc cx, advance
      continue
    let width = clusterWidth(safe.toOpenArray(span.a, span.b),
      b.widthPolicy)
    if width <= 0:
      continue
    if cy >= 0 and cy < b.height and cx >= 0 and cx + width <= b.width:
      b.storeCluster(cx, cy, safe.toOpenArray(span.a, span.b), width, style)
    inc cx, width

proc writeStr*(b: var Buffer, x, y: int, value: string,
    style = styleDefault(), policy = plainTextPolicy()) =
  ## Sanitizes and writes text. Grapheme clusters are atomic, wide clusters
  ## occupy a head/tail pair, CRLF is normalized, tabs advance to a four-cell
  ## stop, and a wide cluster clipped at the right edge is omitted.
  if value.isSanitized(policy):
    b.writeSpans(x, y, value.toOpenArray(0, value.len - 1), style)
  else:
    let safe = sanitizeText(value, policy)
    b.writeSpans(x, y, safe.toOpenArray(0, safe.len - 1), style)

proc internLink*(b: var Buffer, uri: string): uint16 =
  ## Returns the link id for `uri` in this buffer, adding it when new. Empty,
  ## oversized, or surplus URIs get id zero, which draws as plain text.
  if uri.len == 0 or uri.len > maxLinkBytes:
    return 0
  for index, known in b.links:
    if known == uri:
      return uint16(index + 1)
  if b.links.len >= maxLinksPerFrame:
    return 0
  b.links.add uri
  uint16(b.links.len)

proc linkCells*(b: var Buffer, x, y, width: int, link: uint16) =
  ## Attaches link `link` to the cells `x ..< x + width` of row `y` without
  ## touching their glyphs or styles.
  if y < 0 or y >= b.height or width <= 0:
    return
  let first = max(0, x)
  let last = min(b.width, x + width)
  let base = y * b.width
  for column in first ..< last:
    b.cells[base + column].link = link

proc reset*(b: var Buffer, style = styleDefault()) =
  ## Clears every cell, drops any scroll hint, links, and image placements,
  ## and reuses the complex-glyph arena capacity.
  b.glyphArena.setLen 0
  b.scrollHint = ScrollHint()
  b.scrollHintConflict = false
  b.links.setLen 0
  b.images.setLen 0
  let blank = blankCell(style)
  for cell in b.cells.mitems:
    cell = blank

proc hintScroll*(b: var Buffer, region: Rect, rows: int) =
  ## Records that `region` scrolled by `rows` since the previous frame. A
  ## second, different hint in the same frame cancels both.
  if rows == 0 or region.isEmpty:
    return
  if b.scrollHintConflict:
    return
  if b.scrollHint.rows != 0 and (b.scrollHint.region != region or
      b.scrollHint.rows != rows):
    b.scrollHint = ScrollHint()
    b.scrollHintConflict = true
    return
  b.scrollHint = ScrollHint(region: region, rows: rows)

proc scrollRows*(b: var Buffer, top, height, rows: int) =
  ## Moves full rows `top ..< top + height` by `rows` (positive is up) and
  ## blanks the rows exposed by the move, mirroring a terminal scroll inside
  ## a top/bottom margin region.
  if rows == 0 or height <= 0 or top < 0 or top + height > b.height:
    return
  let count = min(abs(rows), height)
  let width = b.width
  let blank = defaultCell()
  if rows > 0:
    for y in top ..< top + height - count:
      let dest = y * width
      let source = (y + count) * width
      for x in 0 ..< width:
        b.cells[dest + x] = b.cells[source + x]
    for y in top + height - count ..< top + height:
      for x in 0 ..< width:
        b.cells[y * width + x] = blank
  else:
    for y in countdown(top + height - 1, top + count):
      let dest = y * width
      let source = (y - count) * width
      for x in 0 ..< width:
        b.cells[dest + x] = b.cells[source + x]
    for y in top ..< top + count:
      for x in 0 ..< width:
        b.cells[y * width + x] = blank

proc copyCellFrom(dest: var Buffer, dx, dy: int, source: Buffer,
    cell: Cell) =
  if cell.wideTail:
    return
  let width = cell.cellWidth
  if dx < 0 or dy < 0 or dx + width > dest.width or dy >= dest.height:
    return
  let link = if cell.link == 0: 0'u16
    else: dest.internLink(source.linkUri(cell.link))
  if cell.glyphLen == 0:
    var simple = cell
    simple.link = link
    dest.setCell(dx, dy, simple)
    return
  let first = int(cell.glyphOffset)
  let last = first + int(cell.glyphLen)
  if last > source.glyphArena.len:
    return
  dest.repairAt(dx, dy)
  if width == 2:
    dest.repairAt(dx + 1, dy)
  var head = cell
  head.link = link
  head.glyphOffset = uint32(dest.glyphArena.len)
  dest.glyphArena.add source.glyphArena.toOpenArray(first, last - 1)
  dest.cells[dy * dest.width + dx] = head
  if width == 2:
    dest.cells[dy * dest.width + dx + 1] = Cell(rune: tailRune,
      style: cell.style, wideTail: true)

proc resize*(b: var Buffer, w, h: int) =
  ## Resizes while preserving complete glyphs in the overlapping top-left
  ## region. A wide glyph clipped by the new edge is omitted.
  var next = initBuffer(w, h, b.widthPolicy)
  let copyWidth = min(b.width, next.width)
  let copyHeight = min(b.height, next.height)
  for y in 0 ..< copyHeight:
    var x = 0
    while x < copyWidth:
      let cell = b.cells[y * b.width + x]
      if not cell.wideTail and x + cell.cellWidth <= copyWidth:
        next.copyCellFrom(x, y, b, cell)
      inc x, max(1, cell.cellWidth)
  b = next

proc clear*(b: var Buffer, rect: Rect, style = styleDefault()) =
  ## Clears `rect` and repairs wide glyphs crossing either edge.
  let clipped = intersection(rect, initRect(0, 0, b.width, b.height))
  if clipped.isEmpty:
    return
  let blank = blankCell(style)
  for y in clipped.y ..< clipped.y + clipped.height:
    b.repairAt(clipped.x, y)
    b.repairAt(clipped.x + clipped.width - 1, y)
    let base = y * b.width
    for x in clipped.x ..< clipped.x + clipped.width:
      b.cells[base + x] = blank

proc placeImage*(b: var Buffer, imageId: uint32, x, y, cols, rows: int) =
  ## Reserves a `cols` by `rows` cell box at `x`, `y` for image `imageId`:
  ## the cells become blank and the visible part is recorded as a placement.
  ## Boxes entirely outside the buffer and zero-sized boxes are ignored.
  if imageId == 0 or cols <= 0 or rows <= 0:
    return
  let visible = intersection(initRect(x, y, cols, rows),
    initRect(0, 0, b.width, b.height))
  if visible.isEmpty:
    return
  b.clear(visible)
  b.images.add ImagePlacement(imageId: imageId, rect: visible, cols: cols,
    rows: rows, offsetX: visible.x - x, offsetY: visible.y - y)

proc restyle*(b: var Buffer, rect: Rect, style: Style) =
  ## Restyles every cell inside `rect` without changing its glyph; used for
  ## selection highlights over already-rendered text.
  let clipped = intersection(rect, initRect(0, 0, b.width, b.height))
  if clipped.isEmpty:
    return
  for y in clipped.y ..< clipped.y + clipped.height:
    for x in clipped.x ..< clipped.x + clipped.width:
      b.cells[y * b.width + x].style = style

proc fill*(b: var Buffer, rect: Rect, rune: Rune, style: Style) =
  ## Fills a rectangle with a scalar while preserving wide-cell invariants.
  let clipped = intersection(rect, initRect(0, 0, b.width, b.height))
  if clipped.isEmpty:
    return
  b.clear(clipped, style)
  if rune == Rune(0x0020):
    return
  let width = max(1, rune.runeWidth(b.widthPolicy.ambiguous))
  let encoded = $rune
  for y in clipped.y ..< clipped.y + clipped.height:
    var x = clipped.x
    while x < clipped.x + clipped.width:
      if x + width <= clipped.x + clipped.width:
        b.storeCluster(x, y, encoded, width, style)
      inc x, width

func checkInvariants*(b: Buffer): bool =
  ## Checks head/tail, arena-bound, and row-bound invariants for tests/debugging.
  if b.width < 0 or b.height < 0 or b.cells.len != b.width * b.height:
    return false
  for y in 0 ..< b.height:
    for x in 0 ..< b.width:
      let cell = b.cells[y * b.width + x]
      if cell.wideTail:
        if x == 0 or b.cells[y * b.width + x - 1].wideTail or
            b.cells[y * b.width + x - 1].cellWidth != 2:
          return false
      elif cell.cellWidth == 2:
        if x + 1 >= b.width or not b.cells[y * b.width + x + 1].wideTail:
          return false
      if cell.glyphLen > 0 and
          int(cell.glyphOffset) + int(cell.glyphLen) > b.glyphArena.len:
        return false
  true

func isTransparentBlank(cell: Cell): bool {.inline.} =
  cell.rune == Rune(0x0020) and cell.glyphLen == 0 and not cell.wideTail and
    cell.style == styleDefault()

proc overlay*(destination: var Buffer, source: Buffer, x, y: int,
    transparentBlank = true) =
  ## Composites complete source graphemes at an offset. Default unstyled blanks
  ## may pass through; styled blanks remain opaque. Edge-clipped wide glyphs
  ## are omitted and both buffers retain valid head/tail pairs.
  for sourceY in 0 ..< source.height:
    let destinationY = y + sourceY
    if destinationY < 0 or destinationY >= destination.height:
      continue
    var sourceX = 0
    while sourceX < source.width:
      let cell = source.cells[sourceY * source.width + sourceX]
      let width = max(1, cell.cellWidth)
      if not cell.wideTail and not (transparentBlank and
          cell.isTransparentBlank):
        destination.copyCellFrom(x + sourceX, destinationY, source, cell)
      inc sourceX, width
