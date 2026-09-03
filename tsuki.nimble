import std/[os, strutils]

# Package

version       = "0.1.0"
author        = "nostacks"
description   = "A fast, tiny, modular coding agent"
license       = "MIT"
srcDir        = "src"
binDir        = "build"
bin           = @["tsuki"]
installExt    = @["nim"]
installFiles  = @["CHANGELOG.md", "LICENSE", "README.md"]
skipDirs      = @["bench", "build", "doc", "examples", "nimcache", "tests",
                  "tools"]


# Dependencies

requires "nim >= 2.2.0"

switch("define", "ssl")

proc prepareBuildDir(directory: string) =
  mkDir("build/" & directory)


task test, "run the debug and release test suites":
  prepareBuildDir("tests")
  exec "nim c -r --threads:on --path:src --nimcache:build/nimcache/test-basic --out:build/tests/basic tests/test1.nim"
  exec "nim c -r --threads:on --path:src --nimcache:build/nimcache/test-agent --out:build/tests/agent tests/agent/all.nim"
  exec "nim c -r --threads:on --path:src --nimcache:build/nimcache/test-codex-local --out:build/tests/codex-local tests/agent/codex_local.nim"
  exec "nim c -r --threads:on --path:src --nimcache:build/nimcache/test-debug --out:build/tests/tui-debug tests/tui/all.nim"
  exec "nim c -r --threads:on -d:release --path:src --nimcache:build/nimcache/test-release --out:build/tests/tui-release tests/tui/all.nim"

task testFresh, "audit clean-checkout inputs and run the full suite":
  for fixture in ["tests/tui/nim.cfg", "tests/tui/corpora/legacy.txt",
      "tests/tui/corpora/kitty.txt",
      "tests/tui/corpora/unicode_grapheme_16.txt"]:
    if not fileExists(fixture):
      raise newException(IOError, "missing test fixture: " & fixture)
  exec "nimble test"

task testProviderLocal, "run the opt-in loopback provider transport fixture":
  prepareBuildDir("tests")
  exec "nim c -r --threads:on --path:src --nimcache:build/nimcache/test-provider-local --out:build/tests/provider-local tests/agent/openai_local.nim"

task testCodexLocal, "run the local Codex App Server protocol fixture":
  prepareBuildDir("tests")
  exec "nim c -r --threads:on --path:src --nimcache:build/nimcache/test-codex-local --out:build/tests/codex-local tests/agent/codex_local.nim"

task testWindows, "run the platform test suite on a native Windows host":
  when defined(windows):
    prepareBuildDir("tests")
    exec "nim c -r --threads:on -d:release --path:src --nimcache:build/nimcache/test-windows --out:build/tests/tui-windows tests/tui/all.nim"
  else:
    echo "testWindows requires a native Windows host"

task lint, "format and check all public Nim modules":
  for directory in ["src", "tests", "examples", "bench"]:
    for source in walkDirRec(directory):
      if source.endsWith(".nim"):
        exec "nimpretty --indent:2 " & source
  exec "git diff --exit-code -- src tests examples bench"
  exec "nim check --threads:on --path:src src/tsuki.nim"
  exec "nim check --threads:on --path:src src/tsuki/tui.nim"
  exec "nim check --threads:on --path:src src/tsuki/tui/agent.nim"
  exec "nim check --threads:on --path:src src/tsuki/tui/expert.nim"

task docs, "build he3 API documentation":
  exec "nim doc --threads:on --path:src --outdir:doc/htmldocs/product src/tsuki/agent.nim"
  exec "nim doc --path:src --outdir:doc/htmldocs src/tsuki/tui.nim"
  exec "nim doc --threads:on --path:src --outdir:doc/htmldocs src/tsuki/tui/agent.nim"

task bench, "run he3 benchmarks":
  prepareBuildDir("bench")
  exec "nim c -r --threads:on -d:release --path:src --nimcache:build/nimcache/bench --out:build/bench/tui bench/tui/bench.nim"

task fuzz, "run bounded deterministic fuzz/property smoke tests":
  prepareBuildDir("tests")
  exec "nim c -r --threads:on -d:release --path:src --nimcache:build/nimcache/fuzz --out:build/tests/fuzz tests/tui/t16safety.nim"

task examples, "compile every public example":
  prepareBuildDir("examples")
  var exampleCount = 0
  for source in walkDirRec("examples"):
    if source.endsWith(".nim"):
      inc exampleCount
  if exampleCount != 3:
    raise newException(IOError,
      "expected exactly three public examples, found " & $exampleCount)
  exec "nim c --threads:on --path:src --nimcache:build/nimcache/example-hello --out:build/examples/hello_world examples/hello_world.nim"
  exec "nim c --threads:on --path:src --nimcache:build/nimcache/example-counter --out:build/examples/counter examples/counter.nim"
  exec "nim c --threads:on --path:src --nimcache:build/nimcache/example-agent --out:build/examples/agent_chat examples/agent_chat.nim"
