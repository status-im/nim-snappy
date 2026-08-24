mode = ScriptMode.Verbose

packageName   = "snappy"
version       = "0.1.1"
author        = "Andri Lim"
description   = "Nim implementation of snappy compression algorithm"
license       = "MIT"
skipDirs      = @["tests"]

requires "nim >= 1.6.18",
         "faststreams >= 0.5.0",
         "results >= 0.5.0",
         "stew >= 0.5.0",
         "testutils >= 0.8.3",
         "unittest2 >= 0.2.0"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]

const sanitize = "\"-fsanitize=undefined\""

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0") &
  (if defined(linux):
    " --passC:" & sanitize & " --passL: " & sanitize
   else: "") &
  " --skipParentCfg --skipUserCfg"

proc build(args, path: string) =
  exec nimc & " " & lang & " " & cfg &
    " --outdir:build --nimcache:build/nimcache -f " & flags & " " & args & " " & path

proc run(args, path: string) =
  build args & " --mm:refc -r", path
  if (NimMajor, NimMinor) > (1, 6):
    build args & " --mm:orc -r", path

### Helper functions
proc test(args, path: string) =
  if not dirExists "build":
    mkDir "build"

  exec "nim " & getEnv("TEST_LANG", "c") & " " & getEnv("NIMFLAGS") & " " & args &
    " --skipParentCfg --styleCheck:usages --styleCheck:error " & path

task test, "Run all tests":
  for threads in ["--threads:off", "--threads:on"]:
    for mode in ["-d:debug", "-d:release"]:
      run threads & " " & mode, "tests/all_tests"

  build "-d:release", "tests/benchmark" # don't run

let
  fuzzSeconds = getEnv("FUZZ_SECONDS", "100")
  fuzzTime =
    if fuzzSeconds == "": ""
    else: " --duration=" & fuzzSeconds & " "

proc fuzz(format: string) =
  for fuzzer in ["libFuzzer", "honggfuzz", "afl"]:
    when defined(macosx):
      if fuzzer == "honggfuzz":
        continue

    build "-d:release -r", "tests/fuzzing/collect_corpus.nim"
    exec "ntu fuzz --fuzzer=" & fuzzer & fuzzTime &
      "--corpus=tests/fuzzing/corpus/" & format & " " &
      "tests/fuzzing/fuzz_" & format

task fuzz, "Run fuzzing tests":
  for format in ["block_format", "framing_format"]:
    fuzz(format)
