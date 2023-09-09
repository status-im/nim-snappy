import
  testutils/fuzzing,
  stew/ptrops,
  ../../snappy, ../cpp_snappy

{.push raises: [].}

test:
  var cppDecompressedLen: csize_t

  let
    lenRes =
      snappy_uncompressed_length(
        cast[cstring](baseAddr payload), payload.len.csize_t,
        cppDecompressedLen)

    decoded = snappy.decode(payload, 128*1024*1024)
  doAssert decoded.len == 0 or lenRes == 0 and decoded.len == cppDecompressedLen.int

  if decoded.len > 0:
    var cppDecompressed = newSeq[byte](cppDecompressedLen)
    doAssert snappy_uncompress(
      cast[cstring](baseAddr payload), payload.len.csize_t,
      cast[ptr cchar](baseAddr cppDecompressed), cppDecompressedLen) == 0

    doAssert cppDecompressed == decoded, "decompression should match between libraries"

    let encoded = snappy.encode(decoded)
    doAssert snappy_uncompress(
      cast[cstring](baseAddr encoded), encoded.len.csize_t,
      cast[ptr cchar](baseAddr cppDecompressed), cppDecompressedLen) == 0

    doAssert cppDecompressed == decoded, "cpp should be able to decompress our compressed data"
