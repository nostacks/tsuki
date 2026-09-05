import std/[base64, os, strutils, unicode]
import ../style
import ../buffer
import ../layout
import ./ansi

when defined(windows):
  import std/winlean

  proc getOsfhandle(fd: cint): int {.
    importc: "_get_osfhandle", header: "<io.h>".}
else:
  import std/posix as posixapi

const
  seqSyncBegin = "\x1b[?2026h"
  seqSyncEnd = "\x1b[?2026l"

type
  OutKind* = enum
    outTty
    outFake
  FakeBuf* = object
    bytes*: seq[byte]
    writes*: int
  ImageProtocolOut* = enum
    ## Image transport the sink may emit. Anything but `imageOutNone` was
    ## chosen from advertised capabilities by the host.
    imageOutNone
    imageOutKitty
    imageOutIterm
  ImageAsset = object
    id: uint32
    data: string
    widthPx: int
    heightPx: int
    transmitted: bool
  ActivePlacement = object
    placement: ImagePlacement
    placementId: uint32
    stale: bool
  Out* = object
    frame*: seq[byte]
    curStyle*: Style
    curValid*: bool
    truecolor*: bool
    syncOutput*: bool
    scrollRegions*: bool
    hyperlinks*: bool
    imageProtocol*: ImageProtocolOut
    deferPlacements*: bool
      ## While set, frames delete stale placements but add none, so a fast
      ## scroll does not re-place every image on every tick.
    curLink: string
    assets: seq[ImageAsset]
    active: seq[ActivePlacement]
    nextPlacementId: uint32
    case kind*: OutKind
    of outTty:
      fd*: cint
    of outFake:
      fake*: ref FakeBuf

const
  kittyChunkChars = 4096
  invalidRune = Rune(0xFFFE)

proc initOut*(fd: cint): Out =
  ## Creates a tty-backed output sink writing directly to `fd`. Truecolor SGR
  ## emission follows the terminal's COLORTERM advertisement so interpolated
  ## colors stay smooth on capable terminals.
  let colorTerm = getEnv("COLORTERM").toLowerAscii
  Out(kind: outTty, fd: fd,
    truecolor: "truecolor" in colorTerm or "24bit" in colorTerm)

proc initFakeOut*(): Out =
  ## Creates an in-memory output sink for tests with deterministic styling.
  Out(kind: outFake, fake: new(ref FakeBuf))

proc write*(o: var Out, data: openArray[byte]) =
  ## Writes `data` in one syscall when tty-backed, appends when fake-backed.
  if data.len == 0:
    return
  case o.kind
  of outFake:
    o.fake.bytes.add data
    inc o.fake.writes
  of outTty:
    var off = 0
    while off < data.len:
      when defined(windows):
        var n: DWORD = 0
        let h = Handle(getOsfhandle(o.fd))
        if writeFile(h, unsafeAddr data[off], DWORD(data.len - off), addr n,
            nil) == 0 or n == 0:
          raiseOSError(osLastError())
        off += int(n)
      else:
        let n = posixapi.write(o.fd, unsafeAddr data[off], int(data.len - off))
        if n < 0:
          if errno == EINTR or errno == EAGAIN:
            continue
          raiseOSError(osLastError())
        if n == 0:
          raise newException(IOError, "terminal write made no progress")
        off += int(n)

proc addSeq*(f: var seq[byte], s: string) {.inline.} =
  if s.len > 0:
    f.add s.toOpenArrayByte(0, s.len - 1)

proc addUInt*(f: var seq[byte], value: int) {.inline.} =
  ## Appends a non-negative decimal integer without allocating a string.
  var digits: array[20, byte]
  var value = value
  var count = 0
  if value == 0:
    f.add byte('0')
    return
  while value > 0:
    digits[count] = byte(ord('0') + value mod 10)
    value = value div 10
    inc count
  while count > 0:
    dec count
    f.add digits[count]

proc addCursorMove*(f: var seq[byte], row, col: int) {.inline.} =
  ## Appends a one-based ANSI cursor position without temporary strings.
  f.add byte(0x1b)
  f.add byte('[')
  f.addUInt row
  f.add byte(';')
  f.addUInt col
  f.add byte('H')

