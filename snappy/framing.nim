import
  faststreams/[inputs, outputs, multisync],
  stew/[endians2, leb128, arrayops],
  ../snappy, types, ./encoder

export
  types

{.compile: "crc32c.c".}
# TODO: we don't have a native implementation of CRC32C algorithm yet.
#       we can't use nimPNG CRC32
proc masked_crc32c(buf: ptr byte, len: uint): cuint {.cdecl, importc.}

func checkCrc*(data: openArray[byte], expected: uint32): bool =
  let startPtr = if data.len == 0: nil else: data[0].unsafeAddr
  let actual = masked_crc32c(startPtr, data.len.uint)
  result = actual == expected

proc checkCrcAndAppend*(output: OutputStream, data: openArray[byte], crc: uint32): bool =
  if checkCrc(data, crc):
    output.write(data)
    return true

const
  # maximum chunk data length
  # MAX_DATA_LEN                 = 16777215
  # maximum uncompressed data length excluding checksum
  MAX_UNCOMPRESSED_DATA_LEN*    = 65536
  # maximum uncompressed data length excluding checksum
  MAX_COMPRESSED_DATA_LEN*      = int maxCompressedLen(MAX_UNCOMPRESSED_DATA_LEN)

  COMPRESSED_DATA_IDENTIFIER*   = 0x00
  UNCOMPRESSED_DATA_IDENTIFIER* = 0x01
  STREAM_IDENTIFIER*            = 0xff

  STREAM_HEADER*                = "\xff\x06\x00\x00sNaPpY"

proc uncompressFramedStream*(input: InputStream, output: OutputStream) {.fsMultiSync.} =
  try:
    if not input.readable(STREAM_HEADER.len):
      raise newException(UnexpectedEofError, "Failed to read strean header")

    if input.read(STREAM_HEADER.len) != STREAM_HEADER.toOpenArrayByte(0, STREAM_HEADER.len-1):
      raise newException(MalformedSnappyData, "Invalid header value")

    var uncompressedData = newSeq[byte](MAX_UNCOMPRESSED_DATA_LEN)

    while input.readable(4):
      let x = uint32.fromBytesLE input.read(4)
      let id = x and 0xFF
      let dataLen = int(x shr 8)

      if dataLen > MAX_COMPRESSED_DATA_LEN:
        raise newException(MalformedSnappyData, "Invalid frame length")

      if not input.readable(dataLen):
        raise newException(UnexpectedEofError, "Failed to read the entire snappy frame")

      if id == COMPRESSED_DATA_IDENTIFIER:
        if dataLen < 4:
          raise newException(MalformedSnappyData, "Frame size too low to contain CRC checksum")

        let
          crc = uint32.fromBytesLE input.read(4)
          uncompressedLen = int snappyUncompress(input.read(dataLen - 4), uncompressedData)

        if uncompressedLen <= 0:
          raise newException(MalformedSnappyData, "Failed to decompress content")

        if not checkCrcAndAppend(Sync output, uncompressedData.toOpenArray(0, uncompressedLen-1), crc):
          raise newException(MalformedSnappyData, "Content CRC checksum failed")

      elif id == UNCOMPRESSED_DATA_IDENTIFIER:
        if dataLen < 4:
          raise newException(MalformedSnappyData, "Frame size too low to contain CRC checksum")

        let crc = uint32.fromBytesLE(input.read(4))
        if not checkCrcAndAppend(Sync output, input.read(dataLen - 4), crc):
          raise newException(MalformedSnappyData, "Content CRC checksum failed")

      elif id < 0x80:
        # Reserved unskippable chunks (chunk types 0x02-0x7f)
        # if we encounter this type of chunk, stop decoding
        # the spec says it is an error
        raise newException(MalformedSnappyData, "Invalid chunk type")

      else:
        # Reserved skippable chunks (chunk types 0x80-0xfe)
        # including STREAM_HEADER (0xff) should be skipped
        input.advance dataLen
  finally:
    close output

proc framingFormatUncompress*(input: InputStream): seq[byte] =
  var output = memoryOutput()
  uncompressFramedStream input, output
  return output.getOutput

proc framingFormatUncompress*(input: openarray[byte]): seq[byte] =
  framingFormatUncompress unsafeMemoryInput(input)

proc processFrame*(output: OutputStream, dst: var openArray[byte], src: openArray[byte]) =
  let
    crc = masked_crc32c(src[0].unsafeAddr, src.len.uint)
    leb128 = uint32(src.len).toBytes(Leb128)
    varintLen = int(leb128.len)

  dst[0..<varintLen] = leb128.toOpenArray()

  let
    encodedLen = encoder.encodeBlock(dst, varintLen, src) + varintLen

  if encodedLen >= (src.len - (src.len div 8)):
    let frameLen = src.len + 4 # include 4 bytes crc
    let header = (uint32(frameLen) shl 8) or UNCOMPRESSED_DATA_IDENTIFIER.uint32
    output.write toBytesLE(header)
    output.write toBytesLE(crc)
    output.write src
  else:
    let frameLen = encodedLen + 4 # include 4 bytes crc
    let header = (uint32(frameLen) shl 8) or COMPRESSED_DATA_IDENTIFIER.uint32
    output.write toBytesLE(header)
    output.write toBytesLE(crc)
    output.write dst.toOpenArray(0, encodedLen-1)

proc framingFormatCompress*(output: OutputStream, src: openArray[byte]) =
  const maxFrameSize = MAX_UNCOMPRESSED_DATA_LEN
  var compressedData = newSeq[byte](MAX_COMPRESSED_DATA_LEN)

  # write the magic identifier
  output.write(STREAM_HEADER)

  var
    p = 0
    len = src.len

  while len > 0:
    let frameSize = min(len, maxFrameSize)
    processFrame(output, compressedData, src.toOpenArray(p, p+frameSize-1))
    inc(p, frameSize)
    dec(len, frameSize)

  output.flush()

proc framingFormatCompress*(src: openArray[byte]): seq[byte] =
  var output = memoryOutput()
  framingFormatCompress(output, src)
  return output.getOutput

