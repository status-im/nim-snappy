import
  snappy/utils,
  faststreams/output_stream

const
  tagLiteral* = 0x00
  tagCopy1*   = 0x01
  tagCopy2*   = 0x02
  tagCopy4*   = 0x03

  inputMargin = 16 - 1

# PutUvarint encodes a uint64 into buf and returns the number of bytes written.
proc putUvarint(s: OutputStream, x: uint64) =
  var x = x
  while x >= 0x80'u64:
    s.append byte(x and 0xFF) or 0x80
    x = x shr 7
  s.append byte(x and 0xFF)

# Uvarint decodes a uint64 from buf and returns that value and the
# number of bytes read (> 0). If an error occurred, the value is 0
# and the number of bytes n is <= 0 meaning:
#
#  n == 0: buf too small
#  n  < 0: value larger than 64 bits (overflow)
#          and -n is the number of bytes read
#
func uvarint(buf: openArray[byte]): (uint64, int) =
  var x: uint64
  var s: uint
  for i, b in buf:
    if int(b) < 0x80:
      if (i > 9) or (i == 9) and (int(b) > 1):
        return (0'u64, -(i + 1)) # overflow
      return (x or (uint64(b) shl s), i + 1)
    x = x or (uint64(b and 0x7F) shl s)
    inc(s, 7)
  result = (0'u64, 0)

template sliceImpl(r: openArray[byte], a, b: int): auto =
  toOpenArray(cast[ptr array[0, byte]](r[0].unsafeAddr)[], a, b)

template `%`(s, i: untyped): untyped =
  (when i is BackwardsIndex: s.len - int(i) else: int(i))

template `[]`[U, V](r: openArray[byte], s: HSlice[U, V]): auto =
  sliceImpl(r, r % s.a, r % s.b)

func load32(b: openArray[byte]): uint32 {.inline.} =
  result = uint32(b[0]) or
    (uint32(b[1]) shl 8 ) or
    (uint32(b[2]) shl 16) or
    (uint32(b[3]) shl 24)

func load32(b: openArray[byte], i: int): uint32 =
  result = load32(b[i..<i+4])

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
  result = load64(b[i..<i+8])

# emitLiteral writes a literal chunk.
#
# It assumes that:
#  1 <= len(lit) and len(lit) <= 65536
proc emitLiteral(s: OutputStream, lit: openarray[byte]) =
  let n = lit.len - 1

  if n < 60:
    s.append (byte(n) shl 2) or tagLiteral
  elif n < (1 shl 8):
    s.append (60 shl 2) or tagLiteral
    s.append byte(n and 0xFF)
  else:
    s.append (61 shl 2) or tagLiteral
    s.append byte(n and 0xFF)
    s.append byte((n shr 8) and 0xFF)

  s.append lit

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
    s.append (63 shl 2) or tagCopy2
    s.append byte(offset and 0xFF)
    s.append byte((offset shr 8) and 0xFF)
    dec(length, 64)

  if length > 64:
    # Emit a length 60 copy, encoded as 3 bytes.
    s.append (59 shl 2) or tagCopy2
    s.append byte(offset and 0xFF)
    s.append byte((offset shr 8) and 0xFF)
    dec(length, 60)

  if (length >= 12) or (offset >= 2048):
    # Emit the remaining copy, encoded as 3 bytes.
    s.append byte((((length-1) shl 2) or tagCopy2) and 0xFF)
    s.append byte(offset and 0xFF)
    s.append byte((offset shr 8) and 0xFF)
    return

  s.append byte((((offset shr 8) shl 5) or ((length-4) shl 2) or tagCopy1) and 0xFF)
  s.append byte(offset and 0xFF)

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

func hash(u, shift: uint32): uint32 =
  result = (u * 0x1e35a7bd) shr shift

# encodeBlock encodes a non-empty src to a guaranteed-large-enough dst. It
# assumes that the varint-encoded length of the decompressed bytes has already
# been written.
#
# It also assumes that:
#  len(dst) >= MaxEncodedLen(len(src)) and
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
  var nextHash = hash(load32(src, s), shift.uint32)

  template emitRemainder(): untyped =
    if nextEmit < src.len:
      emitLiteral(output, src[nextEmit..^1])
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
      nextHash = hash(load32(src, nextS), shift.uint32)
      if load32(src, s) == load32(src, candidate):
        break

    # A 4-byte match has been found. We'll later see if more than 4 bytes
    # match. But, prior to the match, src[nextEmit:s] are unmatched. Emit
    # them as literal bytes.
    output.emitLiteral src[nextEmit..<s]

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
      var prevHash = hash(uint32(x shr 0), shift.uint32)
      table[prevHash and tableMask] = uint16(s - 1)
      var currHash = hash(uint32(x shr 8), shift.uint32)
      candidate = int(table[currHash and tableMask])
      table[currHash and tableMask] = uint16(s)
      if uint32(x shr 8) != load32(src, candidate):
        nextHash = hash(uint32(x shr 16), shift.uint32)
        inc s
        break

const
  decodeErrCodeCorrupt = 1
  decodeErrCodeUnsupportedLiteralLength = 2

func decode(dst, src: var openArray[byte]): int =
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

      copyMem(dst[d].addr, src[s].addr, length)
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

const
  maxBlockSize = 65536

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
  let n = maxEncodedLen(src.len)
  if n == 0: return

  # The block starts with the varint-encoded length of the decompressed bytes.
  var
    p = 0
    len = src.len

  s.putUVarInt uint64(src.len)

  while len > 0:
    var blockSize = len
    if blockSize > maxBlockSize:
      blockSize = maxBlockSize

    if blockSize < minNonLiteralBlockSize:
      s.emitLiteral src[p..<p+blockSize]
    else:
      s.encodeBlock src[p..<p+blockSize]

    inc(p, blockSize)
    dec(len, blockSize)

let SnappyStreamVTable = OutputStreamVTable(
  writePageSync: proc (s: OutputStream, data: openarray[byte])
                      {.nimcall, gcsafe, raises: [IOError, Defect].} =
    encodeBlock(LayeredOutputStream(s).subStream, data)
  ,
  flushSync: proc (s: OutputStream)
                  {.nimcall, gcsafe, raises: [IOError, Defect].} =
    flush LayeredOutputStream(s).subStream
)

func snappyOutputStream*(targetStream: OutputStream): OutputStreamHandle =
  var stream = LayeredOutputStream(
    vtable: vtableAddr(SnappyStreamVTable),
    pageSize: maxBlockSize,
    maxWriteSize: maxBlockSize,
    subStream: targetStream)

  stream.initWithSinglePage()

  OutputStreamHandle(s: stream)

# Encode returns the encoded form of src.
func encode*(src: openarray[byte]): seq[byte] =
  let n = maxEncodedLen(src.len)
  if n == 0: return
  result = newSeq[byte](n)
  {.noSideEffect.}:
    # We assume no side-effects here, because we are working
    # with a `memoryOutput`. The computed side-effects differ
    # because the code of the SnappyStream may be used to write
    # to a file or a network device as well.
    var memOutput = memoryOutput(addr result[0], result.len)
    memOutput.putUVarInt uint64(src.len)
    var snappyStream = snappyOutputStream(memOutput)
    snappyStream.append src
    snappyStream.flush
  result.setLen memOutput.pos

# decodedLen returns the length of the decoded block and the number of bytes
# that the length header occupied.
func decode*(src: openArray[byte]): seq[byte] =
  let (len, bytesRead) = uvarint(src)
  if bytesRead <= 0 or len > 0xffffffff'u64:
    return

  const wordSize = sizeof(uint) * 8
  if (wordSize == 32) and (len > 0x7fffffff'u64):
    return

  if int(len) > 0:
    result = newSeq[byte](len)
    let errCode = decode(result, src[bytesRead..^1])
    if errCode != 0: result = @[]

proc snappyUncompress*(src: openArray[byte], dst: var openArray[byte]): int =
  let (len, bytesRead) = uvarint(src)
  if bytesRead <= 0 or len > 0xffffffff'u64:
    return

  const wordSize = sizeof(uint) * 8
  if (wordSize == 32) and (len > 0x7fffffff'u64):
    return

  if dst.len < int(len):
    return

  if int(len) > 0:
    let errCode = decode(dst.toOpenArray(0, len.int-1), src[bytesRead..^1])
    if errCode != 0:
      return

  result = int(len)

template compress*(src: openArray[byte]): seq[byte] =
  snappy.encode(src)

template uncompress*(src: openArray[byte]): seq[byte] =
  snappy.decode(src)
