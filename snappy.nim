import
  stew/[leb128, ranges/ptr_arith],
  faststreams/[inputs, outputs, buffers, multisync],
  ./snappy/[codec, decoder, encoder_fs, types]

export
  types

proc appendSnappyBytes*(s: OutputStream, src: openArray[byte]) =
  var
    lenU32 = checkInputLen(src.len).valueOr:
      raiseInputTooLarge()
    p = 0

  # The block starts with the varint-encoded length of the decompressed bytes.
  s.write lenU32.toBytes(Leb128).toOpenArray()
  if lenU32 <= 0: return

  while lenU32 > maxBlockSize:
    s.encodeBlock src.toOpenArray(p, p + maxBlockSize.int - 1)
    p += maxBlockSize.int
    lenU32 -= maxBlockSize

  # The `lenU32.int` expressions below cannot overflow because
  # `lenU32` is already less than `maxBlockSize` here:
  if lenU32 < minNonLiteralBlockSize.uint32:
    s.emitLiteral src.toOpenArray(p, p + lenU32.int - 1)
  else:
    s.encodeBlock src.toOpenArray(p, p + lenU32.int - 1)

proc snappyCompress*(input: InputStream, output: OutputStream) =
  try:
    let inputLen = input.len
    if inputLen.isSome:
      let
        lenU32 = checkInputLen(inputLen.get).valueOr:
          raiseInputTooLarge()
        maxCompressed = maxCompressedLen(lenU32).valueOr:
          raiseInputTooLarge()

      output.ensureRunway maxCompressed
      output.write lenU32.toBytes(Leb128).toOpenArray()
    else:
      # TODO: This is a temporary limitation
      doAssert false, "snappy requires an input stream with a known length"

    while input.readable(maxBlockSize.int):
      encodeBlock(output, input.read(maxBlockSize.int))

    let remainingBytes = input.totalUnconsumedBytes
    if remainingBytes > 0:
      if remainingBytes < minNonLiteralBlockSize:
        output.emitLiteral input.read(remainingBytes)
      else:
        output.encodeBlock input.read(remainingBytes)
  finally:
    close output

# Encode returns the encoded form of src.
func encode*(src: openarray[byte]): seq[byte] =
  # Memory streams doesn't have side effects:
  {.noSideEffect.}:
    let output = memoryOutput()
    snappyCompress(unsafeMemoryInput(src), output)
    output.getOutput

func decode*(src: openArray[byte], maxSize = 0xffffffff'u32): seq[byte] =
  let (lenU32, bytesRead) = uint32.fromBytes(src, Leb128)
  if bytesRead <= 0 or lenU32 > maxSize:
    return

  if lenU32 > 0:
    when sizeof(uint) == 4:
      if lenU32 > 0x7fffffff'u32:
        return
    # `lenU32.int` cannot overflow because of the extra check above
    result = newSeq[byte](lenU32.int)
    let errCode = decode(result, src.toOpenArray(bytesRead, src.len - 1))
    if errCode != 0: result = @[]

proc snappyUncompress*(src: openArray[byte], dst: var openArray[byte]): uint32 =
  let (lenU32, bytesRead) = uint32.fromBytes(src, Leb128)
  if bytesRead <= 0 or lenU32.BiggestUInt > dst.len.BiggestUInt:
    return 0

  if lenU32 > 0:
    # `result.int` cannot overflow here, because we've already
    # checked that it's smaller than the `dst.len` which is an int.
    let errCode = decode(dst.toOpenArray(0, lenU32.int - 1),
                         src.toOpenArray(bytesRead, src.len - 1))
    if errCode != 0:
      return 0

  return lenU32
