type
  SnappyError* = object of CatchableError

  SnappyDecodingError* = object of SnappyError
  SnappyEncodingError* = object of SnappyError

  UnexpectedEofError* = object of SnappyDecodingError
  MalformedSnappyData* = object of SnappyDecodingError

  InputTooLarge* = object of SnappyEncodingError

const
  maxUncompressedLen* = 0xffffffff'u32
  maxBlockSize* = 65536

template raiseInputTooLarge* =
  raise newException(InputTooLarge, "Input too large to be compressed with Snappy")

proc checkInputLen*(len: Natural): uint32 =
  when sizeof(int) == 8:
    if len > 0xffffffff:
      raiseInputTooLarge()
  uint32(len)

# maxCompressedLen returns the maximum length of a snappy block, given its
# uncompressed length.
#
# It will return a zero value if srcLen is too large to encode.
func maxCompressedLen*(srcLen: uint32): uint64 =
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
  let n = srcLen.uint64
  32'u64 + n + n div 6'u64

