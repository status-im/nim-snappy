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

### Helper functions
proc test(env, path: string) =
  # Compilation language is controlled by TEST_LANG
  var lang = "c"
  if existsEnv"TEST_LANG":
    lang = getEnv"TEST_LANG"

  when defined(macosx):
    # nim bug, incompatible pointer assignment
    # see nim-lang/Nim#16123
    if lang == "cpp":
      lang = "c"

  if not dirExists "build":
    mkDir "build"

  exec "nim " & lang & " " & env &
    " --hints:off --skipParentCfg " & path

task test, "Run all tests":
  test "-d:debug -r", "tests/all_tests"
  test "-d:release -r", "tests/all_tests"
  test "--threads:on -d:release -r", "tests/all_tests"
  test "", "tests/benchmark" # don't run
