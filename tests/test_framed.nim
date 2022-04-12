{.used.}

import
  std/os, stew/byteutils,
  unittest2,
  ../snappy,
  ../snappy/faststreams

template check_uncompress(source, target: string) =
  test "uncompress " & source & " to " & target:
    var inStream = memFileInput(compDir & source)
    var outStream = memoryOutput()

    uncompressFramed(inStream, outStream)

    let expected = toBytes(readFile(uncompDir & target))
    let actual = outStream.getOutput()

    if actual != expected:
      check false
    else:
      check true

    let sourceData = toBytes(readFile(compDir & source))
    if expected != decodeFramed(sourceData):
      check false

    var uncompressOut = newSeqUninitialized[byte](expected.len)
    check:
      uncompressFramed(sourceData, uncompressOut).expect(
        "decompression worked") == (sourceData.len, expected.len)
    if expected != uncompressOut:
      check false

    # Partial framed reads
    uncompressOut = newSeq[byte](uncompressOut.len - 1)
    let (read, written) = uncompressFramed(sourceData, uncompressOut).expect(
        "decompression worked")
    check:
      read < sourceData.len
      written < expected.len
    if expected.toOpenArray(0, written - 1) !=
        uncompressOut.toOpenArray(0, written - 1):
      check false

    # Resume decompression
    var uncompressRest = newSeq[byte](expected.len - written)
    let (read2, written2) = uncompressFramed(
      sourceData.toOpenArray(read, sourceData.high),
      uncompressRest, false).expect("decompression worked")
    check:
      read2 == sourceData.len - read
      written2 == expected.len - written
    if expected.toOpenArray(written, expected.high) !=
        uncompressRest.toOpenArray(0, written2 - 1):
      check false

template check_roundtrip(source) =
  test "roundtrip " & source:
    let expected = toBytes(readFile(uncompDir & source))
    var ost = memoryOutput()

    compressFramed(expected, ost)
    let compressed = ost.getOutput()

    var inst = memoryInput(compressed)
    var outst = memoryOutput()
    uncompressFramed(inst, outst)
    let actual = outst.getOutput()
    check actual.len == expected.len

    if actual != expected:
      check false
    else:
      check true

proc checkInvalidFramed(payload: openArray[byte], uncompressedLen: int) =
  var tmp = newSeqUninitialized[byte](uncompressedLen)
  check:
    uncompressFramed(payload, tmp).isErr()

  let decoded {.used.} = decodeFramed(payload)
  check: decoded.len == 0

  expect(SnappyError):
    var output = memoryOutput()
    uncompressFramed(unsafeMemoryInput(payload), output)

proc checkValidFramed(payload: openArray[byte], expected: openArray[byte]) =
  var tmp = newSeqUninitialized[byte](expected.len)
  check:
    decodeFramed(payload) == expected
    uncompressFramed(payload, tmp).get() == (payload.len, expected.len)
    tmp == expected

  var output = memoryOutput()
  uncompressFramed(unsafeMemoryInput(payload), output)

  check:
    output.getOutput() == expected

suite "framing":
  setup:
    let
      compDir {.used.} = getAppDir() & DirSep & "stream_compressed" & DirSep
      uncompDir {.used.} = getAppDir() & DirSep & "data" & DirSep

  check_uncompress("alice29.txt.sz-32k", "alice29.txt")
  check_uncompress("alice29.txt.sz-64k", "alice29.txt")
  check_uncompress("house.jpg.sz", "house.jpg")

  check_roundtrip("alice29.txt")
  check_roundtrip("house.jpg")
  check_roundtrip("html")
  check_roundtrip("urls.10K")
  check_roundtrip("fireworks.jpeg")

  check_roundtrip("paper-100k.pdf")

  check_roundtrip("html_x_4")
  check_roundtrip("asyoulik.txt")
  check_roundtrip("lcet10.txt")
  check_roundtrip("plrabn12.txt")
  check_roundtrip("geo.protodata")
  check_roundtrip("kppkn.gtb")
  check_roundtrip("Mark.Twain-Tom.Sawyer.txt")

  test "just a header":
    checkValidFramed(framingHeader, [])

  test "buffer sizes":
    var
      buf = newSeq[byte](128 * 1024)
    for i, c in buf.mpairs():
      c = byte(i)

    let tests = [
      0, 1, 10,
      minNonLiteralBlockSize - 1,
      minNonLiteralBlockSize,
      minNonLiteralBlockSize + 1,
      int maxUncompressedFrameDataLen - 1,
      int maxUncompressedFrameDataLen,
      int maxUncompressedFrameDataLen + 1,
      buf.len]
    for i in tests:
      let recoded = decodeFramed(encodeFramed(buf.toOpenArray(0, i - 1)))
      check:
        recoded == buf[0..i - 1]

  test "full uncompressed":
    let
      data = newSeq[byte](maxUncompressedFrameDataLen)
      compressed = snappy.encode(data)
      framed =
        @framingHeader & @[byte chunkUncompressed] &
        @((data.len + 4).uint32.toBytesLE().toOpenArray(0, 2)) &
        @(maskedCrc(data).toBytesLE()) &
        data

      framedCompressed =
        @framingHeader & @[byte chunkCompressed] &
        @((compressed.len + 4).uint32.toBytesLE().toOpenArray(0, 2)) &
        @(maskedCrc(data).toBytesLE()) &
        compressed

    checkValidFramed(framed, data)
    checkValidFramed(framedCompressed, data)

  test "invalid header":
    checkInvalidFramed([byte 3, 2, 1, 0], 0)

  test "overlong frame":
    let
      data = newSeq[byte](maxUncompressedFrameDataLen + 1)
      compressed = snappy.encode(data)
      framed =
        @framingHeader & @[byte chunkUncompressed] &
        @((data.len + 4).uint32.toBytesLE().toOpenArray(0, 2)) &
        @(maskedCrc(data).toBytesLE()) &
        data

      framedCompressed =
        @framingHeader & @[byte chunkCompressed] &
        @((compressed.len + 4).uint32.toBytesLE().toOpenArray(0, 2)) &
        @(maskedCrc(data).toBytesLE()) &
        compressed

    checkInvalidFramed(framed, data.len)
    checkInvalidFramed(framedCompressed, data.len)
