import private/writer

when defined(posix):
  import std/posix
  import private/term_posix
else:
  import private/term_windows
  import std/winlean

  proc getOsfhandle(fd: cint): int {.
    importc: "_get_osfhandle", header: "<io.h>".}

const seqEnterFullscreen = "\x1b[?1049h"
const seqEnableBase = "\x1b[?25l\x1b[?2004h\x1b[?1004h"
const seqEnableMouse = "\x1b[?1000h\x1b[?1002h\x1b[?1006h"
const seqDisableMouse = "\x1b[?1000l\x1b[?1002l\x1b[?1006l"
const seqKittyDisable = "\x1b[<u"
const seqDisableBase = "\x1b[0m\x1b[?1004l\x1b[?2004l\x1b[?25h"
const seqLeaveFullscreen = "\x1b[?1049l"

type TermSessionMode* = enum
  tsmFullscreen
  tsmInline

type Term* = object
  w*: Out
  mouse*: bool
  caps*: bool
  entered*: bool
  mode*: TermSessionMode
  platformActive: bool
  plat: PlatState

const restoreCapacity = 128

var g_restoreFd: cint = -1
var g_restoreBuf: array[restoreCapacity, char]
var g_restoreLen = 0
var g_resized = false
var g_left = true
var g_wakeFd: cint = -1

when defined(posix):
  var g_prevInt: Sigaction
  var g_prevTerm: Sigaction
  var g_prevWinch: Sigaction
  var g_intInstalled = false
  var g_termInstalled = false
  var g_winchInstalled = false
  var g_atexitInstalled = false

proc writeRaw(fd: cint, data: pointer, len: int) =
  var off = 0
  let bytes = cast[ptr UncheckedArray[char]](data)
  while off < len:
    when defined(posix):
      let n = posix.write(fd, addr bytes[off], int(len - off))
      if n < 0 and errno == EINTR:
        continue
      if n <= 0:
        break
      off += int(n)
    else:
      var written: DWORD = 0
      let handle = Handle(getOsfhandle(fd))
      if writeFile(handle, addr bytes[off], DWORD(len - off),
          addr written, nil) == 0 or written == 0:
        break
      off += int(written)

proc writeRaw(fd: cint, s: string) =
  if s.len > 0:
    writeRaw(fd, unsafeAddr s[0], s.len)

func restoreSequence(t: Term): string =
  result = seqDisableMouse
  if t.caps:
    result.add seqKittyDisable
  result.add seqDisableBase
  if t.mode == tsmFullscreen:
    result.add seqLeaveFullscreen

proc storeRestore(t: Term) =
  ## Fixed storage keeps the restore sequence async-signal-safe.
  let sequence = t.restoreSequence
  let count = min(sequence.len, restoreCapacity)
  for index in 0 ..< count:
    g_restoreBuf[index] = sequence[index]
  g_restoreLen = count

when defined(posix):
  proc sigFatal(sig: cint) {.noconv.} =
    ## Async-signal-safe restore followed by the default signal outcome.
    if g_restoreFd >= 0 and g_restoreLen > 0:
      discard posix.write(g_restoreFd, addr g_restoreBuf[0], g_restoreLen)
    discard signal(sig, SIG_DFL)
    discard posix.raise(sig)

  proc sigWinch(sig: cint) {.noconv.} =
    ## The pipe write closes the race between the flag check and poll.
    g_resized = true
    if g_wakeFd >= 0:
      var value = byte(1)
      discard posix.write(g_wakeFd, addr value, 1)

  proc exitHook() {.noconv.} =
    ## atexit callback restoring the terminal on normal exit.
    if not g_left and g_restoreFd >= 0 and g_restoreLen > 0:
      writeRaw(g_restoreFd, addr g_restoreBuf[0], g_restoreLen)

  proc c_atexit(cb: proc () {.noconv.}): cint {.
    importc: "atexit", header: "<stdlib.h>".}

  proc installFatal(sig: cint, previous: var Sigaction,
      installed: var bool): bool =
    if installed:
      return true
    var action: Sigaction
    action.sa_handler = sigFatal
    action.sa_flags = 0
    if sigaction(sig, action, addr previous) != 0:
      return false
    installed = true
    true

