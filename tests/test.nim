import
  snappy, os, unittest,
  terminal, strutils, randgen

{.passL: "-lsnappy".}
{.passL: "-L.".}
{.passL: "-lstdc++".}

proc snappy_compress(input: cstring, input_length: csize, compressed: cstring, compressed_length: var csize): cint {.importc, cdecl.}
proc snappy_uncompress(compressed: cstring, compressed_length: csize, uncompressed: cstring, uncompressed_length: var csize): cint {.importc, cdecl.}
proc snappy_max_compressed_length(source_length: csize): csize {.importc, cdecl.}
proc snappy_uncompressed_length(compressed: cstring, compressed_length: csize, res: var csize): cint {.importc, cdecl.}

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

proc roundTrip(msg: string, source: openArray[byte]): bool =
  var
    encoded = snappy.encode(source)
    cpp_encoded = newString(snappy_max_compressed_length(source.len.csize))
    output_size: csize = cpp_encoded.len
    success: cint = 0

  if source.len > 0:
    success = snappy_compress(cast[cstring](source[0].unsafeAddr), source.len.csize, cpp_encoded[0].addr, output_size)
  else:
    success = snappy_compress(cast[cstring](0), source.len.csize, cpp_encoded[0].addr, output_size)

  var ok = success == 0
  if not ok: echo "cpp_compress failed"

  ok = output_size == encoded.len
  if not ok: echo "cpp output size and nim output size differ"

  if ok:
    ok = equalMem(encoded[0].addr, cpp_encoded[0].addr, output_size.int)
    if not ok: echo "cpp output and nim output differ"

  if ok:
    ok = snappy.decode(encoded) == source
    if not ok: echo "roundtrip failure"

  if ok:
    stdout.styledWriteLine("  ", msg, "...", fgGreen, "[PASS]")
  else:
    stdout.styledWriteLine("  ", msg, "...", fgRed, "[FAILED]")

  result = ok

proc roundTrip(msg: string, sourceName: string): bool =
  var src = readSource(sourceName)
  roundTrip(msg, src)

proc roundTripRev(msg: string, source: openArray[byte]): bool =
  var
    decoded = snappy.decode(source)
    output_size: csize = 0
    ok = snappy_uncompressed_length(cast[cstring](source[0].unsafeAddr), source.len.csize, output_size) == 0
    cpp_decoded: string

  if not ok: echo "maybe a bad data"

  if ok:
    cpp_decoded = newString(output_size)
    ok = snappy_uncompress(cast[cstring](source[0].unsafeAddr), source.len.csize, cpp_decoded, output_size) == 0
    if not ok: echo "cpp failed to uncompress"

  if ok:
    ok = equalMem(decoded[0].addr, cpp_decoded[0].addr, output_size.int)
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

suite "snappy":
  test "basic roundtrip test":
    check roundTrip("empty", empty)
    check roundTrip("oneZero", oneZero)
    check roundTrip("data_html",    testDataDir & "html")
    check roundTrip("data_urls",    testDataDir & "urls.10K")
    check roundTrip("data_jpg",     testDataDir & "fireworks.jpeg")
    check roundTrip("data_pdf",     testDataDir & "paper-100k.pdf")
    check roundTrip("data_html4",   testDataDir & "html_x_4")
    check roundTrip("data_txt1",    testDataDir & "alice29.txt")
    check roundTrip("data_txt2",    testDataDir & "asyoulik.txt")
    check roundTrip("data_txt3",    testDataDir & "lcet10.txt")
    check roundTrip("data_txt4",    testDataDir & "plrabn12.txt")
    check roundTrip("data_pb",      testDataDir & "geo.protodata")
    check roundTrip("data_gaviota", testDataDir & "kppkn.gtb")
    check roundTrip("data_golden",  testDataDir & "Mark.Twain-Tom.Sawyer.txt")
    check roundTripRev("data_golden_rev", testDataDir & "Mark.Twain-Tom.Sawyer.txt.rawsnappy")

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
