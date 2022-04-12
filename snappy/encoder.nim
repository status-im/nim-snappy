import
  stew/[bitops2, byteutils, endians2, leb128, arrayops, ptrops],
  ./codec

## Internal low-level implementation of the snappy block encoder - should not be
## used directly in user code

const
  maxHashTableBits* = 14
  maxTableSize* = 1'u16 shl maxHashTableBits

template offset(p: ptr byte, offset: uint): ptr byte =
  cast[ptr byte](cast[uint](p) + offset)

func write(dst: var ptr byte, b: byte) =
  dst[] = b
  dst = dst.offset(1)

func write(dst: var ptr byte, src: ptr byte, slen: uint32) =
  copyMem(dst, src, int slen)
  dst = dst.offset(uint slen)

template load32(src: ptr byte): uint32 =
  uint32.fromBytesLE(cast[ptr UncheckedArray[byte]](src).toOpenArray(0, 3))

template load64(src: ptr byte): uint64 =
  uint64.fromBytesLE(cast[ptr UncheckedArray[byte]](src).toOpenArray(0, 7))

func tableSize(len: uint32): (uint16, uint16) =
  var
    tableSize = uint16(1 shl 8)

  while tableSize < maxTableSize and tableSize < len:
    tableSize = tableSize * 2

  (tableSize, tableSize - 1)

