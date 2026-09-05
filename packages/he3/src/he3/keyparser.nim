import std/[unicode, monotimes, times]
import event

const
  defaultDeadlineMs* = 50
  defaultMaxSequenceBytes* = 4096
  defaultMaxPasteBytes* = 1_048_576
  maxParameterValue = 1_000_000

type ParseState* = object
  buf: seq[byte]
  t0: MonoTime
  paste: bool
  pasteBuf: string
  pasteTruncated: bool
  altPending: bool
  discardSequence: bool
  maxSequenceBytes*: int
  maxPasteBytes*: int
  kittyFlags*: int
  kittySeen*: bool
  deviceAttributesSeen*: bool

func initParseState*(maxSequenceBytes = defaultMaxSequenceBytes,
    maxPasteBytes = defaultMaxPasteBytes): ParseState =
  ## Creates a bounded parser state. Zero-initialized states use the same
  ## defaults for compatibility.
  ParseState(maxSequenceBytes: max(16, maxSequenceBytes),
    maxPasteBytes: max(1, maxPasteBytes))

func sequenceLimit(state: ParseState): int {.inline.} =
  if state.maxSequenceBytes > 0: state.maxSequenceBytes
  else: defaultMaxSequenceBytes

func pasteLimit(state: ParseState): int {.inline.} =
  if state.maxPasteBytes > 0: state.maxPasteBytes
  else: defaultMaxPasteBytes

func pending*(s: ParseState): int =
  ## Number of buffered bytes waiting for completion.
  s.buf.len

func kittySupported*(s: ParseState): bool =
  ## True after a kitty keyboard query reply with disambiguate support.
  s.kittySeen and (s.kittyFlags and 1) != 0

func deadlineMs*(s: ParseState, now = getMonoTime()): int =
  ## Milliseconds until an incomplete escape sequence must resolve, or -1
  ## when parsing has no active deadline.
  if s.buf.len == 0 or s.paste:
    return -1
  let elapsed = (now - s.t0).inMilliseconds
  max(0, defaultDeadlineMs - int(elapsed))

func keyEvent(code: KeyCode, ch = Rune(0), mods: set[Mod] = {},
    released = false): Event =
  Event(kind: evKey, key: initKey(code, ch, mods, released))

func controlKey(b: byte, mods: set[Mod] = {}): Event =
  case b
  of 0x00: keyEvent(kcChar, Rune(ord('@')), {modCtrl} + mods)
  of 0x01 .. 0x1a:
    keyEvent(kcChar, Rune(ord('a') + int(b) - 1), {modCtrl} + mods)
  of 0x1c: keyEvent(kcChar, Rune(ord('\\')), {modCtrl} + mods)
  of 0x1d: keyEvent(kcChar, Rune(ord(']')), {modCtrl} + mods)
  of 0x1e: keyEvent(kcChar, Rune(ord('^')), {modCtrl} + mods)
  of 0x1f: keyEvent(kcChar, Rune(ord('_')), {modCtrl} + mods)
  else: Event(kind: evNone)

func modSet(v: int): set[Mod] =
  ## Decodes a CSI modifier parameter into modifier flags.
  let m = max(0, v - 1)
  if (m and 1) != 0: result.incl modShift
  if (m and 2) != 0: result.incl modAlt
  if (m and 4) != 0: result.incl modCtrl
  if (m and 8) != 0: result.incl modSuper

func mouseMods(b: int): set[Mod] =
  ## Decodes SGR mouse button byte modifier bits.
  if (b and 4) != 0: result.incl modShift
  if (b and 8) != 0: result.incl modAlt
  if (b and 16) != 0: result.incl modCtrl

proc feedByte(state: var ParseState, b: byte): bool =
  if state.discardSequence:
    if b >= 0x40 and b <= 0x7E:
      state.discardSequence = false
    return false
  if state.buf.len >= state.sequenceLimit:
    state.buf.setLen 0
    state.altPending = false
    state.discardSequence = true
    return false
  state.buf.add b
  if state.buf.len == 1:
    state.t0 = getMonoTime()
  true

proc take(state: var ParseState, n: int) =
  if n >= state.buf.len:
    state.buf.setLen 0
    return
  for i in n ..< state.buf.len:
    state.buf[i - n] = state.buf[i]
  state.buf.setLen(state.buf.len - n)
  state.t0 = getMonoTime()

