import std/strformat
import tsuki/tui/private/writer

type
  FakeTty* = object
    wr*: Out

proc initFakeTty*(): FakeTty =
  ## Creates a fake tty capturing all writer bytes in memory.
  FakeTty(wr: initFakeOut())

proc bytes*(t: FakeTty): seq[byte] =
  ## Returns every byte written to the fake tty.
  t.wr.fake.bytes

proc writes*(t: FakeTty): int =
  ## Returns the number of write calls issued to the fake tty.
  t.wr.fake.writes

proc clear*(t: var FakeTty) =
  ## Drops all captured bytes and write counts.
  t.wr.fake.bytes.setLen 0
  t.wr.fake.writes = 0

proc check*(cond: bool, name: string) =
  ## Minimal assertion used by every test module.
  if not cond:
    raise newException(AssertionDefect, &"check failed: {name}")
