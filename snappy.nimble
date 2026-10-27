mode = ScriptMode.Verbose

packageName   = "snappy"
version       = "0.1.0"
author        = "Andri Lim"
description   = "Nim implementation of snappy compression algorithm"
license       = "MIT"
skipDirs      = @["tests"]

requires "nim >= 1.6.0",
         "faststreams",
         "unittest2",
         "results",
         "stew",
         "testutils >= 0.8.5"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]
let platform = getEnv("PLATFORM", "")
let testArguments = [
  "-d:debug",
  "-d:release",
]

from std/os import quoteShell

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0") &
  " --skipParentCfg --skipUserCfg --outdir:build -f " &
  quoteShell("--nimcache:build/nimcache/$projectName")

proc build(args, path: string) =
  exec nimc & " " & lang & " " & cfg & " " & flags & " " & args & " " & path

proc run(args, path: string) =
  build args & " -r", path

task test, "Run all tests":
  for threads in ["--threads:off", "--threads:on"]:
    for args in testArguments:
      run threads & " " & args & " --mm:refc", "tests/all_tests"
      if (NimMajor, NimMinor) > (1, 6):
        run threads & " " & args & " --mm:orc", "tests/all_tests"

  build "-d:release", "tests/benchmark" # don't run

task test_asan, "Run all tests with ASAN":
  if platform != "x86":
    # https://clang.llvm.org/docs/AddressSanitizer.html
    putEnv("ASAN_OPTIONS", "detect_leaks=0:detect_stack_use_after_return=1")
    # https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html
    putEnv("UBSAN_OPTIONS", "print_stacktrace=1")
    let asanArgs =
      " --mm:orc -d:useMalloc --cc:clang --debugger:native" &
      " --passC:-fsanitize=address,undefined" &
      " --passL:-fsanitize=address,undefined" &
      " --passC:-fno-sanitize-recover=undefined" &
      " --passC:-fno-sanitize-merge" &
      " --passC:-fno-omit-frame-pointer"
    for threads in ["--threads:off", "--threads:on"]:
      for args in testArguments:
        run threads & " " & args & asanArgs, "tests/all_tests"

let
  fuzzSeconds = getEnv("FUZZ_SECONDS", "100")
  fuzzTime =
    if fuzzSeconds == "": " "
    else: " --duration=" & fuzzSeconds & " "

proc fuzz(format: string) =
  for fuzzer in ["libFuzzer", "honggfuzz", "afl"]:
    when defined(macosx):
      if fuzzer == "honggfuzz":
        continue

    exec "ntu fuzz --fuzzer=" & fuzzer & fuzzTime &
      "--corpus=tests/fuzzing/corpus/" & format & " " &
      "tests/fuzzing/fuzz_" & format

task fuzz, "Run fuzzing tests":
  run "-d:release", "tests/fuzzing/collect_corpus"
  fuzz "block_format"
  fuzz "framing_format"
