## Tsuki coding agent entry point.

proc greet*(name = "world"): string =
  "hello, " & name & "!"

when isMainModule:
  echo greet()
