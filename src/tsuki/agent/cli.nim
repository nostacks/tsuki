## Minimal side-effect-free Phase 1 command-line parser.

import std/strutils
import config, types

type CliParseResult* = object
  options*: CliOverrides
  help*: bool
  version*: bool
  error*: string

proc parseCli*(arguments: openArray[string]): CliParseResult =
  var index = 0
  while index < arguments.len:
    let argument = arguments[index]
    template takeValue(field: untyped, label: string) =
      if index + 1 >= arguments.len:
        result.error = label & " requires a value"
        return
      inc index
      field = arguments[index]
    case argument
    of "-h", "--help": result.help = true
    of "--version": result.version = true
    of "--new": result.options.newSession = true
    of "--chat": result.options.mode = "chat"
    of "--mode":
      var value: string
      takeValue(value, argument)
      let mode = value.toLowerAscii
      if mode notin ["agent", "chat"]:
        result.error = "unknown mode: " & value.safeDisplay(256) &
          " (use agent or chat)"
        return
      result.options.mode = mode
    of "--workspace", "-C":
      takeValue(result.options.workspace, argument)
    of "--config":
      takeValue(result.options.configPath, argument)
    of "--data-dir":
      takeValue(result.options.dataDir, argument)
    of "--provider":
      var value: string
      takeValue(value, argument)
      result.options.providerId = ProviderId(value.safeId())
    of "--model":
      var value: string
      takeValue(value, argument)
      result.options.modelId = ModelId(value.safeDisplay(1024))
    of "--base-url":
      takeValue(result.options.baseUrl, argument)
    of "--credential-env":
      takeValue(result.options.credentialEnv, argument)
    of "--session":
      var value: string
      takeValue(value, argument)
      result.options.sessionId = SessionId(value.safeId())
    else:
      if argument.startsWith("-"):
        result.error = "unknown option: " & argument.safeDisplay(256)
        return
      if result.options.workspace.len > 0:
        result.error = "only one workspace path may be supplied"
        return
      result.options.workspace = argument
    inc index

const cliHelp* = """Usage: tsuki [options] [workspace]

Options:
  -C, --workspace <path>      Workspace root (default: current directory)
  --new                       Start a new session
  --chat                      Chat or plan without reading the workspace
  --mode <agent|chat>         Set the session mode explicitly
  --session <id>              Resume an exact session
  --provider <id>             Select a configured provider
  --model <id>                Select a model
  --config <path>             Load a specific config file
  --data-dir <path>           Override the per-user data directory
  --base-url <url>            Override the selected provider base URL
  --credential-env <name>     Override its credential environment variable
  -h, --help                  Show this help
  --version                   Show the version

Credentials are read only from the configured environment variable.
"""
