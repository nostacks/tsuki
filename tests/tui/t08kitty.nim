import std/[strutils, unicode]
import common
import tsuki/tui/event
import tsuki/tui/keyparser
import tsuki/tui/ui

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
  var ran = 0
  for line in path.lines:
    if line.len == 0 or line.startsWith("#"):
      continue
    let parts = line.split('|')
    check parts.len == 3, "corpus line malformed"
    var st: ParseState
    var events: seq[Event]
    var chunk: seq[byte]
    var i = 0
    let c = parts[1]
    while i + 1 < c.len:
      chunk.add byte(parseHexInt(c[i ..< i + 2]))
      i += 2
    st.parse(chunk, events)
    for e in events:
      if e.kind != evNone:
        check e.eventRepr == parts[2], parts[0] & ": got [" &
          e.eventRepr & "] want [" & parts[2] & "]"
    inc ran
  check ran >= 25, "kitty corpus has enough lines"

proc testProbeSequences =
  var t = initFakeTty()
  var ui = initUiWith(t.wr)
  var probe: seq[byte]
  for ch in "\x1b[?65u":
    probe.add byte(ch)
  var probeEvents: seq[Event]
  keyparser.parse(ui.state, probe, probeEvents)
  check ui.state.kittySupported, "kitty detected with disambiguate"
  ui.kittyEnable()
  check cast[string](t.bytes).contains("\x1b[>1u"), "enable sequence sent"
  ui.leave()
  check cast[string](t.bytes).contains("\x1b[<u"), "disable on teardown"

  var t2 = initFakeTty()
  var ui2 = initUiWith(t2.wr)
  var probe2: seq[byte]
  for ch in "\x1b[?0u":
    probe2.add byte(ch)
  var probeEvents2: seq[Event]
  keyparser.parse(ui2.state, probe2, probeEvents2)
  check not ui2.state.kittySupported, "flags 0 not supported"
  ui2.leave()
  check not cast[string](t2.bytes).contains("\x1b[>1u"),
    "no enable on unsupported"

proc main =
  runCorpusFile("tests/tui/corpora/kitty.txt")
  testProbeSequences()
  echo "kitty ok"

main()
