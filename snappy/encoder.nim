import
  stew/[bitops2, byteutils, endians2, leb128, arrayops, ptrops],
  ./codec

## Internal low-level implementation of the snappy block encoder - should not be
## used directly in user code

const
  maxHashTableBits = 14
  maxTableSize = 1'u16 shl maxHashTableBits

# These load templates assume there is enough data to read at the margin, which
# the code ensures via manual range checking - the built-in range check adds 40%
# execution time
template load32(input: openArray[byte], offsetParam: int): uint32 =
  let offset = offsetParam
  uint32.fromBytesLE(
    cast[ptr UncheckedArray[byte]](input).toOpenArray(offset, offset + 3))

template load64(input: openArray[byte], offsetParam: int): uint64 =
  let offset = offsetParam
  uint64.fromBytesLE(
    cast[ptr UncheckedArray[byte]](input).toOpenArray(offset, offset + 7))

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
    dst: var openArray[byte], src: openArray[byte], fast: static bool = false): int =
  let
    slen = src.len
    n = uint16(slen) - 1

  when fast:
    if slen <= 16:
      dst[0] = (byte(n) shl 2) or tagLiteral
      copyMem(addr dst[1], unsafeAddr src[0], 16)

      return slen + 1

  let w =
    if n < 60:
      dst[0] = (byte(n) shl 2) or tagLiteral
      1
    elif n < (1 shl 8):
      dst[0] = byte(60 shl 2) or tagLiteral
      dst[1] = byte(n)
      2
    else:
      dst[0] = byte(61 shl 2) or tagLiteral
      dst[1] = byte(n and 0xFF)
      dst[2] = byte((n shr 8) and 0xFF)
      3

  dst[w..<w+slen] = src

  slen + w

# emitCopy writes a copy chunk and returns the number of bytes written.
#
# It assumes that:
#  dst is long enough to hold the encoded bytes
#  1 <= offset and offset <= 65535
#  4 <= length and length <= 65535
func emitCopy(dst: var openArray[byte], offset, length: uint16): int =
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

  var w = 0
  while length >= 68:
    # Emit a length 64 copy, encoded as 3 bytes.
    dst[w] = byte(63 shl 2) or tagCopy2
    dst[w + 1] = byte(offset)
    dst[w + 2] = byte(offset shr 8)
    w += 3
    dec(length, 64)

  if length > 64:
    # Emit a length 60 copy, encoded as 3 bytes.
    dst[w] = byte(59 shl 2) or tagCopy2
    dst[w + 1] = byte(offset)
    dst[w + 2] = byte(offset shr 8)

    dec(length, 60)
    w += 3

  if (length >= 12) or (offset >= 2048):
    # Emit the remaining copy, encoded as 3 bytes.
    dst[w] = (byte(length - 1) shl 2) or tagCopy2
    dst[w + 1] = byte(offset)
    dst[w + 2] = byte(offset shr 8)

    return w + 3

  # Emit the remaining copy, encoded as 2 bytes.
  dst[w] = byte((offset shr 8) shl 5) or byte((length-4) shl 2) or tagCopy1
  dst[w + 1] = byte(offset)

  w + 2

when cpuEndian == bigEndian:
  {.error: "TODO: Big endian not supported".}

