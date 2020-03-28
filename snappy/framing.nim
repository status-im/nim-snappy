import
  ../snappy,
  faststreams/[output_stream, input_stream],
  stew/endians2

{.compile: "crc32c.c".}
# TODO: we don't have a native implementation of CRC32C algorithm yet.
#       we can't use nimPNG CRC32
proc masked_crc32c(buf: ptr byte, len: cuint): cuint {.cdecl, importc.}

func checkCrc32(data: openArray[byte], expected: uint32): bool =
  let actual = masked_crc32c(data[0].unsafeAddr, data.len.cuint)
  result = actual == expected

proc checkData(data: openArray[byte], crc: uint32, output: OutputStreamVar): bool =
  if not checkCrc32(data, crc):
    echo "BAD CRC"
    return

  output.append(data)
  result = true

func seekForward(_: openArray[byte]) =
  # TODO: rewindTo ?
  discard

const
  # maximum chunk data length
  MAX_DATA_LEN                 = 16777215
  # maximum uncompressed data length excluding checksum
  MAX_UNCOMPRESSED_DATA_LEN    = 65536

  COMPRESSED_DATA_IDENTIFIER   = 0x00
  UNCOMPRESSED_DATA_IDENTIFIER = 0x01
  STREAM_IDENTIFIER            = 0xff

  STREAM_HEADER                = "\xff\x06\x00\x00sNaPpY"

proc framing_format_uncompress*(input: ByteStreamVar, output: OutputStreamVar) =
  if input[].ensureBytes(STREAM_HEADER.len):
    if input.readBytes(STREAM_HEADER.len) != STREAM_HEADER.toOpenArrayByte(0, STREAM_HEADER.len-1):
      return

  var uncompressedData = newSeq[byte](MAX_UNCOMPRESSED_DATA_LEN)

  while true:
    if input[].eof():
      break

    # ensure bytes
    let x = uint32.fromBytesLE(input.readBytes(4))
    let id = x and 0xFF
    let dataLen = (x shr 8).int

    if id == COMPRESSED_DATA_IDENTIFIER:
      let crc = uint32.fromBytesLE(input.readBytes(4))

      let uncompressedLen = snappyUncompress(
        input.readBytes(dataLen - 4),
        uncompressedData
      )

      if uncompressedLen < 0:
        return

      if not checkData(uncompressedData.toOpenArray(0, uncompressedLen-1), crc, output):
        return

    elif id == UNCOMPRESSED_DATA_IDENTIFIER:
      let crc = uint32.fromBytesLE(input.readBytes(4))
      if not checkData(input.readBytes(dataLen - 4), crc, output):
        return
    elif id < 0x80:
      # Reserved unskippable chunks (chunk types 0x02-0x7f)
      # if we encounter this type of chunk, stop decoding
      # the spec says it is an error
      return
    else:
      # Reserved skippable chunks (chunk types 0x80-0xfe)
      seekForward(input.readBytes(dataLen))
