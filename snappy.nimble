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
         "stew"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]

const sanitize = "\"-fsanitize=undefined\""

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0 --hints:off") &
  (if defined(linux):
    " --passC:" & sanitize & " --passL: " & sanitize
   else: "") &
  " --skipParentCfg --skipUserCfg --outdir:build --nimcache:build/nimcache -f"

proc build(args, path: string) =
  exec nimc & " " & lang & " " & cfg & " " & flags & " " & args & " " & path

proc run(args, path: string) =
  build args & " --mm:refc -r", path
  if (NimMajor, NimMinor) > (1, 6):
    build args & " --mm:orc -r", path

### Helper functions
proc test(args, path: string) =
  if not dirExists "build":
    mkDir "build"

  exec "nim " & getEnv("TEST_LANG", "c") & " " & getEnv("NIMFLAGS") & " " & args &
    " --skipParentCfg --styleCheck:usages --styleCheck:hint " & path

task test, "Run all tests":
  for threads in ["--threads:off", "--threads:on"]:
    for mode in ["-d:debug", "-d:release"]:
      run threads & " " & mode, "tests/all_tests"
 
  build "-d:release", "tests/benchmark" # don't run

