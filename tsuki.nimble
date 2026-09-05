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
skipDirs      = @["build", "doc", "examples", "nimcache", "packages", "tests",
                  "tools"]


# Dependencies

requires "nim >= 2.2.0"

switch("define", "ssl")

const he3Path = "--path:packages/he3/src"

proc prepareBuildDir(directory: string) =
  mkDir("build/" & directory)

proc he3Task(name: string) =
  withDir "packages/he3":
    exec "nimble " & name


task test, "run the debug and release test suites":
  prepareBuildDir("tests")
  exec "nim c -r --threads:on --path:src " & he3Path & " --nimcache:build/nimcache/test-basic --out:build/tests/basic tests/test1.nim"
  exec "nim c -r --threads:on --path:src " & he3Path & " --nimcache:build/nimcache/test-agent --out:build/tests/agent tests/agent/all.nim"
  exec "nim c -r --threads:on --path:src " & he3Path & " --nimcache:build/nimcache/test-codex-local --out:build/tests/codex-local tests/agent/codex_local.nim"
  he3Task("test")

task testFresh, "audit clean-checkout inputs and run the full suite":
  for fixture in ["packages/he3/tests/nim.cfg",
      "packages/he3/tests/corpora/legacy.txt",
      "packages/he3/tests/corpora/kitty.txt",
      "packages/he3/tests/corpora/unicode_grapheme_16.txt"]:
    if not fileExists(fixture):
      raise newException(IOError, "missing test fixture: " & fixture)
  exec "nimble test"

task testProviderLocal, "run the opt-in loopback provider transport fixture":
  prepareBuildDir("tests")
  exec "nim c -r --threads:on --path:src " & he3Path & " --nimcache:build/nimcache/test-provider-local --out:build/tests/provider-local tests/agent/openai_local.nim"

task testCodexLocal, "run the local Codex App Server protocol fixture":
  prepareBuildDir("tests")
  exec "nim c -r --threads:on --path:src " & he3Path & " --nimcache:build/nimcache/test-codex-local --out:build/tests/codex-local tests/agent/codex_local.nim"

task testWindows, "run the platform test suite on a native Windows host":
  he3Task("testWindows")

task lint, "format and check all public Nim modules":
  for directory in ["src", "tests", "examples"]:
    for source in walkDirRec(directory):
      if source.endsWith(".nim"):
        exec "nimpretty --indent:2 " & source
  exec "git diff --exit-code -- src tests examples"
  exec "nim check --threads:on --path:src " & he3Path & " src/tsuki.nim"
  he3Task("lint")

task docs, "build tsuki and he3 API documentation":
  exec "nim doc --threads:on --path:src " & he3Path & " --outdir:doc/htmldocs/product src/tsuki/agent.nim"
  exec "nim doc --path:packages/he3/src --outdir:doc/htmldocs packages/he3/src/he3.nim"
  exec "nim doc --threads:on --path:packages/he3/src --outdir:doc/htmldocs packages/he3/src/he3/agent.nim"

task bench, "run he3 benchmarks":
  he3Task("bench")

task fuzz, "run bounded deterministic fuzz/property smoke tests":
  he3Task("fuzz")

task examples, "compile every public example":
  prepareBuildDir("examples")
  var exampleCount = 0
  for source in walkDirRec("examples"):
    if source.endsWith(".nim"):
      inc exampleCount
  if exampleCount != 3:
    raise newException(IOError,
      "expected exactly three public examples, found " & $exampleCount)
  exec "nim c --threads:on --path:src " & he3Path & " --nimcache:build/nimcache/example-hello --out:build/examples/hello_world examples/hello_world.nim"
  exec "nim c --threads:on --path:src " & he3Path & " --nimcache:build/nimcache/example-counter --out:build/examples/counter examples/counter.nim"
  exec "nim c --threads:on --path:src " & he3Path & " --nimcache:build/nimcache/example-agent --out:build/examples/agent_chat examples/agent_chat.nim"
