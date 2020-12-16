import
  stew/[leb128, ranges/ptr_arith],
  faststreams/[inputs, outputs, buffers, multisync],
  snappy/types

export
  types

const
  tagLiteral* = 0x00
  tagCopy1*   = 0x01
  tagCopy2*   = 0x02
  tagCopy4*   = 0x03

  inputMargin = 16 - 1

  maxHashTableBits = 14

func load32(b: openArray[byte]): uint32 {.inline.} =
  result = uint32(b[0]) or
    (uint32(b[1]) shl 8 ) or
    (uint32(b[2]) shl 16) or
    (uint32(b[3]) shl 24)

func load32(b: openArray[byte], i: int): uint32 =
  result = load32(b.toOpenArray(i, i + 4 - 1))

func load64(b: openArray[byte]): uint64 {.inline.} =
  result = uint64(b[0]) or
    (uint64(b[1]) shl 8 ) or
    (uint64(b[2]) shl 16) or
    (uint64(b[3]) shl 24) or
    (uint64(b[4]) shl 32) or
    (uint64(b[5]) shl 40) or
    (uint64(b[6]) shl 48) or
    (uint64(b[7]) shl 56)

func load64(b: openArray[byte], i: int): uint64 =
  result = load64(b.toOpenArray(i, i + 8 - 1))

# emitLiteral writes a literal chunk.
#
# It assumes that:
#  1 <= len(lit) and len(lit) <= 65536
proc emitLiteral(s: OutputStream, lit: openarray[byte]) =
  let n = lit.len - 1

  if n < 60:
    s.write (byte(n) shl 2) or tagLiteral
  elif n < (1 shl 8):
    s.write (60 shl 2) or tagLiteral
    s.write byte(n and 0xFF)
  else:
    s.write (61 shl 2) or tagLiteral
    s.write byte(n and 0xFF)
    s.write byte((n shr 8) and 0xFF)

  s.writeAndWait lit

# emitCopy writes a copy chunk.
#
# It assumes that:
#  1 <= offset and offset <= 65535
#  4 <= length and length <= 65535
proc emitCopy(s: OutputStream, offset, length: int) =
  var length = length
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
    s.write (63 shl 2) or tagCopy2
    s.write byte(offset and 0xFF)
    s.write byte((offset shr 8) and 0xFF)
    dec(length, 64)

  if length > 64:
    # Emit a length 60 copy, encoded as 3 bytes.
    s.write (59 shl 2) or tagCopy2
    s.write byte(offset and 0xFF)
    s.write byte((offset shr 8) and 0xFF)
    dec(length, 60)

  if (length >= 12) or (offset >= 2048):
    # Emit the remaining copy, encoded as 3 bytes.
    s.write byte((((length-1) shl 2) or tagCopy2) and 0xFF)
    s.write byte(offset and 0xFF)
    s.write byte((offset shr 8) and 0xFF)
    return

  s.write byte((((offset shr 8) shl 5) or ((length-4) shl 2) or tagCopy1) and 0xFF)
  s.write byte(offset and 0xFF)

when false:
  # extendMatch returns the largest k such that k <= len(src) and that
  # src[i:i+k-j] and src[j:k] have the same contents.
  #
  # It assumes that:
  #  0 <= i and i < j and j <= len(src)
  func extendMatch(src: openArray[byte], i, j: int): int =
    var
      i = i
      j = j
    while j < src.len and src[i] == src[j]:
      inc i
      inc j
    result = j

func hash(bytes, mask: uint32): uint32 =
  result = ((bytes * 0x1e35a7bd) shr (32 - maxHashTableBits)) and mask

