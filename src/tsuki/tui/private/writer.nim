import std/[os, strutils, unicode]
import ../style
import ../buffer
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
  Out* = object
    frame*: seq[byte]
    curStyle*: Style
    curValid*: bool
    truecolor*: bool
    syncOutput*: bool
    case kind*: OutKind
    of outTty:
      fd*: cint
    of outFake:
      fake*: ref FakeBuf

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

proc beginFrame*(o: var Out) {.inline.} =
  o.frame.setLen 0
  if o.syncOutput:
    o.frame.addSeq seqSyncBegin

proc endFrame*(o: var Out) =
  if o.syncOutput:
    if o.frame.len == seqSyncBegin.len:
      o.frame.setLen 0
      return
    o.frame.addSeq seqSyncEnd
  o.write o.frame

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
  ## line, trailing blank runs collapsed into an erase-to-end-of-line. The
  ## frame is emitted as a single write syscall.
  o.beginFrame()
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
      o.frame.appendGlyphBytes(b, c)
    if contentEnd < b.width:
      if not haveCur or cur != def:
        o.setStyle(cur, haveCur, def)
      o.frame.addSeq "\x1b[K"
  o.curStyle = cur
  o.curValid = true
  o.endFrame()
