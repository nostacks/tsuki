import std/[os, posix, strutils, termios]

when not declared(SIGWINCH):
  const SIGWINCH* = 28

type PlatState* = object
  orig: Termios
  rawApplied: bool

const tiocgwinsz =
  when defined(macosx) or defined(macos) or defined(bsd):
    0x40087468
  else:
    0x5413

type WinSize = object
  ws_row: cushort
  ws_col: cushort
  ws_xpixel: cushort
  ws_ypixel: cushort

proc platRawEnable*(s: var PlatState): bool =
  ## Applies cfmakeraw-equivalent flags to stdin, saving the original state.
  var t: Termios
  if tcGetAttr(0, addr t) != 0:
    return false
  s.orig = t
  t.c_iflag = t.c_iflag and not (IGNBRK or BRKINT or PARMRK or ISTRIP or
    INLCR or IGNCR or ICRNL or IXON)
  t.c_oflag = t.c_oflag and not OPOST
  t.c_lflag = t.c_lflag and not (ECHO or ECHONL or ICANON or ISIG or IEXTEN)
  t.c_cflag = t.c_cflag and not (CSIZE or PARENB)
  t.c_cflag = t.c_cflag or CS8
  t.c_cc[VMIN] = char(1)
  t.c_cc[VTIME] = char(0)
  s.rawApplied = tcSetAttr(0, TCSANOW, addr t) == 0
  s.rawApplied

proc platRawDisable*(s: var PlatState) =
  ## Restores the original stdin termios saved at enable time.
  if s.rawApplied:
    discard tcSetAttr(0, TCSANOW, addr s.orig)
    s.rawApplied = false

proc envSize(): tuple[w, h: int] =
  let columns = getEnv("COLUMNS")
  let lines = getEnv("LINES")
  var w = 0
  var h = 0
  try:
    if columns.len > 0: w = parseInt(columns)
    if lines.len > 0: h = parseInt(lines)
  except ValueError:
    discard
  if w > 0 and h > 0: (w, h) else: (80, 24)

proc platSize*(s: PlatState): tuple[w, h: int] =
  ## Returns the terminal size in cells. Every standard descriptor is tried
  ## because stdout may be redirected while stdin or stderr is still the tty;
  ## COLUMNS/LINES and then 80x24 are the fallbacks.
  var ws: WinSize
  for fd in [cint(1), cint(0), cint(2)]:
    if ioctl(fd, tiocgwinsz, addr ws) == 0 and ws.ws_col > 0 and
        ws.ws_row > 0:
      return (int(ws.ws_col), int(ws.ws_row))
  envSize()

proc platRead*(s: PlatState, buf: pointer, len: int): int =
  ## Reads raw stdin bytes, -1 on error.
  let n = posix.read(0, buf, len)
  int(n)