# encodeBlock encodes a non-empty src to a guaranteed-large-enough dst. It
# assumes that the varint-encoded length of the decompressed bytes has already
# been written.
#
# It also assumes that:
#  len(dst) >= maxCompressedLen(len(src)) and
#  minNonLiteralBlockSize <= len(src) and len(src) <= maxBlockSize
proc encodeBlock(output: OutputStream, src: openArray[byte]) =
  # Initialize the hash table. Its size ranges from 1shl8 to 1shl14 inclusive.
  # The table element type is uint16, as s < sLimit and sLimit < len(src)
  # and len(src) <= maxBlockSize and maxBlockSize == 65536.
  const
    maxTableSize = 1 shl 14
    # tableMask is redundant, but helps the compiler eliminate bounds
    # checks.
    tableMask = maxTableSize - 1

  var tableSize = 1 shl 8
  while tableSize < maxTableSize and tableSize < src.len:
    tableSize = tableSize * 2

  let mask = (tableSize - 1).uint32

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
  var nextHash = hash(load32(src, s), mask)

  template emitRemainder(): untyped =
    if nextEmit < src.len:
      emitLiteral(output, src.toOpenArray(nextEmit, src.high))
    return

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
      nextHash = hash(load32(src, nextS), mask)
      if load32(src, s) == load32(src, candidate):
        break

    # A 4-byte match has been found. We'll later see if more than 4 bytes
    # match. But, prior to the match, src[nextEmit:s] are unmatched. Emit
    # them as literal bytes.
    output.emitLiteral src.toOpenArray(nextEmit, s - 1)

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

      output.emitCopy(base-candidate, s-base)
      nextEmit = s
      if s >= sLimit:
        emitRemainder()

      # We could immediately start working at s now, but to improve
      # compression we first update the hash table at s-1 and at s. If
      # another emitCopy is not our next move, also calculate nextHash
      # at s+1. At least on ARCH=amd64, these three hash calculations
      # are faster as one load64 call (with some shifts) instead of
      # three load32 calls.
      var x = load64(src, s-1)
      var prevHash = hash(uint32(x shr 0), mask)
      table[prevHash and tableMask] = uint16(s - 1)
      var currHash = hash(uint32(x shr 8), mask)
      candidate = int(table[currHash and tableMask])
      table[currHash and tableMask] = uint16(s)
      if uint32(x shr 8) != load32(src, candidate):
        nextHash = hash(uint32(x shr 16), mask)
        inc s
        break

const
  decodeErrCodeCorrupt = 1
  decodeErrCodeUnsupportedLiteralLength = 2

func decode(dst: var openArray[byte], src: openArray[byte]): int =
  var
    d = 0
    s = 0
    offset = 0
    length = 0

  while s < src.len:
    let tag = src[s] and 0x03
    case tag
    of tagLiteral:
      var x = int(src[s]) shr 2
      if x < 60:
        inc s
      elif x == 60:
        inc(s, 2)
        if s > src.len:
          return decodeErrCodeCorrupt
        x = int(src[s-1])
      elif x == 61:
        inc(s, 3)
        if s > src.len:
          return decodeErrCodeCorrupt
        x = int(src[s-2]) or (int(src[s-1]) shl 8)
      elif x == 62:
        inc(s, 4)
        if s > src.len:
          return decodeErrCodeCorrupt
        x = int(src[s-3]) or (int(src[s-2]) shl 8) or (int(src[s-1]) shl 16)
      elif x == 63:
        inc(s, 5)
        if s > src.len:
          return decodeErrCodeCorrupt
        x = int(src[s-4]) or (int(src[s-3]) shl 8) or (int(src[s-2]) shl 16) or (int(src[s-1]) shl 24)
      length = x + 1
      if length <= 0:
        return decodeErrCodeUnsupportedLiteralLength

      if (length > (dst.len-d)) or (length > (src.len-s)):
        return decodeErrCodeCorrupt

      copyMem(addr dst[d], unsafeAddr src[s], length)
      inc(d, length)
      inc(s, length)
      continue

    of tagCopy1:
      inc(s, 2)
      if s > src.len:
        return decodeErrCodeCorrupt
      length = 4 + ((int(src[s-2]) shr 2) and 0x07)
      offset = ((int(src[s-2]) and 0xe0) shl 3) or int(src[s-1])

    of tagCopy2:
      s += 3
      if s > src.len:
        return decodeErrCodeCorrupt
      length = 1 + (int(src[s-3]) shr 2)
      offset = int(src[s-2]) or (int(src[s-1]) shl 8)

    of tagCopy4:
      s += 5
      if s > src.len:
        return decodeErrCodeCorrupt
      length = 1 + (int(src[s-5]) shr 2)
      offset = int(src[s-4]) or (int(src[s-3]) shl 8) or (int(src[s-2]) shl 16) or (int(src[s-1]) shl 24)

    else: discard

    if offset <= 0 or d < offset or (length > (dst.len-d)):
      return decodeErrCodeCorrupt

    # Copy from an earlier sub-slice of dst to a later sub-slice. Unlike
    # the built-in copy function, this byte-by-byte copy always runs
    # forwards, even if the slices overlap. Conceptually, this is:
    #
    # d += forwardCopy(dst[d:d+length], dst[d-offset:])
    var stop = d + length
    while d != stop:
      dst[d] = dst[d-offset]
      inc d

  if d != dst.len:
    return decodeErrCodeCorrupt
  return 0

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
  minNonLiteralBlockSize = 1 + 1 + inputMargin

