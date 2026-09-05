import std/[monotimes, os, strutils, times]
import common
import he3
import he3/keyparser
import he3/private/writer
import he3/diff

when defined(posix):
  import std/posix
  import pty

proc parseAll(bytes: string): seq[Event] =
  var state = initParseState()
  state.parse(bytes.toOpenArrayByte(0, bytes.len - 1), result)

proc testControlKeys =
  check parseAll("\x1c")[0].key.isChar('\\', {modCtrl}), "ctrl backslash"
  check parseAll("\x1d")[0].key.isChar(']', {modCtrl}), "ctrl right bracket"
  check parseAll("\x1e")[0].key.isChar('^', {modCtrl}), "ctrl caret"
  check parseAll("\x1f")[0].key.isChar('_', {modCtrl}), "ctrl underscore"
  check parseAll("\x00")[0].key.isChar('@', {modCtrl}), "ctrl at"
  check parseAll("\x1b\x1c")[0].key.isChar('\\', {modAlt, modCtrl}),
    "alt ctrl backslash"

proc testEscapeDeadline =
  var state = initParseState()
  var events: seq[Event]
  state.parse([byte(0x1b)], events)
  let start = getMonoTime()
  check state.deadlineMs(start) <= defaultDeadlineMs and
    state.deadlineMs(start) > 0, "a lone escape arms the deadline"
  state.checkDeadline(events, start + initDuration(milliseconds = 10))
  check events.len == 0, "the escape waits for a possible sequence"
  let due = start + initDuration(milliseconds = defaultDeadlineMs + 1)
  check state.deadlineMs(due) == 0, "deadline reaches zero"
  state.checkDeadline(events, due)
  check events.len == 1 and events[0].key.isKey(kcEscape),
    "a zero deadline resolves the escape instead of spinning"
  check state.deadlineMs(due) == -1, "no deadline remains afterwards"

proc testKittyFunctionalKeys =
  let shift = parseAll("\x1b[57441u")
  check shift.len == 1 and shift[0].kind == evNone,
    "a bare modifier press never becomes text"
  let f13 = parseAll("\x1b[57376u")
  check f13.len == 1 and f13[0].kind == evNone,
    "an unmapped functional key never becomes text"
  check parseAll("\x1b[57399u")[0].key.isChar('0'), "keypad digits are text"
  check parseAll("\x1b[57414u")[0].key.isKey(kcEnter), "keypad enter"

proc testDeviceAttributes =
  var state = initParseState()
  var events: seq[Event]
  let reply = "\x1b[?62;22c"
  state.parse(reply.toOpenArrayByte(0, reply.len - 1), events)
  check state.deviceAttributesSeen and events.len == 0,
    "a primary device attributes reply is consumed silently and recorded"

proc testGraphemeSpans =
  let samples = ["", "a", "abc", "\r\n", "éx", "你好世界",
    "👨‍👩‍👧‍👦 flags 🇯🇵🇺🇸", "한국어", "a\tb\nc",
    "क्षि", "\x7fx\x01"]
  for sample in samples:
    var viaSpans: seq[string]
    for span in sample.graphemeSpans:
      viaSpans.add sample[span]
    var viaStrings: seq[string]
    for cluster in sample.graphemes:
      viaStrings.add cluster
    check viaSpans == viaStrings, "span iteration matches cluster strings"
    var joined = ""
    for part in viaSpans: joined.add part
    check joined == sample, "spans cover every byte exactly once"
    check sample.textWidth == sample.cellWidth,
      "textWidth agrees with the allocating measurement"
  check "\r\n".textWidth == 0 and "é".textWidth == 1, "widths"

proc testSanitizeFastPath =
  check "plain text\twith\ntabs".isSanitized, "clean text needs no copy"
  check "你好 é 👍".isSanitized, "clean multibyte text needs no copy"
  check not "esc\x1b[31m".isSanitized, "escape forces sanitizing"
  check not "cr\r\n".isSanitized, "carriage return forces normalization"
  check not "\xC0\xAF".isSanitized, "invalid UTF-8 forces sanitizing"
  check not "‮text".isSanitized, "bidi override forces sanitizing"
  check not "abc".isSanitized(plainTextPolicy(maxBytes = 2)),
    "byte limits force truncation"
  check not "abc".isSanitized(plainTextPolicy(maxCodepoints = 3)),
    "code point limits force truncation"
  check not "a\tb".isSanitized(TextPolicy(kind: tpkPlain, allowNewlines: true,
    allowTabs: false)), "policy without tabs sanitizes tabs"
  for sample in ["ok", "\x1bx", "a\rb", "\xffz", "你́"]:
    let expected = sanitizeText(sample)
    check sanitizeText(sample) == expected, "sanitizer stays deterministic"
    if sample.isSanitized:
      check expected == sample, "fast path returns identical text"