func hash(u: uint32, mask: uint16): uint16 =
  uint16(((u * 0x1e35a7bd'u32) shr (32 - maxHashTableBits)) and mask)

# emitLiteral writes a literal chunk and returns the number of bytes written.
#
# It assumes that:
#  dst is long enough to hold the encoded bytes
#  1 <= slen and slen <= 65536
func emitLiteral(
    dst: var ptr byte, src: var ptr byte, slen: uint32,
    fast: static bool = false) =
  let
    n = uint16(slen-1)

  if fast and slen <= 16:
    dst.write((byte(n) shl 2) or tagLiteral)

    copyMem(dst, src, 16)
    dst = dst.offset(uint slen)
    src = src.offset(uint slen)
    return

  if n < 60:
    dst.write((byte(n) shl 2) or tagLiteral)
  elif n < (1 shl 8):
    dst.write((60 shl 2) or tagLiteral)
    dst.write(byte(n))
  else:
    dst.write((61 shl 2) or tagLiteral)
    dst.write(byte(n and 0xFF))
    dst.write(byte((n shr 8) and 0xFF))

  dst.write(src, slen)
  src = src.offset(uint slen)

# emitCopy writes a copy chunk and returns the number of bytes written.
#
# It assumes that:
#  dst is long enough to hold the encoded bytes
#  1 <= offset and offset <= 65535
#  4 <= length and length <= 65535
func emitCopy(dst: var ptr byte, offset, length: uint16) =
  var
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
    dst.write((63 shl 2) or tagCopy2)
    dst.write(byte(offset))
    dst.write(byte(offset shr 8))
    dec(length, 64)

  if length > 64:
    # Emit a length 60 copy, encoded as 3 bytes.
    dst.write((59 shl 2) or tagCopy2)
    dst.write(byte(offset))
    dst.write(byte(offset shr 8))

    dec(length, 60)

  if (length >= 12) or (offset >= 2048):
    # Emit the remaining copy, encoded as 3 bytes.
    dst.write((byte(length-1) shl 2) or tagCopy2)
    dst.write(byte(offset))
    dst.write(byte(offset shr 8))
    return

  # Emit the remaining copy, encoded as 2 bytes.
  dst.write(byte((offset shr 8) shl 5) or byte((length-4) shl 2) or tagCopy1)
  dst.write(byte(offset))

when cpuEndian == bigEndian:
  {.error: "TODO: Big endian not supported".}

func findMatchLength(s1, s2, s2Limit: ptr byte, data: var uint64): uint16 =
  # Finding the longest match is a hotspot - doing so with a larger read for
  # the common case significantly speeds up the process
  var
    matched = 0'u16
    s1 = s1
    s2 = s2

  if s2.offset(16) <= s2Limit:
    let
      a1 = load64(s1)
      a2 = load64(s2)

    if a1 != a2:
      let
        xorVal = a1 xor a2
        shift = uint16(firstOne(xorVal) - 1)
        matchedBytes = shift shr 3

      data = load64(s2.offset(matchedBytes))
      return uint16 matchedBytes

    s2 = s2.offset(8)
    matched = 8

  while s2.offset(16) <= s2Limit:
    let
      a1 = load64(s1.offset(uint matched))
      a2 = load64(s2)

    if a1 == a2:
      s2 = s2.offset(8)
      matched += 8
    else:
      let
        xorVal = a1 xor a2
        shift = uint16(firstOne(xorVal) - 1)
        matchedBytes = shift shr 3
      data = load64(s2.offset(matchedBytes))
      return uint16 matched + uint16 matchedBytes

  while s2 < s2Limit:
    if s1.offset(matched)[] == s2[]:
      s2 = s2.offset(1)
      matched += 1
    else:
      if s2.offset(8) <= s2Limit:
        data = load64(s2)
      break

  matched

func encodeBlock*(input: openArray[byte], output: var openArray[byte]): int =
  ## Write one block of snappy-encoded data to output and return the number of
  ## written bytes.
  ##
  ## It is assumed `output` is large enough to hold an encoded block and more,
  ## as returned by maxCompressedLen - the implementation will assume there
  ## are additional bytes available in the output and overshoot the writes
  ## to exploit 16-byte copies on CPU:s that support them.

  # This is a pointer-heavy port of the C++ implementation - a safer approach
  # might be possible but is difficult to do in part due to poor codegen and
  # in part because of the difficulty of efficiently expressing "overlong" reads
  # and writes where more data than necessary is copied from one place to
  # another so as to exploit large memory copies as supported on modern CPU:s
  # in lieu of many small 1-byte transfers
  #
  # TODO: https://github.com/nim-lang/Nim/issues/19653

  static: doAssert maxBlockLen - 1 == uint16.high

  # Ensure we can rely on unsigned arithmetic not overflowing in general -
  # all blocks are limited to 64 kb meaning that offsets comfortably fit in
  # a 16-bit type. 32-bit types are used to simplify reasoning and avoid
  # wrapping issues.
  doAssert input.len > 0
  doAssert input.len.uint64 <= maxBlockLen.uint64

  let
    ilen = uint32 input.len

  # Check that we have lots of bytes in output, and therefore can skip all
  # bounds checks writing - `maxCompressedLen` ensures at least 32 bytes of
  # extra space, some of which will have been used up for writing the length
  # prefix - strictly, we need 16 bytes of such "spare room" in this function
  doAssert output.len.uint64 > (maxCompressedLen(ilen) - 16)

  var
    ip = unsafeAddr input[0] # Input pointer - current reading position
    op = addr output[0] # Output pointer, current writing position

  let
    baseIp = ip
    baseOp = op

    ipEnd = ip.offset(input.len)

  if ilen < minNonLiteralBlockSize:
    # We need a few bytes to work with for the optimized loops below
    emitLiteral(op, ip, ilen)
    return baseOp.distance(op)

  # Initialize the hash table. Its size ranges from 1shl8 to 1shl14 inclusive.
  # The table element type is uint16, as s < sLimit and sLimit < len(src)
  # and len(src) <= maxBlockSize and maxBlockSize == 65536.
  let
    (tableSize, tableMask) = tableSize(ilen)

  var table{.noinit.}: array[maxTableSize, uint16]
  zeroMem(addr table[0], tableSize.int * sizeof(table[0]))

  # ipLimit is when to stop looking for offset/length copies. The inputMargin
  # lets us use a fast path for `emitLiteral` in the main loop, while we are
  # looking for copies.
  static: doAssert inputMargin <= minNonLiteralBlockSize
  let
    ipLimit = ip.offset(uint(ilen - inputMargin))

  var preload = load32(ip.offset(1))

  template emitRemainder =
    if ip < ipEnd:
      emitLiteral(op, ip, uint32 ip.distance(ipEnd))
    return baseOp.distance(op)

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

    var nextEmit = ip
    ip = ip.offset(1)

    var
      data = load64(ip)
      skip = 32'u32
    var candidate: ptr byte
    block doLiteral: # After this block, a literal will have been emitted
      if (ip.distance(ipLimit) >= 16):
        let delta = uint16 baseIp.distance(ip)
        for j in 0'u8..<4'u8:
          for k in 0'u8..<4'u8:
            let i = 4 * j + k

            # These for-loops are meant to be unrolled. So we can freely
            # special case the first iteration to use the value already
            # loaded in preload.

            let dword = if i == 0: preload else: uint32 data

            let hash = hash(dword, tableMask)
            candidate = baseIp.offset(table[hash])
            table[hash] = delta + i

            if load32(candidate) == dword:
              op.write((i shl 2) or tagLiteral)
              copyMem(op, nextEmit, 16)
              ip = ip.offset(i)
              op = op.offset(i + 1)
              break doLiteral

            data = data shr 8

          data = load64(ip.offset((4*j + 4)))

        ip = ip.offset(16)
        skip += 16;

      while true:
        let hash = hash(uint32 data, tableMask)
        let bytesBetweenHashLookups = skip shr 5
        skip += bytesBetweenHashLookups
        let nextIp = ip.offset(bytesBetweenHashLookups)
        if nextIp > ipLimit:
          ip = nextEmit
          emitRemainder()

        candidate = baseIp.offset(table[hash])

        table[hash] = uint16 baseIp.distance(ip)
        if uint32(data) == load32(candidate):
          break
        data = load32(nextIp)
        ip = nextIp

      # A 4-byte match has been found. We'll later see if more than 4 bytes
      # match. But, prior to the match, src[nextEmit:s] are unmatched. Emit
      # them as literal bytes.
      emitLiteral(op, nextEmit, uint32 nextEmit.distance(ip), true)

    # Call emitCopy, and then see if another emitCopy could be our next
    # move. Repeat until we find no match for the input immediately after
    # what was consumed by the last emitCopy call.
    #
    # If we exit this loop normally then we need to call emitLiteral next,
    # though we don't yet know how big the literal will be. We handle that
    # by proceeding to the next iteration of the main loop. We also can
    # exit this loop via goto if we get close to exhausting the input.
    while true:
      # Invariant: we have a 4-byte match at ip, and no need to emit any
      # literal bytes prior to ip.
      var base = ip

      let
        matched = findMatchLength(
          candidate.offset(4), ip.offset(4), ipEnd, data) + 4
      ip = ip.offset(matched)

      emitCopy(op, uint16(candidate.distance(base)), matched)

      if ip > ipLimit:
        emitRemainder()

      # We could immediately start working at s now, but to improve
      # compression we first update the hash table at s-1 and at s. If
      # another emitCopy is not our next move, also calculate nextHash
      # at s+1. At least on ARCH=amd64, these three hash calculations
      # are faster as one load64 call (with some shifts) instead of
      # three load32 calls.
      table[hash(load32(ip.offset(-1)), tableMask)] = uint16(baseIp.distance(ip) - 1)

      let hash = hash(uint32 data, tableMask)
      candidate = baseIp.offset(table[hash])
      table[hash] = uint16 baseIp.distance(ip)

      if uint32(data) != load32(candidate):
        break
    preload = uint32(data shr 8)
  emitRemainder()

func encodeFrame*(input: openArray[byte], output: var openArray[byte]): int =
  ## Write a single frame of data using either compressed or uncompressed
  ## frames depending on whether we succeed in compressing the input
  doAssert input.len > 0 and input.len.uint64 <= maxUncompressedFrameDataLen
  let
    ilen = uint32 input.len

  doAssert output.len.uint64 >= maxCompressedLen(ilen)

  let
    # CRC is computed over the uncompressed data and appears first in the
    # frame, after the header
    crc = maskedCrc(input)
  output[4..7] = crc.toBytesLE()

  # If input is smaller than a literal, it won't compress at all
  if input.len >= minNonLiteralBlockSize:
    let
      header = ilen.toBytes(Leb128)
      headerLen = header.len
      blockLen = encodeBlock(
        input, output.toOpenArray(8 + headerLen, output.high))

    if blockLen <= (input.len - (input.len div 8)):
      # The data compressed well, we'll write it as a compressed block
      output[8..<8 + headerLen] = header.toOpenArray()

      let frameLen = headerLen + blockLen + 4 # include 4 bytes crc
      output[0] = chunkCompressed
      output[1..3] = uint32(frameLen).toBytesLE().toOpenArray(0, 2)

      return frameLen + 4

  # Compresses poorly - write uncompressed
  let
    frameLen = input.len + 4
  output[0] = chunkUncompressed
  output[1..3] = uint32(frameLen).toBytesLE().toOpenArray(0, 2)

  copyMem(addr output[8], unsafeAddr input[0], input.len)

  frameLen + 4
