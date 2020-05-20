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
    fuzzNims = fuzzingDir / ".." / ".." / ".." / "nim-testutils" / "testutils" / "fuzzing" / "fuzz.nims"

  exec &"""nim c -r "{collectCorpusNim}""""
  exec &"""nim "{fuzzNims}" {fuzzer} "{fuzzingFile}" "{corpusDir}" """

