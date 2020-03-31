import
  ../snappy, ../snappy/utils,
  ../tests/openarrays_snappy as oas,
  faststreams/[output_stream, input_stream],
  stew/endians2

{.compile: "crc32c.c".}
# TODO: we don't have a native implementation of CRC32C algorithm yet.
#       we can't use nimPNG CRC32
proc masked_crc32c(buf: ptr byte, len: uint): cuint {.cdecl, importc.}

func checkCrc32(data: openArray[byte], expected: uint32): bool =
  let actual = masked_crc32c(data[0].unsafeAddr, data.len.uint)
  result = actual == expected

proc checkData(data: openArray[byte], crc: uint32, output: OutputStreamVar): bool =
  if not checkCrc32(data, crc):
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

proc framing_format_uncompress*(input: ByteStreamVar, output: OutputStreamVar) =
  if not input[].ensureBytes(STREAM_HEADER.len):
    # debugEcho "NOT A SNAPPY STREAM"
    return

  if input.readBytes(STREAM_HEADER.len) != STREAM_HEADER.toOpenArrayByte(0, STREAM_HEADER.len-1):
    # debugEcho "BAD HEADER"
    return

  var uncompressedData = newSeq[byte](MAX_UNCOMPRESSED_DATA_LEN)

  while true:
    if input[].eof():
      break

    # ensure bytes
    if not input[].ensureBytes(4):
      # debugEcho "CHK 1 NOT ENOUGH BYTES"
      return

    let x = uint32.fromBytesLE(input.readBytes(4))
    let id = x and 0xFF
    let dataLen = (x shr 8).int

    if not input[].ensureBytes(dataLen):
      # debugEcho "CHK 2 NOT ENOUGH BYTES"
      # debugEcho "request: ", dataLen
      # debugEcho "pos: ", input[].pos
      # debugEcho "endPos: ", input.endPos
      # debugEcho "distance: ", input.endPos - input[].pos
      return

    if id == COMPRESSED_DATA_IDENTIFIER:
      let crc = uint32.fromBytesLE(input.readBytes(4))

      let uncompressedLen = snappyUncompress(
        input.readBytes(dataLen - 4),
        uncompressedData
      )

      if uncompressedLen <= 0:
        # debugEcho "BAD LEN"
        return

      if not checkData(uncompressedData.toOpenArray(0, uncompressedLen-1), crc, output):
        # debugEcho "BAD CRC"
        return

    elif id == UNCOMPRESSED_DATA_IDENTIFIER:
      let crc = uint32.fromBytesLE(input.readBytes(4))
      if not checkData(input.readBytes(dataLen - 4), crc, output):
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
      seekForward(input.readBytes(dataLen))

  output.flush()

proc processFrame*(output: OutputStreamVar, dst: var openArray[byte], src: openArray[byte]) =
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

proc framing_format_compress*(output: OutputStreamVar, src: openArray[byte]) =
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
