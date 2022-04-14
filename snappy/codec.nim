import
  stew/[endians2, leb128, results]

export endians2, leb128, results

const
  maxUncompressedLen* = 0xffffffff'u32
    ## Maximum uncompressed length supported by the simple snappy block format -
    ## use the framed encoding to compress more data

  maxBlockLen* = 65536'u32
    ## Although snappy in theory support larger block sizes, we use the same
    ## block size as the C++ implementation.

  maxUncompressedFrameDataLen* = 65536'u32
    ## The maximum amount of uncompressed data that may fit in a single frame

  tagLiteral* = 0x00
  tagCopy1*   = 0x01
  tagCopy2*   = 0x02
  tagCopy4*   = 0x03

  inputMargin* = 16 - 1

  # Chunk types for framed format
  chunkCompressed*   = 0x00
  chunkUncompressed* = 0x01
  chunkStream*       = 0xff

  framingHeader* =
    [byte 0xff, 0x06, 0x00, 0x00, 0x73, 0x4e, 0x61, 0x50, 0x70, 0x59]

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
# https://groups.google.com/d/topic/snappy-compression/oGbhsdIJSJ8/discussion
# The difference between Nim (2+inputMargin) and C++ (inputMargin) is purely an
# optimization. It should not affect the encoded form. This is tested by
# TestSameEncodingAsCppShortCopies.
  minNonLiteralBlockSize* = 1 + 1 + inputMargin

type
  CodecError* {.pure.} = enum
    bufferTooSmall
    invalidInput

  FrameError* {.pure.} = enum
    bufferTooSmall
    invalidInput
    crcMismatch
    unknownChunk

{.compile: "crc32c.c".}
# TODO: we don't have a native implementation of CRC32C algorithm yet.
#       we can't use nimPNG CRC32
proc masked_crc32c(buf: ptr byte, len: uint): cuint {.cdecl, importc.}

func maskedCrc*(data: openArray[byte]): uint32 =
  if data.len == 0:
    masked_crc32c(nil, 0)
  else:
    masked_crc32c(unsafeAddr data[0], data.len.uint)

func checkCrc*(data: openArray[byte], expected: uint32): bool =
  let actual = maskedCrc(data)
  actual == expected

func checkInputLen*(inputLen: uint64): Opt[uint32] =
  static: doAssert uint32.high.uint64 <= maxUncompressedLen.uint64
  if inputLen > maxUncompressedLen.uint64:
    err()
  else:
    ok(inputLen.uint32)

func checkInputLen*(inputLen: int): Opt[uint32] =
  static: doAssert uint32.high.uint64 <= maxUncompressedLen.uint64
  checkInputLen(inputLen.uint64)

func maxCompressedLen*(srcLen: uint32): uint64 =
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
  let
    n = srcLen.uint64
    max = 32'u64 + n + n div 6'u64
  max

func maxCompressedLen*(inputLen: int): Opt[uint64] =
  if inputLen.uint64 > maxUncompressedLen.uint64:
    err()
  else:
    static: doAssert uint32.high.uint64 <= maxUncompressedLen.uint64
    ok(maxCompressedLen(inputLen.uint32))

func uncompressedLen*(input: openArray[byte]): Opt[uint32] =
  ## Read the uncompressed length from a stream - at least the first 5
  ## bytes of the compressed input must be given
  ## `uint32` is used because the length may not fit in an `int`
  ## on 32-bit machines.
  let (lenU32, bytesRead) = fromBytes(uint32, input, Leb128)
  if bytesRead <= 0:
    err()
  else:
    ok(lenU32)

func maxCompressedLenFramed*(inputLen: int64): uint64 =
  ## The maximum number of bytes a compressed framed snappy stream will occupy,
  ## including scratch space used during compression.
  const
    # Frames that don't compress well will be written uncompressed which caps
    # the output size to the input size plus header
    maxFrameLen = maxUncompressedFrameDataLen + 8

  if inputLen <= 0:
    return framingHeader.len

  let
    # At least one frame..
    frames = (inputLen.uint64 + maxUncompressedFrameDataLen - 1) div
      maxUncompressedFrameDataLen
    maxFramesLen =
      # When encoding frames, we need the last frame to be large enough to
      # accomodate the compression overhead so that we can attempt compression -
      # as a simplification, we make compute the buffer for a full frame (so
      # that we have enough space for compressing the second last frame even
      # when the last frame is small)
      ((frames - 1) * maxFrameLen) +
        maxCompressedLen(maxUncompressedFrameDataLen) + 8

  maxFramesLen + framingHeader.len

func decodeFrameHeader*(input: openArray[byte]): tuple[id: byte, len: int] =
  doAssert input.len >= 4
  let
    header = uint32.fromBytesLE(input)
    id = byte(header and 0xff)
    dataLen = int(header shr 8)
  (id, dataLen)

func uncompressedLenFramed*(input: openArray[byte]): Opt[uint64] =
  var
    read = 0
    expected = 0'u64

  while (let remaining = input.len - read; remaining > 0):
    if remaining < 4:
      return

    let
      (id, dataLen) = decodeFrameHeader(input.toOpenArray(read, read + 3))

    if remaining < dataLen + 4:
      return

    read += 4

    let uncompressed =
      if id == chunkCompressed:
        uncompressedLen(input.toOpenArray(read + 4, read + dataLen - 1)).valueOr:
          return
      elif id == chunkUncompressed: uint32(dataLen - 4)
      elif id < 0x80: return # Reserved unskippable chunk
      else: 0'u32 # Reserved skippable (for example framing format header)

    if uncompressed > maxUncompressedFrameDataLen:
      return # Uncomnpressed data has limits (for the known chunk types)

    expected += uncompressed
    read += dataLen

  ok(expected)

const
  maxCompressedBlockLen* = maxCompressedLen(maxBlockLen).uint32
  maxCompressedFrameDataLen* =
    maxCompressedLen(maxUncompressedFrameDataLen).uint32
