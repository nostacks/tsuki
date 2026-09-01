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

  Buffer* = object
    ## A rectangular cell grid and its reused complex-glyph arena.
    width*: int
    height*: int
    cells*: seq[Cell]
    glyphArena*: seq[byte]
    widthPolicy*: WidthPolicy
    rowVersions: seq[uint64]
    fingerprintVersions: seq[uint64]
    rowFingerprints: seq[uint64]

func defaultCell*(): Cell =
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
    a.glyphLen == b.glyphLen

func initBuffer*(w, h: int, widthPolicy = WidthPolicy()): Buffer =
  ## Creates a nonnegative `w` by `h` blank buffer.
  result.width = max(0, w)
  result.height = max(0, h)
  result.widthPolicy = widthPolicy
  result.cells = newSeq[Cell](result.width * result.height)
  result.rowVersions = newSeq[uint64](result.height)
  result.fingerprintVersions = newSeq[uint64](result.height)
  result.rowFingerprints = newSeq[uint64](result.height)
  for version in result.rowVersions.mitems: version = 1
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
  if ao < 0 or bo < 0 or ao + n > a.glyphArena.len or
      bo + n > b.glyphArena.len:
    return false
  for i in 0 ..< n:
    if a.glyphArena[ao + i] != b.glyphArena[bo + i]:
      return false
  true

func sameCell*(a: Buffer, ai: int, b: Buffer, bi: int): bool =
  ## Compares two cells including complex grapheme bytes across arenas.
  if ai < 0 or ai >= a.cells.len or bi < 0 or bi >= b.cells.len:
    return false
  let ac = a.cells[ai]
  let bc = b.cells[bi]
  if ac.glyphLen == 0 and bc.glyphLen == 0:
    return ac.rune == bc.rune and ac.style == bc.style and
      ac.wideTail == bc.wideTail and ac.cellWidth == bc.cellWidth
  ac.rune == bc.rune and ac.style == bc.style and
    ac.wideTail == bc.wideTail and ac.cellWidth == bc.cellWidth and
    glyphBytesEqual(a, ac, b, bc)

proc markRow(b: var Buffer, y: int) {.inline.} =
  if y >= 0 and y < b.rowVersions.len:
    inc b.rowVersions[y]

func mix(hash: var uint64, value: uint64) {.inline.} =
  hash = (hash xor value) * 1099511628211'u64

func mixColor(hash: var uint64, color: Color) =
  hash.mix uint64(ord(color.kind))
  case color.kind
  of ckDefault: discard
  of ckNamed: hash.mix uint64(ord(color.name))
  of ckIndexed: hash.mix uint64(color.index)
  of ckRgb:
    hash.mix uint64(color.rgb[0])
    hash.mix uint64(color.rgb[1])
    hash.mix uint64(color.rgb[2])

proc rowFingerprint*(b: var Buffer, y: int): uint64 =
  ## Returns a cached content fingerprint used to skip unchanged row scans.
  if y < 0 or y >= b.height: return 0
  if b.fingerprintVersions[y] == b.rowVersions[y]:
    return b.rowFingerprints[y]
  var hash = 1469598103934665603'u64
  for x in 0 ..< b.width:
    let cell = b.cells[y * b.width + x]
    hash.mix uint64(uint32(cell.rune))
    hash.mix uint64(cell.cellWidth)
    hash.mix uint64(ord(cell.wideTail))
    hash.mixColor cell.style.fg
    hash.mixColor cell.style.bg
    hash.mix uint64(cast[uint8](cell.style.attrs))
    if cell.glyphLen > 0:
      let first = int(cell.glyphOffset)
      let last = min(b.glyphArena.len, first + int(cell.glyphLen))
      for index in first ..< last: hash.mix uint64(b.glyphArena[index])
  b.rowFingerprints[y] = hash
  b.fingerprintVersions[y] = b.rowVersions[y]
  hash

func `==`*(a, b: Buffer): bool =
  ## Compares dimensions, styles, and grapheme content, independent of arena
  ## offsets and capacities.
  if a.width != b.width or a.height != b.height or
      a.cells.len != b.cells.len:
    return false
  for i in 0 ..< a.cells.len:
    if not sameCell(a, i, b, i):
      return false
  true

proc appendGlyphBytes*(dest: var seq[byte], b: Buffer, cell: Cell) =
  ## Appends a head cell's exact UTF-8 grapheme bytes to `dest`.
  if cell.wideTail:
    return
  if cell.glyphLen == 0:
    let value = uint32(cell.rune)
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
  else:
    let first = int(cell.glyphOffset)
    let last = first + int(cell.glyphLen)
    if first >= 0 and last <= b.glyphArena.len:
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
  b.markRow(y)
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

