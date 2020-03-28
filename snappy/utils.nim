# MaxEncodedLen returns the maximum length of a snappy block, given its
# uncompressed length.
#
# It will return a zero value if srcLen is too large to encode.
func maxEncodedLen*(srcLen: int): int =
  var n = uint64(srcLen)
  if n > 0xffffffff'u64:
    return 0

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
  n = 32'u64 + n + n div 6'u64
  if n > 0xffffffff'u64:
    return 0

  result = int(n)
  