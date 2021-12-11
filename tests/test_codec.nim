{.used.}

import
  os, unittest, terminal, strutils,
  faststreams,
  snappy, randgen, openarrays_snappy, nimstreams_snappy

include system/timers

const
  currentDir = currentSourcePath.parentDir

{.passl: "-lsnappy -L\"" & currentDir & "\" -lstdc++".}

type
  TestTimes = object
    fastStreams: int
    appendSnappyBytes: int
    openArrays: int
    nimStreams: int
    cppLib: int

template timeit(timerVar: var Nanos, code: untyped) =
  let t0 = getTicks()
  code
  timerVar = int(getTicks() - t0) div 1000000

proc printTimes(t: TestTimes) =
  styledEcho "  cpu time [OpenArrays]: ", styleBright, $t.openArrays, "ms"
  styledEcho "  cpu time [FastStream]: ", styleBright, $t.fastStreams, "ms"
  styledEcho "  cpu time [NimStreams]: ", styleBright, $t.nimStreams, "ms"
  styledEcho "  cpu time [C++ Snappy]: ", styleBright, $t.cppLib, "ms"

proc snappy_compress(input: cstring, input_length: csize_t, compressed: cstring, compressed_length: var csize_t): cint {.importc, cdecl.}
proc snappy_uncompress(compressed: cstring, compressed_length: csize_t, uncompressed: cstring, uncompressed_length: var csize_t): cint {.importc, cdecl.}
proc snappy_max_compressed_length(source_length: csize_t): csize_t {.importc, cdecl.}
proc snappy_uncompressed_length(compressed: cstring, compressed_length: csize_t, res: var csize_t): cint {.importc, cdecl.}

const
  testDataDir = "data" & DirSep

let
  empty: seq[byte] = @[]
  oneZero = @[0.byte]

proc readSource(sourceName: string): seq[byte] =
  var f = open(sourceName, fmRead)
  if f.isNil: return
  let size = f.getFileSize()
  result = newSeq[byte](size)
  doAssert(size == f.readBytes(result, 0, size))
  f.close()

proc timedRoundTrip(msg: string, source: openarray[byte]): (bool, TestTimes) =
  var timers: TestTimes
  timeit(timers.fastStreams):
    var encodedWithFastStreams = snappy.encode(source)

  timeit(timers.appendSnappyBytes):
    var encodedWithAppendSnappyBytes = block:
      let output = memoryOutput()
      snappy.appendSnappyBytes(output, source)
      output.getOutput

  timeit(timers.nimStreams):
    var encodedWithNimStreams = nimstreams_snappy.encode(source)

  timeit(timers.openArrays):
    var encodedWithOpenArrays = openarrays_snappy.encode(source)

  var
    encodedWithCpp = newString(snappy_max_compressed_length(source.len.csize_t))
    outputSize = csize_t encodedWithCpp.len

  timeit(timers.cppLib):
    var success = if source.len > 0:
      snappy_compress(cast[cstring](source[0].unsafeAddr), source.len.csize_t, encodedWithCpp[0].addr, outputSize)
    else:
      snappy_compress(cast[cstring](0), source.len.csize_t, encodedWithCpp[0].addr, outputSize)

  var ok = success == 0
  if not ok: echo "cpp_compress failed"

  ok = outputSize == encodedWithOpenArrays.len.csize_t
  if not ok: echo "cpp output size and nim output size differ"

  if ok:
    ok = equalMem(encodedWithOpenArrays[0].addr, encodedWithCpp[0].addr, outputSize.int)
    if not ok: echo "cpp output and nim output differ"

  if ok:
    ok = encodedWithOpenArrays == encodedWithFastStreams
    if not ok:
      echo "OpenArray and FastStreams implementations disagree"

  if ok:
    ok = encodedWithOpenArrays == encodedWithAppendSnappyBytes
    if not ok:
      echo "OpenArray and AppendSnappyBytes implementations disagree"

  if ok:
    ok = encodedWithOpenArrays == encodedWithNimStreams
    if not ok:
      echo "OpenArray and NimStreams implementations disagree"

  if ok:
    ok = snappy.decode(encodedWithOpenArrays) == source
    if not ok: echo "roundtrip failure"

  if ok:
    stdout.styledWriteLine("  ", msg, "...", fgGreen, "[PASS]")
  else:
    stdout.styledWriteLine("  ", msg, "...", fgRed, "[FAILED]")

  (ok, timers)

proc roundTrip(msg: string, source: openArray[byte]): bool =
  timedRoundTrip(msg, source)[0]

proc roundTrip(msg: string, sourceName: string): bool =
  var src = readSource(sourceName)
  roundTrip(msg, src)

proc timedRoundTrip(msg: string, sourceName: string): auto =
  var src = readSource(sourceName)
  timedRoundTrip(msg, src)