proc addRune*(f: var seq[byte], r: Rune) {.inline.} =
  ## Appends the UTF-8 encoding of `r` without intermediate allocations.
  let v = uint32(r)
  if v < 0x80:
    f.add byte(v)
  elif v < 0x800:
    f.add byte(0xC0 or (v shr 6))
    f.add byte(0x80 or (v and 0x3F))
  elif v < 0x10000:
    f.add byte(0xE0 or (v shr 12))
    f.add byte(0x80 or ((v shr 6) and 0x3F))
    f.add byte(0x80 or (v and 0x3F))
  else:
    f.add byte(0xF0 or (v shr 18))
    f.add byte(0x80 or ((v shr 12) and 0x3F))
    f.add byte(0x80 or ((v shr 6) and 0x3F))
    f.add byte(0x80 or (v and 0x3F))

func isBlank*(c: Cell): bool {.inline.} =
  c.rune == Rune(0x0020) and c.glyphLen == 0 and not c.wideTail and
    c.style == styleDefault()

func rowContentEnd*(b: Buffer, y: int): int =
  let base = y * b.width
  result = b.width
  while result > 0 and b.cells[base + result - 1].isBlank:
    dec result

proc addScrollRegion*(f: var seq[byte], top, bottom, rows: int) =
  ## Appends a scroll of `rows` lines (positive is up) confined to the
  ## one-based rows `top .. bottom`, leaving the margins reset afterwards.
  f.add byte(0x1b)
  f.add byte('[')
  f.addUInt top
  f.add byte(';')
  f.addUInt bottom
  f.add byte('r')
  f.add byte(0x1b)
  f.add byte('[')
  f.addUInt abs(rows)
  f.add byte(if rows > 0: 'S' else: 'T')
  f.addSeq "\x1b[r"

func linkSafe(uri: string): bool =
  ## OSC payloads end at the first control byte, so a URI carrying one could
  ## cut the sequence short or smuggle a control into the terminal.
  for ch in uri:
    if ch < ' ' or ch == '\x7F':
      return false
  true

func hasOpenLink*(o: Out): bool {.inline.} =
  ## True while an OSC 8 hyperlink is open in the current frame.
  o.curLink.len > 0

proc closeLink*(o: var Out) =
  ## Ends the open OSC 8 hyperlink, if any.
  if o.curLink.len == 0:
    return
  o.frame.addSeq "\x1b]8;;\x1b\\"
  o.curLink.setLen 0

proc setLink*(o: var Out, b: Buffer, link: uint16) =
  ## Makes the terminal's hyperlink state match a cell's link: closes the
  ## open link when the cell has none and opens the cell's URI otherwise.
  ## Emits nothing when the sink does not advertise hyperlinks.
  if not o.hyperlinks:
    return
  if link == 0 or int(link) > b.links.len:
    o.closeLink()
    return
  if o.curLink == b.links[int(link) - 1]:
    return
  o.closeLink()
  let uri = b.links[int(link) - 1]
  if not uri.linkSafe:
    return
  o.frame.addSeq "\x1b]8;;"
  o.frame.addSeq uri
  o.frame.addSeq "\x1b\\"
  o.curLink = uri

proc beginFrame*(o: var Out) {.inline.} =
  o.frame.setLen 0
  if o.syncOutput:
    o.frame.addSeq seqSyncBegin

proc endFrame*(o: var Out) =
  o.closeLink()
  if o.syncOutput:
    if o.frame.len == seqSyncBegin.len:
      o.frame.setLen 0
      return
    o.frame.addSeq seqSyncEnd
  o.write o.frame

func findAsset(o: Out, id: uint32): int =
  for index, asset in o.assets:
    if asset.id == id:
      return index
  -1

func hasImage*(o: Out, id: uint32): bool =
  ## True once `registerImage` stored data for `id`.
  o.findAsset(id) >= 0

proc registerImage*(o: var Out, id: uint32, data: string,
    widthPx, heightPx: int) =
  ## Stores PNG bytes for image `id` so later placements can show it.
  ## Re-registering an id replaces the data and re-places its placements.
  ## Nothing is stored when the sink has no image protocol.
  if o.imageProtocol == imageOutNone or id == 0 or data.len == 0 or
      widthPx <= 0 or heightPx <= 0:
    return
  let index = o.findAsset(id)
  let asset = ImageAsset(id: id, data: data, widthPx: widthPx,
    heightPx: heightPx)
  if index >= 0:
    o.assets[index] = asset
    for entry in o.active.mitems:
      if entry.placement.imageId == id:
        entry.stale = true
  else:
    o.assets.add asset

