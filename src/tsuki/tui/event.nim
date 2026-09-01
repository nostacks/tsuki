import std/[monotimes, times, unicode]

type
  KeyCode* = enum
    kcNone
    kcChar
    kcEnter
    kcEscape
    kcTab
    kcBackspace
    kcDelete
    kcInsert
    kcHome
    kcEnd
    kcPageUp
    kcPageDown
    kcUp
    kcDown
    kcLeft
    kcRight
    kcF1
    kcF2
    kcF3
    kcF4
    kcF5
    kcF6
    kcF7
    kcF8
    kcF9
    kcF10
    kcF11
    kcF12
    kcCapsLock
    kcScrollLock
    kcNumLock
    kcPrintScreen
    kcPause
    kcMenu
    kcMediaPlay
    kcMediaPause
    kcMediaStop
    kcMediaPrev
    kcMediaNext
    kcMediaVolumeUp
    kcMediaVolumeDown
    kcMediaVolumeMute
    kcMediaEject
  Mod* = enum
    modShift
    modCtrl
    modAlt
    modSuper
    modHyper
    modMeta
    modCapsLock
    modNumLock
  Key* = object
    code*: KeyCode
    char*: Rune
    mods*: set[Mod]
    released*: bool
  MouseAction* = enum
    maPress
    maRelease
    maDrag
    maMove
    maScroll
  MouseEvent* = object
    action*: MouseAction
    button*: range[0..11]
    x*: int
    y*: int
    mods*: set[Mod]
  MouseClickTracker* = object
    ## Small application-owned state used to recognize deliberate double-clicks.
    armed: bool
    button: int
    x: int
    y: int
    at: MonoTime
  EventKind* = enum
    evNone
    evKey
    evMouse
    evResize
    evPaste
    evTimer
    evFocus
    evUser
  Event* = object
    case kind*: EventKind
    of evNone:
      discard
    of evKey:
      key*: Key
    of evMouse:
      mouse*: MouseEvent
    of evResize:
      width*, height*: int
    of evPaste:
      text*: string
    of evTimer:
      timerId*: uint64
    of evFocus:
      focused*: bool
    of evUser:
      name*: string
      payload*: string

func `==`*(a, b: Key): bool =
  ## Compares two keys field by field.
  a.code == b.code and a.char == b.char and a.mods == b.mods and
    a.released == b.released

func `==`*(a, b: MouseEvent): bool =
  ## Compares two mouse events field by field.
  a.action == b.action and a.button == b.button and a.x == b.x and
    a.y == b.y and a.mods == b.mods

func `==`*(a, b: Event): bool =
  ## Compares two events by kind and payload.
  if a.kind != b.kind:
    return false
  case a.kind
  of evNone: true
  of evKey: a.key == b.key
  of evMouse: a.mouse == b.mouse
  of evResize: a.width == b.width and a.height == b.height
  of evPaste: a.text == b.text
  of evTimer: a.timerId == b.timerId
  of evFocus: a.focused == b.focused
  of evUser: a.name == b.name and a.payload == b.payload

func initKey*(code: KeyCode, char = Rune(0), mods: set[Mod] = {},
    released = false): Key =
  ## Creates a key event payload.
  Key(code: code, char: char, mods: mods, released: released)

func isChar*(key: Key, value: char, mods: set[Mod] = {}): bool =
  ## Matches a character key and exact modifier set.
  key.code == kcChar and key.char == Rune(ord(value)) and key.mods == mods and
    not key.released

func isChar*(key: Key, value: Rune, mods: set[Mod] = {}): bool =
  ## Matches a Unicode character key and exact modifier set.
  key.code == kcChar and key.char == value and key.mods == mods and
    not key.released

func isKey*(key: Key, code: KeyCode, mods: set[Mod] = {}): bool =
  ## Matches a named key and exact modifier set.
  key.code == code and key.mods == mods and not key.released

func isQuit*(event: Event): bool =
  ## Matches Escape, Ctrl-C, or Ctrl-Q using standard terminal conventions.
  event.kind == evKey and (event.key.isKey(kcEscape) or
    event.key.isChar('c', {modCtrl}) or event.key.isChar('q', {modCtrl}))

func isSubmit*(event: Event): bool =
  ## Matches an unmodified Enter key press.
  event.kind == evKey and event.key.isKey(kcEnter)

func isCancel*(event: Event): bool =
  ## Matches Escape or Ctrl-C.
  event.kind == evKey and (event.key.isKey(kcEscape) or
    event.key.isChar('c', {modCtrl}))

func isSuspend*(event: Event): bool =
  ## Matches the conventional Ctrl-Z suspend request.
  event.kind == evKey and event.key.isChar('z', {modCtrl})

func isMouse*(event: Event, action: MouseAction,
    button = -1): bool =
  ## Matches a mouse action and, when non-negative, an exact button.
  event.kind == evMouse and event.mouse.action == action and
    (button < 0 or int(event.mouse.button) == button)

func isClick*(event: Event, button = 0): bool =
  ## Matches a primary press by default. Release remains separately matchable.
  event.isMouse(maPress, button)

func isDrag*(event: Event, button = 0): bool =
  ## Matches a drag for the requested button.
  event.isMouse(maDrag, button)

func isHover*(event: Event): bool =
  ## Matches pointer motion without an active drag.
  event.isMouse(maMove)

func wheelDelta*(event: Event): int =
  ## Returns +1 for wheel-up/left and -1 for wheel-down/right, or zero.
  if event.kind != evMouse or event.mouse.action != maScroll:
    return 0
  if event.mouse.button mod 2 == 0: 1 else: -1

proc isDoubleClick*(tracker: var MouseClickTracker, event: Event,
    now = getMonoTime(), maxIntervalMs = 500): bool =
  ## Recognizes two presses at the same cell/button within a bounded interval.
  if event.kind != evMouse or event.mouse.action != maPress:
    return false
  result = tracker.armed and tracker.button == int(event.mouse.button) and
    tracker.x == event.mouse.x and tracker.y == event.mouse.y and
    (now - tracker.at).inMilliseconds <= max(0, maxIntervalMs)
  tracker.armed = not result
  tracker.button = int(event.mouse.button)
  tracker.x = event.mouse.x
  tracker.y = event.mouse.y
  tracker.at = now

func userEvent*(name: string, payload = ""): Event =
  ## Creates an application-defined event suitable for thread-safe posting.
  Event(kind: evUser, name: name, payload: payload)
