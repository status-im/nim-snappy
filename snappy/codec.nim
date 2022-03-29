import
  stew/results

export results

const
  tagLiteral* = 0x00
  tagCopy1*   = 0x01
  tagCopy2*   = 0x02
  tagCopy4*   = 0x03

  inputMargin* = 16 - 1

  maxUncompressedLen* = 0xffffffff'u32
  maxBlockSize* = 65536'u32

# minNonLiteralBlockSize is the minimum size of the input to encodeBlock that
# could be encoded with a copy tag. This is the minimum with respect to the
# algorithm used by encodeBlock, not a minimum enforced by the file format.
#
# The encoded output must start with at least a 1 byte literal, as there are
# no previous bytes to copy. A minimal (1 byte) copy after that, generated
# from an emitCopy call in encodeBlock's main loop, would require at least
# another inputMargin bytes, for the reason above: we want any emitLiteral
# calls inside encodeBlock's main loop to use the fast path if possible, which
# requires being able to overrun by inputMargin bytes. Thus,
# minNonLiteralBlockSize equals 1 + 1 + inputMargin.
#
# The C++ code doesn't use this exact threshold, but it could, as discussed at
# https:#groups.google.com/d/topic/snappy-compression/oGbhsdIJSJ8/discussion
# The difference between Nim (2+inputMargin) and C++ (inputMargin) is purely an
# optimization. It should not affect the encoded form. This is tested by
# TestSameEncodingAsCppShortCopies.
const
  minNonLiteralBlockSize* = 1 + 1 + inputMargin

func checkInputLen*(srcLen: int): Opt[uint32] =
  static: doAssert uint32.high.uint64 <= maxUncompressedLen.uint64
  if srcLen.uint64 > maxUncompressedLen.uint64:
    err()
  else:
    ok(srcLen.uint32)

func maxCompressedLen*(srcLen: uint32): Opt[int] =
  ## Return the maximum number of bytes needed to encode an input of the given
  ## length - fails when input exceeds maxUncompressedLen or output
  ## see also snappy::MaxCompressedLength

  # Compressed data can be defined as:
  #    compressed := item* literal*
  #    item       := literal* copy
  #
  # The trailing literal sequence has a space blowup of at most 62/60
  # since a literal of length 60 needs one tag byte + one extra byte
  # for length information.
  #
  # Item blowup is trickier to measure. Suppose the "copy" op copies
  # 4 bytes of data. Because of a special check in the encoding code,
  # we produce a 4-byte copy only if the offset is < 65536. Therefore
  # the copy op takes 3 bytes to encode, and this type of item leads
  # to at most the 62/60 blowup for representing literals.
  #
  # Suppose the "copy" op copies 5 bytes of data. If the offset is big
  # enough, it will take 5 bytes to encode the copy op. Therefore the
  # worst case here is a one-byte literal followed by a five-byte copy.
  # That is, 6 bytes of input turn into 7 bytes of "compressed" data.
  #
  # This last factor dominates the blowup, so the final estimate is:
  static:
    doAssert sizeof(int) <= sizeof(uint64),
      "did we get to 128-bit ints already???"

  let
    n = srcLen.uint64
    max = 32'u64 + n + n div 6'u64
  if max > int.high.uint64: # for 32-bit platforms..
    err()
  else:
    ok(int(max))

func hash*(u, shift: uint32): uint32 =
  (u * 0x1e35a7bd'u32) shr shift
