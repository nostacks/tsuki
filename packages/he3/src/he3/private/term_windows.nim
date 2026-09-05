import std/winlean

type PlatState* = object
  hIn: Handle
  hOut: Handle
  origIn: DWORD
  origOut: DWORD
  rawApplied: bool

type
  Short = int16
  Coord = object
    x: Short
    y: Short
  SmallRect = object
    left: Short
    top: Short
    right: Short
    bottom: Short
  ConsoleScreenBufferInfo = object
    dwSize: Coord
    dwCursorPos: Coord
    wAttributes: int16
    srWindow: SmallRect
    dwMaximumWindowSize: Coord

const
  ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
  ENABLE_LINE_INPUT = 0x0002
  ENABLE_ECHO_INPUT = 0x0004
  ENABLE_PROCESSED_INPUT = 0x0001
  ENABLE_WINDOW_INPUT = 0x0008
  ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200
  STD_INPUT_HANDLE = -10
  STD_OUTPUT_HANDLE = -11

proc getStdHandle(nStdHandle: DWORD): Handle {.
  importc: "GetStdHandle", stdcall, dynlib: "kernel32".}

proc getConsoleMode(handle: Handle, mode: ptr DWORD): WINBOOL {.
  importc: "GetConsoleMode", stdcall, dynlib: "kernel32".}

proc setConsoleMode(handle: Handle, mode: DWORD): WINBOOL {.
  importc: "SetConsoleMode", stdcall, dynlib: "kernel32".}

proc getConsoleScreenBufferInfo(handle: Handle,
    info: ptr ConsoleScreenBufferInfo): WINBOOL {.
  importc: "GetConsoleScreenBufferInfo", stdcall, dynlib: "kernel32".}

proc platRawEnable*(s: var PlatState): bool =
  ## Switches the console into raw input and VT output mode, saving the
  ## original console modes.
  s.hIn = getStdHandle(DWORD(STD_INPUT_HANDLE))
  s.hOut = getStdHandle(DWORD(STD_OUTPUT_HANDLE))
  if s.hIn == 0 or s.hOut == 0:
    return false
  var mode: DWORD = 0
  if getConsoleMode(s.hIn, addr mode) == 0:
    return false
  s.origIn = mode
  mode = mode and not DWORD(ENABLE_LINE_INPUT or ENABLE_ECHO_INPUT or
    ENABLE_PROCESSED_INPUT)
  mode = mode or DWORD(ENABLE_WINDOW_INPUT or ENABLE_VIRTUAL_TERMINAL_INPUT)
  if setConsoleMode(s.hIn, mode) == 0:
    return false
  mode = 0
  if getConsoleMode(s.hOut, addr mode) == 0:
    discard setConsoleMode(s.hIn, s.origIn)
    return false
  s.origOut = mode
  mode = mode or ENABLE_VIRTUAL_TERMINAL_PROCESSING
  if setConsoleMode(s.hOut, mode) == 0:
    discard setConsoleMode(s.hIn, s.origIn)
    return false
  s.rawApplied = true

proc platRawDisable*(s: var PlatState) =
  ## Restores the original console modes.
  if s.rawApplied:
    discard setConsoleMode(s.hIn, s.origIn)
    discard setConsoleMode(s.hOut, s.origOut)
    s.rawApplied = false

proc platSize*(s: PlatState): tuple[w, h: int] =
  ## Returns the console size in cells, 80x24 as fallback.
  var info: ConsoleScreenBufferInfo
  if getConsoleScreenBufferInfo(s.hOut, addr info) != 0:
    let w = int(info.srWindow.right) - int(info.srWindow.left) + 1
    let h = int(info.srWindow.bottom) - int(info.srWindow.top) + 1
    if w > 0 and h > 0:
      return (w, h)
  (80, 24)

proc platRead*(s: PlatState, buf: pointer, len: int): int =
  ## Reads raw console input bytes, -1 on error.
  var n: DWORD = 0
  if readFile(s.hIn, buf, DWORD(len), addr n, nil) == 0:
    return -1
  int(n)

func platInputHandle*(s: PlatState): Handle =
  ## Exposes the owned console input handle to the reactor wait set.
  s.hIn