template findMatchLength(input: openArray[byte], s1Param, s2Param: int, data: var uint64): uint16 =
  # Finding the longest match is a hotspot - doing so with a larger read for
  # the common case significantly speeds up the process
  var
    matched = 0'u16
    s1 = s1Param
    s2 = s2Param
  block find:
    if s2 + 16 <= input.len:
      let
        a1 = load64(input, s1)
        a2 = load64(input, s2)

      if a1 != a2:
        let
          xorVal = a1 xor a2
          shift = uint16(firstOne(xorVal) - 1)
          matchedBytes = shift shr 3

        data = load64(input, s2 + int matchedBytes)
        matched = matchedBytes
        break find

      s2 += 8
      matched = 8

    while s2 + 16 <= input.len:
      let
        a1 = load64(input, s1 + int matched)
        a2 = load64(input, s2)

      if a1 == a2:
        s2 += 8
        matched += 8
      else:
        let
          xorVal = a1 xor a2
          shift = uint16(firstOne(xorVal) - 1)
          matchedBytes = shift shr 3
        data = load64(input, s2 + int matchedBytes)
        matched += matchedBytes
        break find

    while s2 < input.len:
      if input[s1 + int matched] == input[s2]:
        s2 += 1
        matched += 1
      else:
        if s2 + 8 <= input.len:
          data = load64(input, s2)
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
  doAssert uint(input.len) > (uint 0)
  doAssert input.len.uint64 <= maxBlockLen.uint64
  let
    ilen32 = uint32 input.len

  # Check that we have lots of bytes in output, and therefore can skip all
  # bounds checks writing - `maxCompressedLen` ensures at least 32 bytes of
  # extra space, some of which will have been used up for writing the length
  # prefix - strictly, we need 16 bytes of such "spare room" in this function
  doAssert output.len.uint64 > (maxCompressedLen(ilen32) - 16)

  var
    ip = 0 # unsafeAddr input[0] # Input pointer - current reading position
    op = 0 # addr output[0] # Output pointer, current writing position

  let
    opHigh = output.high
    ipHigh = input.high

  if ilen32 < minNonLiteralBlockSize:
    # We need a few bytes to work with for the optimized loops below
    return emitLiteral(output, input)

  # Initialize the hash table. Its size ranges from 1shl8 to 1shl14 inclusive.
  # The table element type is uint16, as s < sLimit and sLimit < len(src)
  # and len(src) <= maxBlockSize and maxBlockSize == 65536.
  let
    (tableSize, tableMask) = tableSize(ilen32)

  var table{.noinit.}: array[maxTableSize, uint16]
  zeroMem(addr table[0], tableSize.int * sizeof(table[0]))

  # ipLimit is when to stop looking for offset/length copies. The inputMargin
  # lets us use a fast path for `emitLiteral` in the main loop, while we are
  # looking for copies.
  static: doAssert inputMargin <= minNonLiteralBlockSize
  let
    ipLimit = input.len - inputMargin

  var preload = load32(input, ip + 1)

  template emitRemainder =
    if ip < input.len:
      op += emitLiteral(
        output.toOpenArray(op, opHigh), input.toOpenArray(ip, ipHigh))
    return op

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
    ip += 1

    var
      data = load64(input, ip)
      skip = 32'u32
      candidate: uint16

    block doLiteral: # After this block, a literal will have been emitted
      if (ipLimit >= ip + 16):
        let delta = uint16 ip
        for j in 0'u8..<4'u8:
          for k in 0'u8..<4'u8:
            # These for-loops are meant to be unrolled. So we can freely
            # special case the first iteration to use the value already
            # loaded in preload.
            let
              i = 4 * j + k
              dword = if i == 0: preload else: uint32 data
              hash = hash(dword, tableMask)

            candidate = table[hash]
            table[hash] = delta + i

            if load32(input, int candidate) == dword:
              output[op] = byte(i shl 2) or tagLiteral
              copyMem(addr output[op + 1], unsafeAddr input[nextEmit], 16)

              ip += int i
              op += int i + 2
              break doLiteral

            data = data shr 8

          data = load64(input, ip + int((4*j + 4)))

        ip += 16
        skip += 16

      while true:
        let
          hash = hash(uint32 data, tableMask)
          bytesBetweenHashLookups = skip shr 5

        skip += bytesBetweenHashLookups

        let nextIp = ip + int bytesBetweenHashLookups
        if nextIp > ipLimit:
          ip = nextEmit
          emitRemainder()

        candidate = table[hash]

        table[hash] = uint16 ip

        if uint32(data) == load32(input, int candidate):
          break

        data = load32(input, nextIp)
        ip = nextIp

      # A 4-byte match has been found. We'll later see if more than 4 bytes
      # match. But, prior to the match, src[nextEmit:ip] are unmatched. Emit
      # them as literal bytes.
      op += emitLiteral(
        output.toOpenArray(op, opHigh),
        input.toOpenArray(nextEmit, ip - 1), true)

      nextEmit = ip

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
      let base = uint16 ip

      let
        matched = findMatchLength(input, int candidate + 4, ip + 4, data) + 4

      ip += int matched
      op += emitCopy(
        output.toOpenArray(op, opHigh), base - candidate, matched)

      if ip > ipLimit:
        emitRemainder()

      # We could immediately start working at s now, but to improve
      # compression we first update the hash table at s-1 and at s. If
      # another emitCopy is not our next move, also calculate nextHash
      # at s+1. At least on ARCH=amd64, these three hash calculations
      # are faster as one load64 call (with some shifts) instead of
      # three load32 calls.
      table[hash(load32(input, ip - 1), tableMask)] = uint16(ip - 1)

      let
        hash = hash(uint32 data, tableMask)

      candidate = table[hash]
      table[hash] = uint16 ip

      if uint32(data) != load32(input, int candidate):
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
  output[8..<8 + input.len] = input

  frameLen + 4
