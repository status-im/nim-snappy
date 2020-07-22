import
  os, strformat,
  confutils, testutils/fuzzing_engines

type
  SnappyFormat = enum
    block_format
    framing_format

cli do (format {.argument.}: SnappyFormat,
        fuzzer = libFuzzer):
  let
    fuzzingDir = thisDir()
    fuzzingFile = fuzzingDir / "fuzz_" & addFileExt($format, "nim")
    corpusDir = fuzzingDir / "corpus" / $format

  let
    collectCorpusNim = fuzzingDir / "collect_corpus.nim"

  exec &"""nim c -r "{collectCorpusNim}""""
  exec &"""ntu fuzz --fuzzer:{fuzzer} --corpus:"{corpusDir}" "{fuzzingFile}" """

