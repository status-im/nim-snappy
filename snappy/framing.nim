import
  faststreams/[output_stream, input_stream],
  stew/endians2

func maskedCrc32(data: openArray[byte]): uint32 =
  const MASK_DELTA = 0xa282ead8'u32
  const K = [0'u32, 0x1db71064, 0x3b6e20c8, 0x26d930ac, 0x76dc4190,
    0x6b6b51f4, 0x4db26158, 0x5005713c, 0xedb88320'u32, 0xf00f9344'u32, 0xd6d6a3e8'u32,
    0xcb61b38c'u32, 0x9b64c2b0'u32, 0x86d3d2d4'u32, 0xa00ae278'u32, 0xbdbdf21c'u32]

  var crc = not 0'u32
  for b in data:
    crc = (crc shr 4) xor K[int((crc and 0xF) xor (uint32(b) and 0xF'u32))]
    crc = (crc shr 4) xor K[int((crc and 0xF) xor (uint32(b) shr 4'u32))]

  crc = not crc
  result = ((crc shr 15) or (crc shl 17)) + MASK_DELTA

func checkCrc32(data, checksum: openArray[byte]): bool =
  # data: uncompressed
  # checksum: the first 4 bytes of chunk body
  let
    actual   = maskedCrc32(data)
    expected = uint32.fromBytesLE(checksum)
  result = actual == expected

const
  # maximum chunk data length
  MAX_DATA_LEN                 = 16777215
  # maximum uncompressed data length excluding checksum
  MAX_UNCOMPRESSED_DATA_LEN    = 65536

  COMPRESSED_DATA_IDENTIFIER   = byte(0x00)
  UNCOMPRESSED_DATA_IDENTIFIER = byte(0x01)
  STREAM_IDENTIFIER            = byte(0xff)