proc parseRune(data: openArray[byte], outRune: var Rune): int =
  ## Decodes one UTF-8 rune, returning byte length, 0 when incomplete,
  ## -1 when invalid.
  if data.len == 0:
    return 0
  let b0 = data[0]
  if b0 < 0x80:
    outRune = Rune(b0)
    return 1
  var need: int
  var value: uint32
  var minimum: uint32
  if b0 >= 0xC2 and b0 <= 0xDF:
    need = 2
    value = uint32(b0 and 0x1F)
    minimum = 0x80
  elif b0 >= 0xE0 and b0 <= 0xEF:
    need = 3
    value = uint32(b0 and 0x0F)
    minimum = 0x800
  elif b0 >= 0xF0 and b0 <= 0xF4:
    need = 4
    value = uint32(b0 and 0x07)
    minimum = 0x10000
  else:
    return -1
  if data.len < need:
    return 0
  for i in 1 ..< need:
    let b = data[i]
    if b < 0x80 or b > 0xBF:
      return -1
    value = (value shl 6) or uint32(b and 0x3F)
  if value < minimum or value > 0x10FFFF or
      (value >= 0xD800 and value <= 0xDFFF):
    return -1
  outRune = Rune(value)
  need

type
  CsiParam* = tuple[main: int, sub: int]
  CsiParams = object
    count: int
    items: array[8, CsiParam]

func len(params: CsiParams): int {.inline.} = params.count

func `[]`(params: CsiParams, index: int): CsiParam {.inline.} =
  params.items[index]

func add(params: var CsiParams, value: CsiParam) {.inline.} =
  if params.count < params.items.len:
    params.items[params.count] = value
    inc params.count

func parseParams(data: openArray[byte], outHasQ: var bool): CsiParams =
  ## Splits CSI parameters on `;` and `:`; empty fields default to 1.
  var cur: CsiParam = (1, 0)
  var field = 0
  var any = false
  for b in data:
    if b == byte(';'):
      result.add cur
      cur = (1, 0)
      field = 0
      any = false
    elif b == byte(':'):
      field = 1
      any = false
    elif b >= byte('0') and b <= byte('9'):
      let d = int(b - byte('0'))
      if field == 0:
        if cur.main == 1 and not any: cur.main = d
        else: cur.main = min(maxParameterValue, cur.main * 10 + d)
      else:
        cur.sub = min(maxParameterValue, cur.sub * 10 + d)
      any = true
    elif b == byte('?'):
      outHasQ = true
    else:
      discard
  result.add cur

func sgrMouse(final: char, b: int, params: CsiParams): Event =
  ## Builds a mouse event from an SGR sequence.
  let x = if params.len >= 2: params[1].main - 1 else: 0
  let y = if params.len >= 3: params[2].main - 1 else: 0
  let mods = mouseMods(b)
  var action: MouseAction
  var button: int
  if (b and 128) != 0:
    action = maPress
    button = 8 + (b and 3)
  elif (b and 64) != 0:
    action = maScroll
    button = (b - 64) and 3
  elif (b and 3) == 3 and (b and 32) != 0:
    action = maMove
    button = 0
  elif final == 'm':
    action = maRelease
    button = b and 3
  elif (b and 32) != 0:
    action = maDrag
    button = (b - 32) and 3
  else:
    action = maPress
    button = b and 3
  Event(kind: evMouse, mouse: MouseEvent(action: action, button: button,
    x: x, y: y, mods: mods))