proc leave*(t: var Term)

proc enter*(t: var Term, o: sink Out, mouse = false,
    mode = tsmFullscreen) =
  ## Enables raw mode, switches to the alternate screen, hides the cursor,
  ## enables bracketed paste, and installs exit hooks. Mouse tracking is
  ## optional. Idempotent.
  if t.entered:
    return
  t.w = o
  t.platformActive = t.w.kind == outTty
  if t.platformActive and not t.plat.platRawEnable:
    raise newException(IOError,
      "cannot enter terminal raw/VT mode; stdin may not be a supported TTY")
  t.mouse = mouse
  t.mode = mode
  t.entered = true
  if t.platformActive:
    g_left = false
  var enable = if mode == tsmFullscreen: seqEnterFullscreen else: ""
  enable.add seqEnableBase
  if mouse:
    enable.add seqEnableMouse
  try:
    t.w.write enable.toOpenArrayByte(0, enable.len - 1)
  except CatchableError:
    t.entered = false
    t.plat.platRawDisable()
    if t.platformActive:
      g_left = true
    raise
  if not t.platformActive:
    return
  t.storeRestore()
  g_restoreFd = t.w.fd
  when defined(posix):
    if not installFatal(SIGINT, g_prevInt, g_intInstalled) or
        not installFatal(SIGTERM, g_prevTerm, g_termInstalled):
      t.leave()
      raise newException(IOError, "cannot install terminal signal handlers")
    if not g_winchInstalled:
      var action: Sigaction
      action.sa_handler = sigWinch
      action.sa_flags = 0
      if sigaction(SIGWINCH, action, addr g_prevWinch) != 0:
        t.leave()
        raise newException(IOError, "cannot install resize signal handler")
      g_winchInstalled = true
    if not g_atexitInstalled:
      if c_atexit(exitHook) != 0:
        t.leave()
        raise newException(IOError, "cannot install terminal exit hook")
      g_atexitInstalled = true

proc setKittyProtocol*(t: var Term, enabled: bool) =
  ## Records keyboard-protocol state in both normal and fatal restore paths.
  t.caps = enabled
  if t.platformActive:
    t.storeRestore()

proc setSignalWakeFd*(t: Term, fd: cint) =
  ## Registers the reactor wake descriptor that the resize handler writes to.
  ## Pass -1 before the reactor closes.
  if t.platformActive or fd < 0:
    g_wakeFd = fd

proc leave*(t: var Term) =
  ## Fully restores the terminal: raw mode off, alt-screen exit, protocol
  ## disables, cursor shown. Idempotent and safe after a signal.
  if not t.entered:
    return
  t.entered = false
  if t.platformActive:
    t.plat.platRawDisable()
  let restore = t.restoreSequence
  if t.w.kind == outTty:
    writeRaw(t.w.fd, restore)
  else:
    t.w.write restore.toOpenArrayByte(0, restore.len - 1)
  if t.platformActive:
    g_left = true
    g_restoreFd = -1
    g_wakeFd = -1
  when defined(posix):
    if g_intInstalled:
      discard sigaction(SIGINT, g_prevInt)
      g_intInstalled = false
    if g_termInstalled:
      discard sigaction(SIGTERM, g_prevTerm)
      g_termInstalled = false
    if g_winchInstalled:
      discard sigaction(SIGWINCH, g_prevWinch)
      g_winchInstalled = false
  t.platformActive = false

proc readInput*(t: Term, buf: pointer, len: int): int =
  ## Reads raw input bytes from the terminal, -1 on error.
  t.plat.platRead(buf, len)

proc size*(t: Term): tuple[w, h: int] =
  ## Returns the current terminal size in cells.
  t.plat.platSize()

proc takeResize*(t: var Term): bool =
  ## Returns and clears the SIGWINCH-driven resize flag.
  result = g_resized
  g_resized = false

func interactive*(t: Term): bool =
  ## True when this session owns real terminal input rather than a fake sink.
  t.platformActive

when not defined(posix):
  func inputHandle*(t: Term): Handle =
    ## Returns the console input handle for the Windows wait set.
    t.plat.platInputHandle()