# Encode returns the encoded form of src. The returned slice may be a sub-
# slice of dst if dst was large enough to hold the entire encoded block.
# Otherwise, a newly allocated slice will be returned.
#
# The dst and src must not overlap. It is valid to pass a nil dst.
proc appendSnappyBytes*(s: OutputStream, src: openArray[byte]) =
  var
    lenU32 = checkInputLen(src.len)
    p = 0

  # The block starts with the varint-encoded length of the decompressed bytes.
  s.write lenU32.toBytes(Leb128).toOpenArray()

  while lenU32 > maxBlockSize.uint32:
    s.encodeBlock src.toOpenArray(p, p + maxBlockSize)
    p += maxBlockSize
    lenU32 -= maxBlockSize.uint32

  # The `lenU32.int` expressions below cannot overflow because
  # `lenU32` is already less than `maxBlockSize` here:
  if lenU32 < minNonLiteralBlockSize.uint32:
    s.emitLiteral src.toOpenArray(p, p + lenU32.int)
  else:
    s.encodeBlock src.toOpenArray(p, p + lenU32.int)

proc snappyCompress*(input: InputStream, output: OutputStream) =
  try:
    let inputLen = input.len
    if inputLen.isSome:
      let lenU32 = checkInputLen(inputLen.get)
      output.ensureRunway maxCompressedLen(lenU32)
      output.write lenU32.toBytes(Leb128).toOpenArray()
    else:
      # TODO: This is a temporary limitation
      doAssert false, "snappy requires an input stream with a known length"

    while input.readable(maxBlockSize):
      encodeBlock(output, input.read(maxBlockSize))

    let remainingBytes = input.totalUnconsumedBytes
    if remainingBytes > 0:
      if remainingBytes < minNonLiteralBlockSize:
        output.emitLiteral input.read(remainingBytes)
      else:
        output.encodeBlock input.read(remainingBytes)
  finally:
    close output

# Encode returns the encoded form of src.
func encode*(src: openarray[byte]): seq[byte] =
  # Memory streams doesn't have side effects:
  {.noSideEffect.}:
    let output = memoryOutput()
    snappyCompress(unsafeMemoryInput(src), output)
    output.getOutput

func decode*(src: openArray[byte], maxSize = 0xffffffff'u32): seq[byte] =
  let (lenU32, bytesRead) = uint32.fromBytes(src, Leb128)
  if bytesRead <= 0 or lenU32 > maxSize:
    return

  if lenU32 > 0:
    when sizeof(uint) == 4:
      if lenU32 > 0x7fffffff'u32:
        return
    # `lenU32.int` cannot overflow because of the extra check above
    result = newSeq[byte](lenU32.int)
    let errCode = decode(result, src.toOpenArray(bytesRead, src.len - 1))
    if errCode != 0: result = @[]

proc snappyUncompress*(src: openArray[byte], dst: var openArray[byte]): uint32 =
  let (uncompressedLen, bytesRead) = uint32.fromBytes(src, Leb128)
  if bytesRead <= 0 or uncompressedLen.BiggestUInt > dst.len.BiggestUInt:
    return 0

  if uncompressedLen > 0:
    # `result.int` cannot overflow here, because we've already
    # checked that it's smaller than the `dst.len` which is an int.
    let errCode = decode(dst.toOpenArray(0, uncompressedLen.int - 1),
                         src.toOpenArray(bytesRead, src.len - 1))
    if errCode != 0:
      return 0

  return uncompressedLen