proc roundTripRev(msg: string, source: openArray[byte]): bool =
  var
    decoded = snappy.decode(source)
    outputSize: csize_t = 0
    ok = snappy_uncompressed_length(cast[cstring](source[0].unsafeAddr), source.len.csize_t, outputSize) == 0
    cpp_decoded: string

  if not ok: echo "maybe a bad data"

  if ok:
    cpp_decoded = newString(outputSize)
    ok = snappy_uncompress(cast[cstring](source[0].unsafeAddr), source.len.csize_t, cpp_decoded, outputSize) == 0
    if not ok: echo "cpp failed to uncompress"

  if ok:
    ok = equalMem(decoded[0].addr, cpp_decoded[0].addr, outputSize.int)
    if not ok: echo "cpp output and nim output differ"

  if ok:
    ok = snappy.encode(decoded) == source
    if not ok: echo "rev roundtrip failure"

  if ok:
    stdout.styledWriteLine("  ", msg, "...", fgGreen, "[PASS]")
  else:
    stdout.styledWriteLine("  ", msg, "...", fgRed, "[FAILED]")

  result = ok

proc roundTripRev(msg: string, sourceName: string): bool =
  var src = readSource(sourceName)
  roundTripRev(msg, src)

template toBytes(s: string): auto =
  toOpenArrayByte(s, 0, s.len-1)

proc compressFileWithFaststreams(src, dst: string) =
  var input = memFileInput(src)
  var output = fileOutput(dst)
  output.appendSnappyBytes input.read(input.len.get)
  output.flush()

when false:
  # TODO: This is not tested yet
  import streams

  proc compressFileWithNimStreams(src, dst: string) =
    var input = newFileStream(src, fmRead)
    var output = newFileStream(dst, fmWrite)
    output.appendSnappyBytes input, getFileSize(src).int