proc testOverlayGlyphs =
  var destination = initBuffer(10, 2)
  destination.writeStr(0, 0, "ééé")
  var source = initBuffer(5, 2)
  source.writeStr(0, 0, "👨‍👩‍👧")
  source.writeStr(0, 1, "é你")
  destination.overlay(source, 3, 0)
  var expected = initBuffer(10, 2)
  expected.writeStr(0, 0, "ééé")
  expected.writeStr(3, 0, "👨‍👩‍👧")
  expected.writeStr(3, 1, "é你")
  check destination == expected, "overlay reproduces exact cluster bytes"
  check destination.checkInvariants, "overlay keeps invariants"

proc testDiffRowTail =
  var previous = initBuffer(6, 1)
  previous.writeStr(0, 0, "abcdef")
  var next = initBuffer(6, 1)
  next.writeStr(0, 0, "ab")
  var output = initFakeOut()
  output.curValid = true
  diffInto(previous, next, output)
  check cast[string](output.fake.bytes) == "\x1b[1;3H\x1b[K",
    "a cleared tail is one erase-to-end-of-line"
  var same = initBuffer(6, 1)
  same.writeStr(0, 0, "ab")
  output.fake.bytes.setLen 0
  let writes = output.fake.writes
  diffInto(next, same, output)
  check output.fake.writes == writes, "identical frames write nothing"

proc testSyncOutput =
  var output = initFakeOut()
  output.syncOutput = true
  var buffer = initBuffer(3, 1)
  buffer.writeStr(0, 0, "x")
  output.flushFull(buffer)
  let bytes = cast[string](output.fake.bytes)
  check bytes.len > 16 and bytes[0 ..< 8] == "\x1b[?2026h" and
    bytes[^8 .. ^1] == "\x1b[?2026l",
    "synchronized output wraps a frame when enabled"
  output.fake.bytes.setLen 0
  let writes = output.fake.writes
  var same = buffer
  diffInto(buffer, same, output)
  check output.fake.writes == writes,
    "an empty synchronized frame writes nothing"

proc testRedrawDeadlines =
  var opened = openTui(tuiOptions(mode = tmHeadless))
  check opened.ok, "headless app opens"
  var app = move(opened.value)
  app.draw proc (frame: var Frame) = discard
  let start = getMonoTime()
  app.apply(redrawAt(start + initDuration(milliseconds = 400)))
  app.apply(redrawAt(start + initDuration(milliseconds = 15)))
  let event = app.wait()
  let elapsed = (getMonoTime() - start).inMilliseconds
  check event.kind == evNone and app.dirty and elapsed < 300,
    "the earliest requested deadline wins and marks the frame dirty"
  app.draw proc (frame: var Frame) = discard
  check not app.dirty, "drawing clears the invalidation"
  let later = app.wait()
  let laterElapsed = (getMonoTime() - start).inMilliseconds
  check later.kind == evNone and app.dirty and laterElapsed >= 380,
    "the later deadline is re-armed after the earlier frame"
  app.apply(quitTui())
  check not app.running, "quit stops the loop"
  app.close()

when defined(posix):
  proc eofChild() =
    discard signal(SIGHUP, SIG_IGN)
    let outcome = runTui(proc (frame: var Frame) =
      frame.write(0, 0, "waiting"))
    if outcome.ok: quit(0) else: quit(3)

  proc testInputEof =
    let (master, pid) = spawnPty(eofChild)
    var buf: array[4096, byte]
    var seen = ""
    let deadline = getMonoTime() + initDuration(seconds = 5)
    while "waiting" notin seen and getMonoTime() < deadline:
      var fds = [TPollfd(fd: master, events: cshort(POLLIN), revents: 0)]
      if posix.poll(addr fds[0], Tnfds(1), 50) > 0:
        let n = read(master, addr buf[0], buf.len)
        if n <= 0: break
        for i in 0 ..< int(n): seen.add char(buf[i])
    check "waiting" in seen, "child drew its first frame"
    discard close(master)
    var status: cint
    var exited = false
    while getMonoTime() < deadline:
      if waitpid(pid, status, WNOHANG) == pid:
        exited = true
        break
      sleep(10)
    if not exited:
      discard kill(pid, SIGKILL)
      discard waitpid(pid, status, cint(0))
    check exited and WIFEXITED(status) and WEXITSTATUS(status) == 0,
      "losing the terminal ends the run loop instead of spinning"

proc main =
  testControlKeys()
  testEscapeDeadline()
  testKittyFunctionalKeys()
  testDeviceAttributes()
  testGraphemeSpans()
  testSanitizeFastPath()
  testOverlayGlyphs()
  testDiffRowTail()
  testSyncOutput()
  testRedrawDeadlines()
  when defined(posix):
    testInputEof()
  echo "hardening ok"

main()
