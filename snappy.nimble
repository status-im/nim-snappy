packageName   = "snappy"
version       = "0.1.0"
author        = "Andri Lim"
description   = "Nim implementation of snappy compression algorithm"
license       = "MIT"
skipDirs      = @["tests"]

requires: "nim >= 0.19.0"

task test, "Run all tests":
  exec "nim c tests/test"
  exec "nim c -d:release tests/test"