proc addKittyDelete(f: var seq[byte], id, placementId: uint32) =
  f.addSeq "\x1b_Ga=d,d=i,i="
  f.addUInt int(id)
  if placementId != 0:
    f.addSeq ",p="
    f.addUInt int(placementId)
  f.addSeq ",q=2\x1b\\"

proc forgetImage*(o: var Out, id: uint32) =
  ## Drops image `id`: kitty terminals free its data at once, and any cells
  ## it covered are repainted by the next frame.
  let index = o.findAsset(id)
  if index < 0:
    return
  o.assets.delete(index)
  if o.imageProtocol == imageOutKitty:
    var bytes: seq[byte]
    bytes.addSeq "\x1b_Ga=d,d=I,i="
    bytes.addUInt int(id)
    bytes.addSeq ",q=2\x1b\\"
    o.write bytes
    var kept: seq[ActivePlacement]
    for entry in o.active:
      if entry.placement.imageId != id:
        kept.add entry
    o.active = kept
  else:
    for entry in o.active.mitems:
      if entry.placement.imageId == id:
        entry.stale = true

proc invalidateImages*(o: var Out, region: Rect) =
  ## Marks placements touching `region` for deletion and re-placement, used
  ## after the terminal moved rows with a scroll region.
  for entry in o.active.mitems:
    if not intersection(entry.placement.rect, region).isEmpty:
      entry.stale = true

proc invalidateCells(b: var Buffer, rect: Rect) =
  ## Makes `prev` cells unlike any drawable cell so the diff repaints them.
  let clipped = intersection(rect, initRect(0, 0, b.width, b.height))
  if clipped.isEmpty:
    return
  for y in clipped.y ..< clipped.y + clipped.height:
    let base = y * b.width
    for x in clipped.x ..< clipped.x + clipped.width:
      b.cells[base + x] = Cell(rune: invalidRune, displayWidth: 1)

proc removeStaleImages*(o: var Out, prev: var Buffer,
    desired: openArray[ImagePlacement]) =
  ## Deletes terminal placements that the next frame no longer wants. Runs
  ## before the cell diff so cells under a removed iTerm image are repainted.
  if o.active.len == 0:
    return
  var kept: seq[ActivePlacement]
  for entry in o.active:
    if not entry.stale and entry.placement in desired:
      kept.add entry
      continue
    case o.imageProtocol
    of imageOutKitty:
      o.frame.addKittyDelete(entry.placement.imageId, entry.placementId)
    of imageOutIterm, imageOutNone:
      discard
    prev.invalidateCells(entry.placement.rect)
  o.active = kept

proc transmitKitty(o: var Out, asset: var ImageAsset) =
  let encoded = base64.encode(asset.data)
  var offset = 0
  var first = true
  while offset < encoded.len:
    let stop = min(encoded.len, offset + kittyChunkChars)
    o.frame.addSeq "\x1b_G"
    if first:
      o.frame.addSeq "a=t,f=100,i="
      o.frame.addUInt int(asset.id)
      o.frame.addSeq ",q=2,"
      first = false
    o.frame.addSeq(if stop < encoded.len: "m=1;" else: "q=2,m=0;")
    o.frame.add encoded.toOpenArrayByte(offset, stop - 1)
    o.frame.addSeq "\x1b\\"
    offset = stop
  asset.transmitted = true

proc placeKitty(o: var Out, asset: ImageAsset, p: ImagePlacement,
    placementId: uint32) =
  o.frame.addCursorMove(p.rect.y + 1, p.rect.x + 1)
  o.frame.addSeq "\x1b_Ga=p,i="
  o.frame.addUInt int(asset.id)
  o.frame.addSeq ",p="
  o.frame.addUInt int(placementId)
  if p.offsetX > 0 or p.offsetY > 0 or p.rect.width < p.cols or
      p.rect.height < p.rows:
    o.frame.addSeq ",x="
    o.frame.addUInt p.offsetX * asset.widthPx div p.cols
    o.frame.addSeq ",y="
    o.frame.addUInt p.offsetY * asset.heightPx div p.rows
    o.frame.addSeq ",w="
    o.frame.addUInt max(1, p.rect.width * asset.widthPx div p.cols)
    o.frame.addSeq ",h="
    o.frame.addUInt max(1, p.rect.height * asset.heightPx div p.rows)
  o.frame.addSeq ",c="
  o.frame.addUInt p.rect.width
  o.frame.addSeq ",r="
  o.frame.addUInt p.rect.height
  o.frame.addSeq ",C=1,q=2\x1b\\"

