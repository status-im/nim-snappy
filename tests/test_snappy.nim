{.used.}

import
  stew/byteutils,
  std/[os, strutils],
  unittest2,
  ../snappy,
  ../snappy/[faststreams, streams],
  ./cpp_snappy, ./randgen

include system/timers

const
  currentDir = currentSourcePath.parentDir
  dataDir = currentDir & DirSep & "data" & DirSep

let
  empty: seq[byte] = @[]
  oneZero = @[0.byte]

proc readSource(sourceName: string): seq[byte] =
  var f = open(sourceName, fmRead)
  if f.isNil: return
  let size = f.getFileSize()
  result = newSeqUninitialized[byte](size)
  doAssert(size == f.readBytes(result, 0, size))
  f.close()

proc streamsEncode(input: openArray[byte]): seq[byte] =
  let
    ins = newStringStream(string.fromBytes(input))
    outs = newStringStream()
  compress(ins, input.len, outs)
  outs.setPosition(0)
  outs.readAll().toBytes()

proc faststreamsEncode(input: openArray[byte]): seq[byte] =
  let
    ins = unsafeMemoryInput(string.fromBytes(input))
    outs = memoryOutput()
  compress(ins, outs)
  outs.getOutput()

proc roundTrip(msg: string, source: openArray[byte]) =
  var encodedWithSnappy = snappy.encode(source)
  var encodedWithFastStreams = faststreamsEncode(source)
  var encodedWithNimStreams = streamsEncode(source)
  var encodedWithCpp = cpp_snappy.encode(source)

  # check encodedWithCpp.len == encodedWithOpenArrays.len
  # check: encodedWithOpenArrays == encodedWithCpp
  # Test that everything can decode with C++ snappy - there may be minor
  # differences in encoding however!
  checkpoint(msg)
  check:
    encodedWithSnappy == encodedWithFastStreams
    encodedWithSnappy == encodedWithNimStreams

    snappy.decode(encodedWithSnappy) == source
    cpp_snappy.decode(encodedWithSnappy) == source

    snappy.decode(encodedWithFastStreams) == source
    cpp_snappy.decode(encodedWithFastStreams) == source

    snappy.decode(encodedWithNimStreams) == source
    cpp_snappy.decode(encodedWithNimStreams) == source

    snappy.decode(encodedWithCpp) == source
    cpp_snappy.decode(encodedWithCpp) == source

proc roundTripRev(msg: string, source: openArray[byte]) =
  var
    decoded = snappy.decode(source)
    outputSize: csize_t = 0
    ok = snappy_uncompressed_length(cast[cstring](source[0].unsafeAddr), source.len.csize_t, outputSize) == 0
    cpp_decoded = cpp_snappy.decode(source)

  check:
    decoded == cpp_decoded

proc roundTripRev(msg: string, sourceName: string) =
  var src = readSource(sourceName)
  roundTripRev(msg, src)

proc roundTrip(msg: string, sourceName: string) =
  var src = readSource(sourceName)
  roundTrip(msg, src)

template toBytes(s: string): auto =
  toOpenArrayByte(s, 0, s.len-1)

suite "snappy":
  test "basic roundtrip test":
    roundTrip("empty", empty)
    roundTrip("oneZero", oneZero)
    roundTrip("data_html",    dataDir & "html")
    roundTrip("data_urls",    dataDir & "urls.10K")
    roundTrip("data_jpg",     dataDir & "fireworks.jpeg")
    roundTrip("data_pdf",     dataDir & "paper-100k.pdf")
    roundTrip("data_html4",   dataDir & "html_x_4")
    roundTrip("data_txt1",    dataDir & "alice29.txt")
    roundTrip("data_txt2",    dataDir & "asyoulik.txt")
    roundTrip("data_txt3",    dataDir & "lcet10.txt")
    roundTrip("data_txt4",    dataDir & "plrabn12.txt")
    roundTrip("data_pb",      dataDir & "geo.protodata")
    roundTrip("data_gaviota", dataDir & "kppkn.gtb")
    roundTrip("data_golden",  dataDir & "Mark.Twain-Tom.Sawyer.txt")
    roundTripRev("data_golden_rev", dataDir & "Mark.Twain-Tom.Sawyer.txt.rawsnappy")

  test "misc test":
    for i in 1..32:
      let x = repeat("b", i)
      let y = "aaaa$1aaaabbbb" % [x]
      roundTrip("repeat " & $i, toBytes(y))

    var i = 1
    while i < 20_000:
      var buf = newSeq[byte](i)
      for j in 0..<buf.len:
        buf[j] = byte((j mod 10) + int('a'))
      roundTrip("buf " & $buf.len, buf)
      inc(i, 23)

    for m in 1 .. 5:
      for i in m * maxBlockLen.int - 5 .. m * maxBlockLen.int + 5:
        var buf = newSeq[byte](i)
        roundTrip("empty buf " & $buf.len, buf)

    for m in 1 .. 5:
      for i in m * maxBlockLen.int - 5 .. m * maxBlockLen.int + 5:
        var buf = newSeq[byte](i)
        for j in 0..<buf.len:
          buf[j] = byte((j mod 10) + int('a'))
        roundTrip("buf " & $buf.len, buf)

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

    block:
      # Sanity check that we actually compress things :)
      let buf = newSeq[byte](1024)
      check:
        snappy.encode(buf).len < buf.len div 2

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

    roundTrip("random1", random1)
    roundTrip("random2", random2)
    roundTrip("random3", random3)
    roundTrip("random4", random4)

    const
      listLen = 100
      minStringSize = 1000
      maxStringSize = 10000

    for x in randList(string, randGen(minStringSize, maxStringSize), randGen(listLen, listLen)):
      roundTrip("random " & $x.len, toBytes(x))