proc writeCluster*(b: var Buffer, x, y: int, cluster: string,
    style = styleDefault()): int =
  ## Writes one already-sanitized grapheme atomically and returns its width.
  result = cluster.clusterWidth(b.widthPolicy)
  if result <= 0 or x < 0 or y < 0 or x >= b.width or y >= b.height or
      x + result > b.width:
    return
  b.markRow(y)
  b.repairAt(x, y)
  if result == 2:
    b.repairAt(x + 1, y)
  let base = cluster.runeAt(0)
  var head = Cell(rune: base, style: style, displayWidth: uint8(result))
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
    for i in 0 ..< int(head.glyphLen):
      b.glyphArena.add byte(cluster[i])
  b.cells[y * b.width + x] = head
  if result == 2:
    b.cells[y * b.width + x + 1] = Cell(rune: tailRune, style: style,
      wideTail: true)

proc writeStr*(b: var Buffer, x, y: int, value: string,
    style = styleDefault(), policy = plainTextPolicy()) =
  ## Sanitizes and writes text. Grapheme clusters are atomic, wide clusters
  ## occupy a head/tail pair, CRLF is normalized, tabs advance to a four-cell
  ## stop, and a wide cluster clipped at the right edge is omitted.
  let safe = sanitizeText(value, policy)
  var cx = x
  var cy = y
  for cluster in safe.graphemes:
    if cluster == "\n":
      inc cy
      cx = x
      continue
    if cluster == "\t":
      let advance = 4 - ((max(0, cx - x)) mod 4)
      for unused in 0 ..< advance:
        if cx >= 0 and cx < b.width and cy >= 0 and cy < b.height:
          discard b.writeCluster(cx, cy, " ", style)
        inc cx
      continue
    let width = cluster.clusterWidth(b.widthPolicy)
    if width <= 0:
      continue
    if cy >= 0 and cy < b.height and cx >= 0 and cx + width <= b.width:
      discard b.writeCluster(cx, cy, cluster, style)
    inc cx, width

proc reset*(b: var Buffer, style = styleDefault()) =
  ## Clears every cell and reuses the complex-glyph arena capacity.
  b.glyphArena.setLen 0
  let blank = blankCell(style)
  for y in 0 ..< b.height:
    b.markRow(y)
    for x in 0 ..< b.width:
      b.cells[y * b.width + x] = blank

proc copyCellFrom(dest: var Buffer, dx, dy: int, source: Buffer, sx, sy: int) =
  let sourceCell = source.cellAt(sx, sy)
  if sourceCell.wideTail:
    return
  if sourceCell.glyphLen == 0:
    dest.setCell(dx, dy, sourceCell)
  else:
    discard dest.writeCluster(dx, dy, source.glyphString(sourceCell),
      sourceCell.style)

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
        next.copyCellFrom(x, y, b, x, y)
      inc x, max(1, cell.cellWidth)
  b = next

proc clear*(b: var Buffer, rect: Rect, style = styleDefault()) =
  ## Clears `rect` and repairs wide glyphs crossing either edge.
  let clipped = intersection(rect, initRect(0, 0, b.width, b.height))
  if clipped.isEmpty:
    return
  for y in clipped.y ..< clipped.y + clipped.height:
    b.markRow(y)
    for x in clipped.x ..< clipped.x + clipped.width:
      b.repairAt(x, y)
    for x in clipped.x ..< clipped.x + clipped.width:
      b.cells[y * b.width + x] = blankCell(style)

proc restyle*(b: var Buffer, rect: Rect, style: Style) =
  ## Restyles every cell inside `rect` without changing its glyph; used for
  ## selection highlights over already-rendered text.
  let clipped = intersection(rect, initRect(0, 0, b.width, b.height))
  if clipped.isEmpty:
    return
  for y in clipped.y ..< clipped.y + clipped.height:
    b.markRow(y)
    for x in clipped.x ..< clipped.x + clipped.width:
      b.cells[y * b.width + x].style = style

proc fill*(b: var Buffer, rect: Rect, rune: Rune, style: Style) =
  ## Fills a rectangle with a scalar while preserving wide-cell invariants.
  let clipped = intersection(rect, initRect(0, 0, b.width, b.height))
  if clipped.isEmpty:
    return
  b.clear(clipped, style)
  let width = max(1, rune.runeWidth(b.widthPolicy.ambiguous))
  var encoded = $rune
  for y in clipped.y ..< clipped.y + clipped.height:
    var x = clipped.x
    while x < clipped.x + clipped.width:
      if x + width <= clipped.x + clipped.width:
        discard b.writeCluster(x, y, encoded, style)
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
    var sourceX = 0
    while sourceX < source.width:
      let cell = source.cellAt(sourceX, sourceY)
      let width = max(1, cell.cellWidth)
      if not cell.wideTail and not (transparentBlank and
          cell.isTransparentBlank):
        let destinationX = x + sourceX
        let destinationY = y + sourceY
        if destinationX >= 0 and destinationY >= 0 and
            destinationX + width <= destination.width and
            destinationY < destination.height:
          discard destination.writeCluster(destinationX, destinationY,
            source.glyphString(cell), cell.style)
      inc sourceX, width