suite "snappy":
  let
    dataDir = getAppDir() & DirSep & testDataDir
    largeFile = dataDir / "largefile.bin"

  if fileExists(largeFile):
    test "test large file performance":
      let (success, times) = timedRoundTrip("empty", largeFile)
      printTimes times
      check success and float64(times.fastStreams) < float64(times.openArrays) * 1.1

    let
      largeFileCopy1 = dataDir / "largefile.bin.copy.1"
      largeFileCopy2 = dataDir / "largefile.bin.copy.2"

    var time = 0
    timeit(time): compressFileWithFaststreams(largeFile, largeFileCopy1)
    styledEcho "  compress file [Faststreams]: ", styleBright, $time, "ms"

    timeit(time): compressFileWithFaststreams(largeFile, largeFileCopy2)
    styledEcho "  compress file [Faststreams]: ", styleBright, $time, "ms"

    removeFile largeFileCopy1
    removeFile largeFileCopy2

  test "basic roundtrip test":
    check roundTrip("empty", empty)
    check roundTrip("oneZero", oneZero)
    check roundTrip("data_html",    dataDir & "html")
    check roundTrip("data_urls",    dataDir & "urls.10K")
    check roundTrip("data_jpg",     dataDir & "fireworks.jpeg")
    check roundTrip("data_pdf",     dataDir & "paper-100k.pdf")
    check roundTrip("data_html4",   dataDir & "html_x_4")
    check roundTrip("data_txt1",    dataDir & "alice29.txt")
    check roundTrip("data_txt2",    dataDir & "asyoulik.txt")
    check roundTrip("data_txt3",    dataDir & "lcet10.txt")
    check roundTrip("data_txt4",    dataDir & "plrabn12.txt")
    check roundTrip("data_pb",      dataDir & "geo.protodata")
    check roundTrip("data_gaviota", dataDir & "kppkn.gtb")
    check roundTrip("data_golden",  dataDir & "Mark.Twain-Tom.Sawyer.txt")
    check roundTripRev("data_golden_rev", dataDir & "Mark.Twain-Tom.Sawyer.txt.rawsnappy")

  test "misc test":
    for i in 1..32:
      let x = repeat("b", i)
      let y = "aaaa$1aaaabbbb" % [x]
      check roundTrip("repeat " & $i, toBytes(y))

    var i = 1
    while i < 20_000:
      var buf = newSeq[byte](i)
      for j in 0..<buf.len:
        buf[j] = byte((j mod 10) + int('a'))
      check roundTrip("buf " & $buf.len, buf)
      inc(i, 23)

    for m in 1 .. 5:
      for i in m * maxBlockSize - 5 .. m * maxBlockSize + 5:
        var buf = newSeq[byte](i)
        for j in 0..<buf.len:
          buf[j] = byte((j mod 10) + int('a'))
        check roundTrip("buf " & $buf.len, buf)

    block:
      let encoded = [27'u8, 0b000010_00, 1, 2, 3, 0b000_000_10, 3, 0,
        0b010110_00, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 ,21, 22, 23, 24, 25, 26]
      let decompressed = @[1'u8, 2, 3, 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26]
      let decoded = snappy.decode(encoded)
      check decoded == decompressed

    block:
      let encoded = [28'u8, 0b000010_00, 1, 2, 3, 0b000_000_10, 3, 0,
        0b010111_00, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 ,21, 22, 23, 24, 25, 26, 27]
      let decompressed = @[1'u8, 2, 3, 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27]
      let decoded = snappy.decode(encoded)
      check decoded == decompressed

  template badData(encoded: string): untyped =
    block:
      var decoded = snappy.decode(encoded.toBytes)
      check decoded.len == 0

  test "malformed data":
    # An empty buffer.
    var encoded = snappy.encode(empty)
    check encoded.len == 1
    check encoded[0] == byte(0)

    # Decompress fewer bytes than the header reports.
    badData "\x05\x00a"

    # A varint that overflows u64.
    badData "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x00"

    # A varint that fits in u64 but overflows u32.
    badData "\x80\x80\x80\x80\x10"

    # A literal whose length is too small.
    # Since the literal length is 1, 'h' is read as a literal and 'i' is
    # interpreted as a copy 1 operation missing its offset byte.
    badData "\x02\x00hi"

    # A literal whose length is too big.
    badData "\x02\xechi"

    # A literal whose length is too big, requires 1 extra byte to be read, and
    # src is too short to read that byte.
    badData "\x02\xf0hi"

    # A literal whose length is too big, requires 1 extra byte to be read,
    # src is too short to read the full literal.
    badData "\x02\xf0hi\x00\x00\x00"

    # A copy 1 operation that stops at the tag byte. This fails because there's
    # no byte to read for the copy offset.
    badData "\x02\x00a\x01"

    # A copy 2 operation that stops at the tag byte and another copy 2 operation
    # that stops after the first byte in the offset.
    badData "\x11\x00a\x3e"
    badData "\x11\x00a\x3e\x01"

    # Same as copy 2, but for copy 4.
    badData "\x11\x00a\x3f"
    badData "\x11\x00a\x3f\x00"
    badData "\x11\x00a\x3f\x00\x00"
    badData "\x11\x00a\x3f\x00\x00\x00"

    # A copy operation whose offset is zero.
    badData "\x11\x00a\x01\x00"

    # A copy operation whose offset is too big.
    badData "\x11\x00a\x01\xFF"

    # A copy operation whose length is too big.
    badData "\x05\x00a\x1d\x01"

    badData "\x11\x00\x00\xfc\xfe\xff\xff\xff"

    badData "\x11\x00\x00\xfc\xff\xff\xff\xff"

  test "random data":
    # Selected random inputs pulled from quickcheck failure witnesses.
    let random1 = [0'u8, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0, 5, 0, 0, 1, 1,
      0, 0, 1, 2, 0, 0, 2, 1, 0, 0, 2, 2, 0, 0, 0, 6, 0, 0, 3, 1, 0, 0, 0, 7, 0,
      0, 1, 3, 0, 0, 0, 8, 0, 0, 2, 3, 0, 0, 0, 9, 0, 0, 1, 4, 0, 0, 1, 0, 0, 3,
      0, 0, 1, 0, 1, 0, 0, 0, 10, 0, 0, 0, 0, 2, 4, 0, 0, 2, 0, 0, 3, 0, 1, 0, 0,
      1, 5, 0, 0, 6, 0, 0, 0, 0, 11, 0, 0, 1, 6, 0, 0, 1, 7, 0, 0, 0, 12, 0, 0,
      3, 2, 0, 0, 0, 13, 0, 0, 2, 5, 0, 0, 0, 3, 3, 0, 0, 0, 1, 8, 0, 0, 1, 0,
      1, 0, 0, 0, 4, 1, 0, 0, 0, 0, 14, 0, 0, 0, 1, 9, 0, 0, 0, 1, 10, 0, 0, 0,
      0, 1, 11, 0, 0, 0, 1, 0, 2, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 5, 1, 0, 0, 0, 1,
      2, 1, 0, 0, 0, 0, 0, 2, 6, 0, 0, 0, 0, 0, 1, 12, 0, 0, 0, 0, 0, 3, 4, 0, 0,
      0, 0, 0, 7, 0, 0, 0, 0, 0, 1, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

    let random2 = [10'u8, 2, 14, 13, 0, 8, 2, 10, 2, 14, 13, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

    let random3 = [0'u8, 0, 0, 4, 1, 4, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

    let random4 = [0'u8, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0, 5, 0, 0, 1, 1,
      0, 0, 1, 2, 0, 0, 1, 3, 0, 0, 1, 4, 0, 0, 2, 1, 0, 0, 0, 4, 0, 1, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

    check roundTrip("random1", random1)
    check roundTrip("random2", random2)
    check roundTrip("random3", random3)
    check roundTrip("random4", random4)

    const
      listLen = 100
      minStringSize = 1000
      maxStringSize = 10000

    for x in randList(string, randGen(minStringSize, maxStringSize), randGen(listLen, listLen)):
      check roundTrip("random " & $x.len, toBytes(x))
