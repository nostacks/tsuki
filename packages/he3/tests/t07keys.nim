import std/[strutils, unicode, monotimes, times]
import common
import he3/event
import he3/keyparser

func keyName(code: KeyCode): string =
  case code
  of kcEscape: "esc"
  of kcBackspace: "bspace"
  of kcInsert: "ins"
  of kcDelete: "del"
  of kcPageUp: "pgup"
  of kcPageDown: "pgdn"
  of kcChar: ""
  else:
    var n = $code
    n.removePrefix("kc")
    n.toLowerAscii

func eventRepr(e: Event): string =
  ## Canonical single-line repr used by the corpus files.
  result = ""
  case e.kind
  of evNone: result = "none"
  of evResize: result = "resize:" & $e.width & "x" & $e.height
  of evPaste:
    result = "paste:" & e.text.replace("\x1b", "\\e").replace("\n", "\\n")
      .replace("\r", "\\r")
  of evTimer: result = "timer:" & $e.timerId
  of evFocus: result = "focus:" & $e.focused
  of evUser: result = "user:" & e.name & ":" & e.payload
  of evMouse:
    let m = e.mouse
    let actionName = case m.action
      of maPress: "press"
      of maRelease: "release"
      of maDrag: "drag"
      of maMove: "move"
      of maScroll: "scroll"
    result = "mouse:" & actionName & ":" & $m.button & ":" &
      $m.x & ":" & $m.y
    var mods: seq[string]
    if modShift in m.mods: mods.add "shift"
    if modAlt in m.mods: mods.add "alt"
    if modCtrl in m.mods: mods.add "ctrl"
    for mo in mods:
      result.add ":" & mo
  of evKey:
    let k = e.key
    var parts: seq[string]
    if modCtrl in k.mods: parts.add "ctrl"
    if modAlt in k.mods: parts.add "alt"
    if modShift in k.mods: parts.add "shift"
    if modSuper in k.mods: parts.add "super"
    if k.released: parts.add "release"
    let name = if k.code == kcChar: $k.char else: keyName(k.code)
    result = "key:" & parts.join("+") & (if parts.len > 0: "+" else: "") & name

proc runCorpusFile(path: string) =
  var lineNo = 0
  var ran = 0
  for line in path.lines:
    inc lineNo
    if line.len == 0 or line.startsWith("#"):
      continue
    let parts = line.split('|')
    check parts.len == 3, "corpus line " & $lineNo & " malformed"
    let chunks = parts[1].split('/')
    let expected = parts[2]
    var st: ParseState
    var events: seq[Event]
    var now = getMonoTime()
    for c in chunks:
      var chunk: seq[byte]
      var i = 0
      while i + 1 < c.len:
        chunk.add byte(parseHexInt(c[i ..< i + 2]))
        i += 2
      st.parse(chunk, events)
    for i in 0 ..< 3:
      let before = events.len
      st.checkDeadline(events, now + initDuration(seconds = 100 * (i + 1)))
      if events.len == before:
        break
    var got: seq[string]
    for e in events:
      if e.kind != evNone:
        got.add e.eventRepr
    let gotStr = if got.len == 0: "none" else: got.join(" ")
    check gotStr == expected, "corpus line " & $lineNo & " (" &
      parts[0] & ") got [" & got.join(" ") & "] want [" & expected & "]"
    inc ran
  check ran >= 150, "corpus has at least 150 lines"

proc testHostileInput =
  var invalid: ParseState
  var events: seq[Event]
  invalid.parse([byte(0xC0), byte(0xAF), byte('x')], events)
  check events.len == 1 and events[0].key.isChar('x'),
    "overlong UTF-8 is dropped without hiding later input"

  var bounded = initParseState(maxSequenceBytes = 16, maxPasteBytes = 4)
  var huge = @[byte(0x1B), byte('[')]
  for unused in 0 ..< 1000: huge.add byte('9')
  huge.add byte('A')
  bounded.parse(huge, events)
  check bounded.pending == 0,
    "an unterminated control sequence cannot grow parser state without bound"

  events.setLen 0
  let pasteChunks = ["\e[200~abcdef\e[20", "1~"]
  for chunk in pasteChunks:
    bounded.parse(chunk.toOpenArrayByte(0, chunk.len - 1), events)
  check events.len == 1 and events[0].kind == evPaste and
    events[0].text == "abcd…",
    "split paste terminators work and pasted bytes stay bounded"

proc main =
  runCorpusFile("tests/corpora/legacy.txt")
  testHostileInput()
  echo "keys ok"

main()