func csiEvent(final: char, params: CsiParams, alt: bool): Event =
  ## Builds an event from a complete CSI sequence, evNone when unknown.
  var mods: set[Mod]
  var released = false
  if params.len >= 2:
    mods = modSet(params[1].main)
    released = params[1].sub == 3
  if alt:
    mods.incl modAlt
  case final
  of 'A': keyEvent(kcUp, mods = mods, released = released)
  of 'B': keyEvent(kcDown, mods = mods, released = released)
  of 'C': keyEvent(kcRight, mods = mods, released = released)
  of 'D': keyEvent(kcLeft, mods = mods, released = released)
  of 'H': keyEvent(kcHome, mods = mods, released = released)
  of 'F': keyEvent(kcEnd, mods = mods, released = released)
  of 'Z': keyEvent(kcTab, mods = {modShift})
  of 'I': Event(kind: evFocus, focused: true)
  of 'O': Event(kind: evFocus, focused: false)
  of 'M', 'm': sgrMouse(final, params[0].main, params)
  else:
    if params.len >= 1:
      case params[0].main
      of 1, 7: keyEvent(kcHome, mods = mods, released = released)
      of 2: keyEvent(kcInsert, mods = mods, released = released)
      of 3: keyEvent(kcDelete, mods = mods, released = released)
      of 4, 8: keyEvent(kcEnd, mods = mods, released = released)
      of 5: keyEvent(kcPageUp, mods = mods, released = released)
      of 6: keyEvent(kcPageDown, mods = mods, released = released)
      of 11: keyEvent(kcF1, mods = mods, released = released)
      of 12: keyEvent(kcF2, mods = mods, released = released)
      of 13: keyEvent(kcF3, mods = mods, released = released)
      of 14: keyEvent(kcF4, mods = mods, released = released)
      of 15: keyEvent(kcF5, mods = mods, released = released)
      of 17: keyEvent(kcF6, mods = mods, released = released)
      of 18: keyEvent(kcF7, mods = mods, released = released)
      of 19: keyEvent(kcF8, mods = mods, released = released)
      of 20: keyEvent(kcF9, mods = mods, released = released)
      of 21: keyEvent(kcF10, mods = mods, released = released)
      of 23: keyEvent(kcF11, mods = mods, released = released)
      of 24: keyEvent(kcF12, mods = mods, released = released)
      else: Event(kind: evNone)
    else:
      Event(kind: evNone)

func ss3Event(final: char, alt: bool): Event =
  ## Builds an event from an SS3 sequence.
  var mods: set[Mod]
  if alt:
    mods.incl modAlt
  case final
  of 'A': keyEvent(kcUp, mods = mods)
  of 'B': keyEvent(kcDown, mods = mods)
  of 'C': keyEvent(kcRight, mods = mods)
  of 'D': keyEvent(kcLeft, mods = mods)
  of 'H': keyEvent(kcHome, mods = mods)
  of 'F': keyEvent(kcEnd, mods = mods)
  of 'P': keyEvent(kcF1, mods = mods)
  of 'Q': keyEvent(kcF2, mods = mods)
  of 'R': keyEvent(kcF3, mods = mods)
  of 'S': keyEvent(kcF4, mods = mods)
  else: Event(kind: evNone)

func kittyEvent(code: int, mods: set[Mod], event: int): Event =
  ## Maps a kitty protocol key event. Functional keys live in the private use
  ## area and either map to a named key or are dropped; they never become text.
  let released = event == 3
  case code
  of 27: keyEvent(kcEscape, mods = mods, released = released)
  of 13, 57414: keyEvent(kcEnter, mods = mods, released = released)
  of 9: keyEvent(kcTab, mods = mods, released = released)
  of 127: keyEvent(kcBackspace, mods = mods, released = released)
  of 57358: keyEvent(kcCapsLock, mods = mods, released = released)
  of 57359: keyEvent(kcScrollLock, mods = mods, released = released)
  of 57360: keyEvent(kcNumLock, mods = mods, released = released)
  of 57361: keyEvent(kcPrintScreen, mods = mods, released = released)
  of 57362: keyEvent(kcPause, mods = mods, released = released)
  of 57363: keyEvent(kcMenu, mods = mods, released = released)
  of 57399 .. 57408:
    keyEvent(kcChar, Rune(ord('0') + code - 57399), mods = mods,
      released = released)
  of 57409: keyEvent(kcChar, Rune(ord('.')), mods = mods, released = released)
  of 57410: keyEvent(kcChar, Rune(ord('/')), mods = mods, released = released)
  of 57411: keyEvent(kcChar, Rune(ord('*')), mods = mods, released = released)
  of 57412: keyEvent(kcChar, Rune(ord('-')), mods = mods, released = released)
  of 57413: keyEvent(kcChar, Rune(ord('+')), mods = mods, released = released)
  of 57415: keyEvent(kcChar, Rune(ord('=')), mods = mods, released = released)
  of 57416: keyEvent(kcChar, Rune(ord(',')), mods = mods, released = released)
  of 57417: keyEvent(kcLeft, mods = mods, released = released)
  of 57418: keyEvent(kcRight, mods = mods, released = released)
  of 57419: keyEvent(kcUp, mods = mods, released = released)
  of 57420: keyEvent(kcDown, mods = mods, released = released)
  of 57421: keyEvent(kcPageUp, mods = mods, released = released)
  of 57422: keyEvent(kcPageDown, mods = mods, released = released)
  of 57423: keyEvent(kcHome, mods = mods, released = released)
  of 57424: keyEvent(kcEnd, mods = mods, released = released)
  of 57425: keyEvent(kcInsert, mods = mods, released = released)
  of 57426: keyEvent(kcDelete, mods = mods, released = released)
  of 57428, 57430: keyEvent(kcMediaPlay, mods = mods, released = released)
  of 57429: keyEvent(kcMediaPause, mods = mods, released = released)
  of 57432: keyEvent(kcMediaStop, mods = mods, released = released)
  of 57435: keyEvent(kcMediaNext, mods = mods, released = released)
  of 57436: keyEvent(kcMediaPrev, mods = mods, released = released)
  of 57438: keyEvent(kcMediaVolumeDown, mods = mods, released = released)
  of 57439: keyEvent(kcMediaVolumeUp, mods = mods, released = released)
  of 57440: keyEvent(kcMediaVolumeMute, mods = mods, released = released)
  else:
    if code >= 0x20 and code <= 0x10FFFF and
        not (code >= 0xD800 and code <= 0xDFFF) and
        not (code >= 0xE000 and code <= 0xF8FF):
      keyEvent(kcChar, Rune(code), mods = mods, released = released)
    else:
      Event(kind: evNone)