proc placeIterm(o: var Out, asset: ImageAsset, p: ImagePlacement) =
  o.frame.addCursorMove(p.rect.y + 1, p.rect.x + 1)
  o.frame.addSeq "\x1b]1337;File=inline=1;doNotMoveCursor=1;"
  o.frame.addSeq "preserveAspectRatio=0;width="
  o.frame.addUInt p.rect.width
  o.frame.addSeq ";height="
  o.frame.addUInt p.rect.height
  o.frame.addSeq ";size="
  o.frame.addUInt asset.data.len
  o.frame.add byte(':')
  let encoded = base64.encode(asset.data)
  o.frame.add encoded.toOpenArrayByte(0, encoded.len - 1)
  o.frame.add byte(0x07)

proc placeImages*(o: var Out, desired: openArray[ImagePlacement]) =
  ## Emits placements for images the terminal does not show yet. Runs after
  ## the cell diff so no later cell write erases an inline image. Unknown
  ## image ids and cropped iTerm images are skipped without output.
  if o.imageProtocol == imageOutNone or desired.len == 0 or
      o.deferPlacements:
    return
  for p in desired:
    var shown = false
    for entry in o.active:
      if entry.placement == p:
        shown = true
        break
    if shown:
      continue
    let index = o.findAsset(p.imageId)
    if index < 0:
      continue
    o.closeLink()
    case o.imageProtocol
    of imageOutKitty:
      if not o.assets[index].transmitted:
        o.transmitKitty(o.assets[index])
      inc o.nextPlacementId
      if o.nextPlacementId == 0: inc o.nextPlacementId
      o.placeKitty(o.assets[index], p, o.nextPlacementId)
      o.active.add ActivePlacement(placement: p,
        placementId: o.nextPlacementId)
    of imageOutIterm:
      if p.offsetX > 0 or p.offsetY > 0 or p.rect.width < p.cols or
          p.rect.height < p.rows:
        continue
      o.placeIterm(o.assets[index], p)
      o.active.add ActivePlacement(placement: p)
    of imageOutNone:
      discard

proc resetImages*(o: var Out) =
  ## Forgets every terminal placement before a full repaint. Kitty
  ## terminals drop the placements too; cells repaint everything else.
  if o.active.len == 0:
    return
  if o.imageProtocol == imageOutKitty:
    o.frame.addSeq "\x1b_Ga=d,d=a,q=2\x1b\\"
  o.active.setLen 0

proc deleteAllImagesNow*(o: var Out) =
  ## Frees every kitty image before the terminal is restored.
  if o.imageProtocol != imageOutKitty or o.assets.len == 0:
    return
  const bytes = "\x1b_Ga=d,d=A,q=2\x1b\\"
  o.write bytes.toOpenArrayByte(0, bytes.len - 1)
  o.active.setLen 0
  for asset in o.assets.mitems:
    asset.transmitted = false

proc setStyle*(o: var Out, cur: var Style, haveCur: var bool,
    next: Style) {.inline.} =
  if not haveCur:
    o.frame.addStyleReset(next, o.truecolor)
    haveCur = true
  else:
    o.frame.addStyleTransition(cur, next, o.truecolor)
  cur = next

proc flushFull*(o: var Out, b: Buffer) =
  ## Serializes the entire buffer into one frame: cursor home, one row per
  ## line, trailing blank runs collapsed into an erase-to-end-of-line, then
  ## every image placement. The frame is emitted as a single write syscall.
  o.beginFrame()
  o.resetImages()
  let def = styleDefault()
  o.frame.addSeq "\x1b[H"
  var cur = o.curStyle
  var haveCur = o.curValid
  for y in 0 ..< b.height:
    if y > 0:
      o.frame.addCursorMove(y + 1, 1)
    let contentEnd = b.rowContentEnd(y)
    let base = y * b.width
    for x in 0 ..< contentEnd:
      let c = b.cells[base + x]
      if c.wideTail:
        continue
      if not haveCur or c.style != cur:
        o.setStyle(cur, haveCur, c.style)
      if c.link != 0 or o.curLink.len > 0:
        o.setLink(b, c.link)
      o.frame.appendGlyphBytes(b, c)
    if contentEnd < b.width:
      if not haveCur or cur != def:
        o.setStyle(cur, haveCur, def)
      o.closeLink()
      o.frame.addSeq "\x1b[K"
  o.closeLink()
  o.placeImages(b.images)
  o.curStyle = cur
  o.curValid = true
  o.endFrame()
