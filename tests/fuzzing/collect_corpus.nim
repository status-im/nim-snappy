import
  os,
  ../../snappy

let
  fuzzingDir = getAppDir()
  dataDir = fuzzingDir / ".." / "data"

  corpusDir = fuzzingDir / "corpus"
  blockFormatCorpusDir = corpusDir / "block_format"
  framingFormatCorpusDir = corpusDir / "framing_format"

removeDir corpusDir
createDir blockFormatCorpusDir
createDir framingFormatCorpusDir

for kind, file in walkDir(dataDir):
  if kind != pcFile:
    continue

  let size = getFileSize(file)
  if size > 50000:
    continue

  let
    fileContents = cast[seq[byte]](readFile(file))
    fileName = splitFile(file).name
    blockFileName = changeFileExt(fileName, "snappy")
    framingFileName = changeFileExt(fileName, "fsnappy")

  writeFile(blockFormatCorpusDir / blockFileName,
            snappy.encode(fileContents))

  writeFile(framingFormatCorpusDir / framingFileName,
            encodeFramed(fileContents))