func isCsiParam(c: byte): bool =
  (c >= byte('0') and c <= byte('9')) or c == byte(';') or c == byte(':') or
    c == byte('?') or c == byte('<') or c == byte('>')

proc parseComplete(state: var ParseState, events: var seq[Event]): bool =
  ## Attempts to consume one complete unit from `state.buf`. Returns true
  ## when bytes were consumed.
  if state.buf.len == 0:
    return false
  let b = state.buf[0]
  if state.paste:
    const pasteEnd = [byte(0x1B), byte('['), byte('2'), byte('0'),
      byte('1'), byte('~')]
    if b == pasteEnd[0]:
      var matches = true
      for index in 0 ..< min(state.buf.len, pasteEnd.len):
        if state.buf[index] != pasteEnd[index]:
          matches = false
          break
      if matches and state.buf.len < pasteEnd.len:
        return false
      if matches:
        state.take(pasteEnd.len)
        state.paste = false
        if state.pasteTruncated:
          state.pasteBuf.add "…"
        events.add Event(kind: evPaste, text: move(state.pasteBuf))
        state.pasteBuf = ""
        state.pasteTruncated = false
        return true
    if state.pasteBuf.len < state.pasteLimit:
      state.pasteBuf.add char(b)
    else:
      state.pasteTruncated = true
    state.take(1)
    return true
  if b == 0x1b:
    if state.buf.len == 1:
      return false
    case state.buf[1]
    of byte('['):
      var i = 2
      while i < state.buf.len and isCsiParam(state.buf[i]):
        inc i
      if i >= state.buf.len:
        return false
      let final = char(state.buf[i])
      case final
      of 'M':
        if i == 2:
          if state.buf.len < 6:
            return false
          let mb = int(state.buf[3]) - 32
          let mx = int(state.buf[4]) - 32
          let my = int(state.buf[5]) - 32
          var action: MouseAction
          var button: int
          if (mb and 128) != 0:
            action = maPress
            button = 8 + (mb and 3)
          elif (mb and 64) != 0:
            action = maScroll
            button = (mb - 64) and 3
          elif (mb and 3) == 3 and (mb and 32) != 0:
            action = maMove
          elif (mb and 32) != 0:
            action = maDrag
            button = (mb - 32) and 3
          else:
            action = maPress
            button = mb and 3
          events.add Event(kind: evMouse, mouse: MouseEvent(action: action,
            button: button, x: mx, y: my, mods: mouseMods(mb)))
          state.take(6)
          return true
        let params = parseParams(state.buf.toOpenArray(2, i - 1),
            state.kittySeen)
        events.add csiEvent(final, params, state.altPending)
        state.altPending = false
        state.take(i + 1)
        return true
      of '~', 'm', 'A', 'B', 'C', 'D', 'H', 'F', 'I', 'O', 'Z':
        var hasQ = false
        let params = parseParams(state.buf.toOpenArray(2, i - 1), hasQ)
        if final == '~' and params.len >= 1 and params[0].main == 200:
          state.paste = true
          state.pasteBuf.setLen 0
          state.pasteTruncated = false
        elif final == '~' and params.len >= 1 and params[0].main == 201:
          state.paste = false
          state.pasteBuf.setLen 0
        else:
          events.add csiEvent(final, params, state.altPending)
        state.altPending = false
        state.take(i + 1)
        return true
      of 'u':
        var hasQ = false
        let params = parseParams(state.buf.toOpenArray(2, i - 1), hasQ)
        if hasQ:
          state.kittySeen = true
          state.kittyFlags = if params.len >= 1: params[0].main else: 0
        elif params.len >= 1:
          let mods = if params.len >= 2: modSet(params[1].main) else: {}
          let event = if params.len >= 2: params[1].sub else: 1
          events.add kittyEvent(params[0].main, mods, event)
        state.take(i + 1)
        return true
      of 'c':
        state.deviceAttributesSeen = true
        state.take(i + 1)
        return true
      else:
        return false
    of byte('O'):
      if state.buf.len < 3:
        return false
      events.add ss3Event(char(state.buf[2]), state.altPending)
      state.altPending = false
      state.take(3)
      return true
    else:
      let r = state.buf[1]
      if r == 0x1b:
        if state.buf.len < 3:
          return false
        if state.buf[2] == byte('[') or state.buf[2] == byte('O'):
          state.take(1)
          state.altPending = true
          return true
        events.add keyEvent(kcEscape, mods = {modAlt})
        state.take(1)
        return true
      if r < 0x80:
        var ev: Event
        case char(r)
        of '\r': ev = keyEvent(kcEnter, mods = {modAlt})
        of '\n': ev = keyEvent(kcChar, Rune(0x0A), {modAlt})
        of '\t': ev = keyEvent(kcTab, mods = {modAlt})
        of chr(0x7f): ev = keyEvent(kcBackspace, mods = {modAlt})
        of chr(0x1b): ev = keyEvent(kcEscape, mods = {modAlt})
        else:
          if r < 0x20:
            ev = controlKey(r, {modAlt})
          else:
            ev = keyEvent(kcChar, Rune(r), {modAlt})
        events.add ev
        state.take(2)
        return true
      var rune: Rune
      let n = parseRune(state.buf[1 ..^ 1], rune)
      if n == 0:
        return false
      if n < 0:
        events.add keyEvent(kcEscape)
        state.take(1)
        return true
      events.add keyEvent(kcChar, rune, {modAlt})
      state.take(n + 1)
      return true
  if b < 0x20:
    var ev: Event
    case char(b)
    of '\t': ev = keyEvent(kcTab)
    of '\r': ev = keyEvent(kcEnter)
    of '\n': ev = keyEvent(kcChar, Rune(0x0A))
    else:
      ev = controlKey(b)
    events.add ev
    state.take(1)
    return true
  if b == 0x7f:
    events.add keyEvent(kcBackspace)
    state.take(1)
    return true
  var rune: Rune
  let n = parseRune(state.buf, rune)
  if n == 0:
    return false
  if n < 0:
    state.take(1)
    return true
  events.add keyEvent(kcChar, rune)
  state.take(n)
  return true

proc parse*(state: var ParseState, chunk: openArray[byte],
    events: var seq[Event]) =
  ## Feeds `chunk` into the parser state machine and appends complete
  ## events. Incomplete sequences stay buffered until completion or
  ## `checkDeadline`.
  for b in chunk:
    if state.feedByte(b):
      while state.parseComplete(events):
        discard

proc checkDeadline*(state: var ParseState, events: var seq[Event],
    now: MonoTime) =
  ## Resolves an incomplete sequence after the deadline: a lone ESC becomes
  ## an Escape key; garbage is dropped.
  if state.buf.len == 0 or state.paste:
    return
  if (now - state.t0).inMilliseconds < defaultDeadlineMs:
    return
  if state.buf.len == 1 and state.buf[0] == 0x1b:
    events.add keyEvent(kcEscape)
    state.take(1)
  elif state.buf.len >= 2 and state.buf[0] == 0x1b and state.buf[1] == 0x1b:
    events.add keyEvent(kcEscape)
    state.take(1)
  else:
    state.buf.setLen 0
