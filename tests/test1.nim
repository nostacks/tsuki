import std/unittest
import tsuki

test "greet":
  check greet() == "hello, world!"
  check greet("tsuki") == "hello, tsuki!"
