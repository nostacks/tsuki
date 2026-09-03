import std/unittest
import tsuki
import tsuki/agent

test "product entry point exposes version and CLI parsing":
  check tsukiVersion == "0.1.0"
  let parsed = parseCli(["--new", "workspace"])
  check parsed.error.len == 0
  check parsed.options.newSession
  check parsed.options.workspace == "workspace"

test "the mock mode is removed from the CLI":
  let parsed = parseCli(["--mock"])
  check parsed.error.len > 0
  check not parsed.help

test "phase one defaults are bounded":
  let limits = phase1Limits()
  check limits.maxToolRounds > 0
  check limits.maxImageBytes < limits.maxSessionBytes
