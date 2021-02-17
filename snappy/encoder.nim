import stew/[endians2, leb128, arrayops]

const
  tagLiteral* = 0x00
  tagCopy1*   = 0x01
  tagCopy2*   = 0x02
  tagCopy4*   = 0x03

  inputMargin = 16 - 1

# emitLiteral writes a literal chunk and returns the number of bytes written.
#
# It assumes that:
#  dst is long enough to hold the encoded bytes
#  1 <= len(lit) and len(lit) <= 65536
func emitLiteral(dst: var openArray[byte], d: int, lit: openArray[byte]): int =
  var
    i = d
    n = lit.len-1

  if n < 60:
    dst[i + 0] = (byte(n) shl 2) or tagLiteral
    inc(i)
  elif n < (1 shl 8):
    dst[i + 0] = (60 shl 2) or tagLiteral
    dst[i + 1] = byte(n)
    inc(i, 2)
  else:
    dst[i + 0] = (61 shl 2) or tagLiteral
    dst[i + 1] = byte(n and 0xFF)
    dst[i + 2] = byte((n shr 8) and 0xFF)
    inc(i, 3)

  dst[i..<i+lit.len] = lit
  result = i + lit.len - d

# emitCopy writes a copy chunk and returns the number of bytes written.
#
# It assumes that:
#  dst is long enough to hold the encoded bytes
#  1 <= offset and offset <= 65535
#  4 <= length and length <= 65535
func emitCopy(dst: var openArray[byte], d, offset, length: int): int =
  var
    i = d
    length = length
  # The maximum length for a single tagCopy1 or tagCopy2 op is 64 bytes. The
  # threshold for this loop is a little higher (at 68 = 64 + 4), and the
  # length emitted down below is is a little lower (at 60 = 64 - 4), because
  # it's shorter to encode a length 67 copy as a length 60 tagCopy2 followed
  # by a length 7 tagCopy1 (which encodes as 3+2 bytes) than to encode it as
  # a length 64 tagCopy2 followed by a length 3 tagCopy2 (which encodes as
  # 3+3 bytes). The magic 4 in the 64±4 is because the minimum length for a
  # tagCopy1 op is 4 bytes, which is why a length 3 copy has to be an
  # encodes-as-3-bytes tagCopy2 instead of an encodes-as-2-bytes tagCopy1.
  while length >= 68:
    # Emit a length 64 copy, encoded as 3 bytes.
    dst[i+0] = (63 shl 2) or tagCopy2
    dst[i+1] = byte(offset and 0xFF)
    dst[i+2] = byte((offset shr 8) and 0xFF)
    inc(i, 3)
    dec(length, 64)

  if length > 64:
    # Emit a length 60 copy, encoded as 3 bytes.
    dst[i+0] = (59 shl 2) or tagCopy2
    dst[i+1] = byte(offset and 0xFF)
    dst[i+2] = byte((offset shr 8) and 0xFF)
    inc(i, 3)
    dec(length, 60)

  if (length >= 12) or (offset >= 2048):
    # Emit the remaining copy, encoded as 3 bytes.
    dst[i+0] = (byte(length-1) shl 2) or tagCopy2
    dst[i+1] = byte(offset and 0xFF)
    dst[i+2] = byte((offset shr 8) and 0xFF)
    return i + 3 - d

  # Emit the remaining copy, encoded as 2 bytes.
  dst[i+0] = byte((((offset shr 8) shl 5) or ((length-4) shl 2) or tagCopy1) and 0xFF)
  dst[i+1] = byte(offset and 0xFF)
  result = i + 2 - d

func hash(u, shift: uint32): uint32 =
  result = (u * 0x1e35a7bd) shr shift

