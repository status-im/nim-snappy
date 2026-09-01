import
  testutils/fuzzing,
  results,
  stew/ptrops,
  ../../snappy, ../cpp_snappy

{.push raises: [].}

const MaxLen = 128'u32 * 1024 * 1024

proc cppDecode(payload: openArray[byte]): Opt[seq[byte]] =
  if payload.len == 0:
    return err()

  var cppDecompressedLen: csize_t
  if snappy_uncompressed_length(
      cast[cstring](baseAddr payload), payload.len.csize_t,
      cppDecompressedLen) != 0:
    return err()

  if cppDecompressedLen > MaxLen.csize_t:
    return err()

  var cppDecompressed = newSeqUninit[byte](cppDecompressedLen)
  if cppDecompressedLen > 0 and snappy_uncompress(
      cast[cstring](baseAddr payload), payload.len.csize_t,
      cast[ptr cchar](baseAddr cppDecompressed), cppDecompressedLen) != 0:
    return err()

  ok cppDecompressed

test:
  block:
    let
      nim = snappy.decode(payload, MaxLen)
      cpp = cppDecode(payload).valueOr:
        doAssert nim.len == 0
        break
    doAssert nim == cpp
    doAssert cppDecode(snappy.encode(cpp)) == Opt.some(cpp)
