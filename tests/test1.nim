import std/[strutils, unittest]
import tsuki
import tsuki/agent

test "product entry point exposes version and CLI parsing":
  check tsukiVersion == "0.1.0"
  let parsed = parseCli(["--new", "workspace"])
  check parsed.error.len == 0
  check parsed.options.newSession
  check parsed.options.workspace == "workspace"

test "chat mode is selectable from the CLI":
  check parseCli(["--chat"]).options.mode == "chat"
  check parseCli(["--mode", "Agent"]).options.mode == "agent"
  check parseCli([]).options.mode == ""
  check parseCli(["--mode", "bogus"]).error.len > 0
  check cliHelp.contains("--chat")

test "the mock mode is removed from the CLI":
  let parsed = parseCli(["--mock"])
  check parsed.error.len > 0
  check not parsed.help

test "phase one defaults are bounded":
  let limits = phase1Limits()
  check limits.maxToolRounds > 0
  check limits.maxImageBytes < limits.maxSessionBytes
