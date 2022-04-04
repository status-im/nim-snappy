mode = ScriptMode.Verbose

packageName   = "snappy"
version       = "0.1.0"
author        = "Andri Lim"
description   = "Nim implementation of snappy compression algorithm"
license       = "MIT"
skipDirs      = @["tests"]

requires "nim >= 1.2.0",
         "faststreams",
         "unittest2",
         "stew"

### Helper functions
proc test(args, path: string) =
  if not dirExists "build":
    mkDir "build"

  exec "nim " & getEnv("TEST_LANG", "c") & " " & getEnv("NIMFLAGS") & " " & args &
    " --skipParentCfg --styleCheck:usages --styleCheck:hint " & path

task test, "Run all tests":
  test "-d:debug -r", "tests/all_tests"
  test "-d:release -r", "tests/all_tests"
  test "--threads:on -d:release -r", "tests/all_tests"
  test "-d:release", "tests/benchmark" # don't run
