mode = ScriptMode.Verbose

packageName   = "snappy"
version       = "0.1.0"
author        = "Andri Lim"
description   = "Nim implementation of snappy compression algorithm"
license       = "MIT"
skipDirs      = @["tests"]

requires "nim >= 0.19.0",
         "faststreams",
         "stew"

task test, "Run all tests":
  exec "nim c --passL:\"-lsnappy -L./tests -lstdc++\" -r tests/test"
  exec "nim c --passL:\"-lsnappy -L./tests -lstdc++\" -d:release -r tests/test"
  exec "nim c --passL:\"-lsnappy -L./tests -lstdc++\" --threads:on -d:release -r tests/test"
