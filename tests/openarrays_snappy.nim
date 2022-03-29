import
  stew/[leb128],
  ../snappy/[codec, decoder, encoder_oa]

# Encode returns the encoded form of src. The returned slice may be a sub-
# slice of dst if dst was large enough to hold the entire encoded block.
# Otherwise, a newly allocated slice will be returned.
#
# The dst and src must not overlap. It is valid to pass a nil dst.
func encode*(src: openArray[byte]): seq[byte] =
  let
    lenU32 = checkInputLen(src.len).valueOr:
      return
    maxCompressed = maxCompressedLen(lenU32).valueOr:
      return

  # TODO https://github.com/nim-lang/Nim/issues/19357
  result.setLen(maxCompressed)

  # The block starts with the varint-encoded length of the decompressed bytes.
  let
    leb128 = lenU32.toBytes(Leb128)

  var
    p = 0
    d = int(leb128.len)
    len = src.len

  result[0..<d] = leb128.toOpenArray()

  while len > 0:
    let blockSize = min(len, maxBlockSize.int)

    if blockSize < minNonLiteralBlockSize:
      d += emitLiteral(result, d, src.toOpenArray(p, p+blockSize-1))
    else:
      d += encodeBlock(result, d, src.toOpenArray(p, p+blockSize-1))

    inc(p, blockSize)
    dec(len, blockSize)

  result.setLen(d)

# decodedLen returns the length of the decoded block and the number of bytes
# that the length header occupied.
func decode*(src: openArray[byte]): seq[byte] =
  let (lenU32, bytesRead) = fromBytes(uint32, src, Leb128)
  if bytesRead <= 0:
    return

  const wordSize = sizeof(uint) * 8
  if (wordSize == 32) and (lenU32 > 0x7fffffff'u64):
    return

  if lenU32 > 0:
    result.setLen(lenU32.int) # TODO protect against decompression bombs
    let errCode = decode(result, src.toOpenArray(bytesRead, src.len-1))
    if errCode != 0: result = @[]

template compress*(src: openArray[byte]): seq[byte] =
  snappy.encode(src)

template uncompress*(src: openArray[byte]): seq[byte] =
  snappy.decode(src)
