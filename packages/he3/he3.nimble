import std/[os, strutils]

# Package

version       = "0.1.0"
author        = "nostacks"
description   = "A fast, tiny terminal UI framework"
license       = "MIT"
srcDir        = "src"
skipDirs      = @["bench", "build", "nimcache", "tests"]


# Dependencies

requires "nim >= 2.2.0"

proc prepareBuildDir(directory: string) =
  mkDir("build/" & directory)


task test, "run the debug and release test suites":
  prepareBuildDir("tests")
  exec "nim c -r --threads:on --path:src --nimcache:build/nimcache/test-debug --out:build/tests/debug tests/all.nim"
  exec "nim c -r --threads:on -d:release --path:src --nimcache:build/nimcache/test-release --out:build/tests/release tests/all.nim"

task testWindows, "run the platform test suite on a native Windows host":
  when defined(windows):
    prepareBuildDir("tests")
    exec "nim c -r --threads:on -d:release --path:src --nimcache:build/nimcache/test-windows --out:build/tests/windows tests/all.nim"
  else:
    echo "testWindows requires a native Windows host"

task fuzz, "run bounded deterministic fuzz/property smoke tests":
  prepareBuildDir("tests")
  exec "nim c -r --threads:on -d:release --path:src --nimcache:build/nimcache/fuzz --out:build/tests/fuzz tests/t16safety.nim"

task bench, "run he3 benchmarks":
  prepareBuildDir("bench")
  exec "nim c -r --threads:on -d:release -d:nimAllocStats --path:src --nimcache:build/nimcache/bench --out:build/bench/he3 bench/bench.nim"

task docs, "build he3 API documentation":
  exec "nim doc --path:src --outdir:build/htmldocs src/he3.nim"
  exec "nim doc --threads:on --path:src --outdir:build/htmldocs src/he3/agent.nim"

task lint, "format and check all public Nim modules":
  for directory in ["src", "tests", "bench"]:
    for source in walkDirRec(directory):
      if source.endsWith(".nim"):
        exec "nimpretty --indent:2 " & source
  exec "git diff --exit-code -- src tests bench"
  exec "nim check --threads:on --path:src src/he3.nim"
  exec "nim check --threads:on --path:src src/he3/agent.nim"
  exec "nim check --threads:on --path:src src/he3/expert.nim"