# encodeBlock encodes a non-empty src to a guaranteed-large-enough dst. It
# assumes that the varint-encoded length of the decompressed bytes has already
# been written.
#
# It also assumes that:
#  len(dst) >= MaxEncodedLen(len(src)) and
#  minNonLiteralBlockSize <= len(src) and len(src) <= maxBlockSize
func encodeBlock*(dst: var openArray[byte], offset: int, src: openArray[byte]): int =
  # Initialize the hash table. Its size ranges from 1shl8 to 1shl14 inclusive.
  # The table element type is uint16, as s < sLimit and sLimit < len(src)
  # and len(src) <= maxBlockSize and maxBlockSize == 65536.
  const
    maxTableSize = 1 shl 14
    # tableMask is redundant, but helps the compiler eliminate bounds
    # checks.
    tableMask = maxTableSize - 1

  var
    shift = 32 - 8
    tableSize = 1 shl 8

  while tableSize < maxTableSize and tableSize < src.len:
    tableSize = tableSize * 2
    dec shift

  # In Nim, all array elements are zero-initialized, so there is no advantage
  # to a smaller tableSize per se. However, it matches the C++ algorithm,
  # and in the asm versions of this code, we can get away with zeroing only
  # the first tableSize elements.
  var table: array[maxTableSize, uint16]

  # sLimit is when to stop looking for offset/length copies. The inputMargin
  # lets us use a fast path for emitLiteral in the main loop, while we are
  # looking for copies.
  var sLimit = src.len - inputMargin
  # nextEmit is where in src the next emitLiteral should start from.
  var nextEmit = 0

  # The encoded form must start with a literal, as there are no previous
  # bytes to copy, so we start looking for hash matches at s == 1.
  var s = 1
  var nextHash = hash(fromBytesLE(uint32, src.toOpenArray(s, s+3)), shift.uint32)
  var d = offset

  template emitRemainder(): untyped =
    if nextEmit < src.len:
      d += emitLiteral(dst, d, src.toOpenArray(nextEmit, src.high))
    return d - offset

  while true:
    # Copied from the C++ snappy implementation:
    #
    # Heuristic match skipping: If 32 bytes are scanned with no matches
    # found, start looking only at every other byte. If 32 more bytes are
    # scanned (or skipped), look at every third byte, etc.. When a match
    # is found, immediately go back to looking at every byte. This is a
    # small loss (~5% performance, ~0.1% density) for compressible data
    # due to more bookkeeping, but for non-compressible data (such as
    # JPEG) it's a huge win since the compressor quickly "realizes" the
    # data is incompressible and doesn't bother looking for matches
    # everywhere.
    #
    # The "skip" variable keeps track of how many bytes there are since
    # the last match; dividing it by 32 (ie. right-shifting by five) gives
    # the number of bytes to move ahead for each iteration.
    var skip = 32

    var nextS = s
    var candidate = 0
    while true:
      s = nextS
      let bytesBetweenHashLookups = skip shr 5
      nextS = s + bytesBetweenHashLookups
      inc(skip, bytesBetweenHashLookups)
      if nextS > sLimit:
        emitRemainder()

      candidate = int(table[nextHash and tableMask])
      table[nextHash and tableMask] = uint16(s)
      nextHash = hash(fromBytesLE(uint32, src.toOpenArray(nextS, nextS+3)), shift.uint32)
      if fromBytesLE(uint32, src.toOpenArray(s, s+3)) == fromBytesLE(uint32, src.toOpenArray(candidate, candidate+3)):
        break

    # A 4-byte match has been found. We'll later see if more than 4 bytes
    # match. But, prior to the match, src[nextEmit:s] are unmatched. Emit
    # them as literal bytes.
    d += emitLiteral(dst, d, src.toOpenArray(nextEmit, s-1))

    # Call emitCopy, and then see if another emitCopy could be our next
    # move. Repeat until we find no match for the input immediately after
    # what was consumed by the last emitCopy call.
    #
    # If we exit this loop normally then we need to call emitLiteral next,
    # though we don't yet know how big the literal will be. We handle that
    # by proceeding to the next iteration of the main loop. We also can
    # exit this loop via goto if we get close to exhausting the input.
    while true:
      # Invariant: we have a 4-byte match at s, and no need to emit any
      # literal bytes prior to s.
      var base = s

      # Extend the 4-byte match as long as possible.
      #
      # This is an inlined version of:
      #  s = extendMatch(src, candidate+4, s+4)
      inc(s, 4)
      var i = candidate + 4
      while s < src.len and src[i] == src[s]:
        inc i
        inc s

      d += emitCopy(dst, d, base-candidate, s-base)
      nextEmit = s
      if s >= sLimit:
        emitRemainder()

      # We could immediately start working at s now, but to improve
      # compression we first update the hash table at s-1 and at s. If
      # another emitCopy is not our next move, also calculate nextHash
      # at s+1. At least on ARCH=amd64, these three hash calculations
      # are faster as one load64 call (with some shifts) instead of
      # three load32 calls.
      let x = fromBytesLE(uint64, src.toOpenArray(s-1, src.len-1))
      let prevHash = hash(uint32(x shr 0), shift.uint32)
      table[prevHash and tableMask] = uint16(s - 1)
      let currHash = hash(uint32(x shr 8), shift.uint32)
      candidate = int(table[currHash and tableMask])
      table[currHash and tableMask] = uint16(s)
      if uint32(x shr 8) != fromBytesLE(uint32, src.toOpenArray(candidate, candidate+3)):
        nextHash = hash(uint32(x shr 16), shift.uint32)
        inc s
        break
  result = d - offset
