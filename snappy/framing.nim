import
  ../snappy, ../snappy/utils,
  ../tests/openarrays_snappy as oas,
  faststreams/[output_stream, input_stream],
  stew/endians2

{.compile: "crc32c.c".}
# TODO: we don't have a native implementation of CRC32C algorithm yet.
#       we can't use nimPNG CRC32
proc masked_crc32c(buf: ptr byte, len: uint): cuint {.cdecl, importc.}

func checkCrc(data: openArray[byte], expected: uint32): bool =
  let actual = masked_crc32c(data[0].unsafeAddr, data.len.uint)
  result = actual == expected

proc checkCrcAndAppend(output: OutputStream, data: openArray[byte], crc: uint32): bool =
  if not checkCrc(data, crc):
    return

  output.append(data)
  result = true

func seekForward(_: openArray[byte]) =
  # TODO: rewindTo ?
  discard

const
  # maximum chunk data length
  # MAX_DATA_LEN                 = 16777215
  # maximum uncompressed data length excluding checksum
  MAX_UNCOMPRESSED_DATA_LEN    = 65536
  # maximum uncompressed data length excluding checksum
  MAX_COMPRESSED_DATA_LEN      = maxEncodedLen(MAX_UNCOMPRESSED_DATA_LEN)

  COMPRESSED_DATA_IDENTIFIER   = 0x00
  UNCOMPRESSED_DATA_IDENTIFIER = 0x01
  STREAM_IDENTIFIER            = 0xff

  STREAM_HEADER                = "\xff\x06\x00\x00sNaPpY"

proc framing_format_uncompress*(input: InputStream, output: OutputStream) =
  if not input.readable(STREAM_HEADER.len):
    # debugEcho "NOT A SNAPPY STREAM"
    return

  if input.read(STREAM_HEADER.len) != STREAM_HEADER.toOpenArrayByte(0, STREAM_HEADER.len-1):
    # debugEcho "BAD HEADER"
    return

  var uncompressedData = newSeq[byte](MAX_UNCOMPRESSED_DATA_LEN)

  while input.readable(4):
    let x = uint32.fromBytesLE input.read(4)
    let id = x and 0xFF
    let dataLen = (x shr 8).int

    if not input.readable(dataLen):
      # debugEcho "CHK 2 NOT ENOUGH BYTES"
      # debugEcho "request: ", dataLen
      # debugEcho "pos: ", input[].pos
      # debugEcho "endPos: ", input.endPos
      # debugEcho "distance: ", input.endPos - input[].pos
      return

    if id == COMPRESSED_DATA_IDENTIFIER:
      let crc = uint32.fromBytesLE input.read(4)

      let uncompressedLen = snappyUncompress(
        input.read(dataLen - 4),
        uncompressedData
      )

      if uncompressedLen <= 0:
        # debugEcho "BAD LEN"
        return

      if not output.checkCrcAndAppend(uncompressedData.toOpenArray(0, uncompressedLen-1), crc):
        # debugEcho "BAD CRC"
        return

    elif id == UNCOMPRESSED_DATA_IDENTIFIER:
      let crc = uint32.fromBytesLE(input.read(4))
      if not output.checkCrcAndAppend(input.read(dataLen - 4), crc):
        # debugEcho "BAD CRC UNCOMP"
        return
    elif id < 0x80:
      # Reserved unskippable chunks (chunk types 0x02-0x7f)
      # if we encounter this type of chunk, stop decoding
      # the spec says it is an error
      # debugEcho "BAD CHUNK"
      return
    else:
      # Reserved skippable chunks (chunk types 0x80-0xfe)
      # including STREAM_HEADER (0xff) should be skipped
      seekForward(input.read(dataLen))

  output.flush()

proc framingFormatUncompress*(input: openarray[byte]): seq[byte] =
  var output = memoryOutput()
  framing_format_uncompress memoryInput(input), output
  return output.getOutput

proc processFrame*(output: OutputStream, dst: var openArray[byte], src: openArray[byte]) =
  let
    crc = masked_crc32c(src[0].unsafeAddr, src.len.uint)
    varintLen = oas.putUvarint(dst, src.len.uint64)
    encodedLen = oas.encodeBlock(dst.toOpenArray(varintLen, dst.len-1), src) + varintLen

  if encodedLen >= (src.len - (src.len div 8)):
    let frameLen = src.len + 4 # include 4 bytes crc
    let header = (uint32(frameLen) shl 8) or UNCOMPRESSED_DATA_IDENTIFIER.uint32
    output.append toBytesLE(header)
    output.append toBytesLE(crc)
    output.append src
  else:
    let frameLen = encodedLen + 4 # include 4 bytes crc
    let header = (uint32(frameLen) shl 8) or COMPRESSED_DATA_IDENTIFIER.uint32
    output.append toBytesLE(header)
    output.append toBytesLE(crc)
    output.append dst.toOpenArray(0, encodedLen-1)

proc framing_format_compress*(output: OutputStream, src: openArray[byte]) =
  const maxFrameSize = MAX_UNCOMPRESSED_DATA_LEN
  var compressedData = newSeq[byte](MAX_COMPRESSED_DATA_LEN)

  # write the magic identifier
  output.append(STREAM_HEADER)

  var
    p = 0
    len = src.len

  while len > 0:
    let frameSize = min(len, maxFrameSize)
    processFrame(output, compressedData, src[p..<p+frameSize])
    inc(p, frameSize)
    dec(len, frameSize)

  output.flush()
