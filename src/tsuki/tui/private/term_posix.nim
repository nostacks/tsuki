import std/[posix, termios]

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

proc platSize*(s: PlatState): tuple[w, h: int] =
  ## Returns the terminal size in cells via ioctl, 80x24 as fallback.
  var ws: WinSize
  if ioctl(1, tiocgwinsz, addr ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0:
    (int(ws.ws_col), int(ws.ws_row))
  else:
    (80, 24)

proc platRead*(s: PlatState, buf: pointer, len: int): int =
  ## Reads raw stdin bytes, -1 on error.
  let n = posix.read(0, buf, len)
  int(n)
