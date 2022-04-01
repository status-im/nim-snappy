import
  pkg/faststreams/[inputs, multisync, outputs],
  "."/[codec, encoder, exceptions],
  ../snappy

export
  inputs, multisync, outputs, codec, exceptions

{.push raises: [Defect].}

proc checkCrcAndAppend(
    output: OutputStream, data: openArray[byte], crc: uint32): bool {.
    raises: [Defect, IOError].}=
  if maskedCrc(data) == crc:
    output.write(data)
    return true

proc compress*(input: InputStream, output: OutputStream) {.
    raises: [Defect, InputTooLarge, IOError].} =
  ## Compress all bytes of `input`, writing into `output` and flushing at the end.
  ##
  ## Input length must not exceed `maxUncompressedLen == 2^32-1` or
  ## `InputTooLarge` will be raised. Other errors are raised as they happen on
  ## the given streams.
  let inputLen = input.len
  if inputLen.isSome:
    let
      lenU32 = checkInputLen(inputLen.get).valueOr:
        raiseInputTooLarge()
      maxCompressed = maxCompressedLen(inputLen.get).valueOr:
        raiseInputTooLarge()

    output.ensureRunway maxCompressed
    output.write lenU32.toBytes(Leb128).toOpenArray()
  else:
    # TODO: This is a temporary limitation
    doAssert false, "snappy requires an input stream with a known length"

  var
    # TODO instead of a temporary buffer, use `getWriteableBytes` once it
    #      works
    tmp = newSeqUninitialized[byte](int(maxCompressedLen(maxBlockLen)))

  while input.readable(maxBlockLen.int):
    let written = encodeBlock(input.read(maxBlockLen.int), tmp)
    # TODO async streams could be supported efficiently by waiting here, after
    #      each 64kb-block
    output.write(tmp.toOpenArray(0, written - 1))

  let remainingBytes = input.totalUnconsumedBytes
  if remainingBytes > 0:
    let written = encodeBlock(input.read(remainingBytes), tmp)
    output.write(tmp.toOpenArray(0, written - 1))

proc compress*(input: openArray[byte], output: OutputStream) {.
    raises: [Defect, InputTooLarge, IOError].} =
  compress(unsafeMemoryInput(input), output)

# `uncompress` is not implemented due to the requirement that the full output
# must remain accessible throughout uncompression
# TODO reading from a stream is still feasible

proc compressFramed*(input: InputStream, output: OutputStream) {.
    raises: [Defect, IOError].} =
  # write the magic identifier
  output.write(framingHeader)

  var
    read = 0
    tmp = newSeqUninitialized[byte](
      maxCompressedLen(maxUncompressedFrameDataLen))

  while input.readable(maxUncompressedFrameDataLen.int):
    let written = encodeFrame(input.read(maxUncompressedFrameDataLen.int), tmp)
    # TODO async streams could be supported efficiently by waiting here, after
    #      each 64kb-block
    output.write(tmp.toOpenArray(0, written - 1))

  let remainingBytes = input.totalUnconsumedBytes
  if remainingBytes > 0:
    let written = encodeFrame(input.read(remainingBytes), tmp)
    output.write(tmp.toOpenArray(0, written - 1))

  output.flush()

proc compressFramed*(input: openArray[byte], output: OutputStream) {.
    raises: [Defect, IOError].} =
  compressFramed(unsafeMemoryInput(input), output)

proc uncompressFramed*(input: InputStream, output: OutputStream) {.
    fsMultiSync, raises: [Defect, IOError, SnappyDecodingError].} =
  if not input.readable(framingHeader.len):
    raise newException(UnexpectedEofError, "Failed to read stream header")

  if input.read(framingHeader.len) != framingHeader:
    raise newException(MalformedSnappyData, "Invalid header value")

  var uncompressedData =
    newSeqUninitialized[byte](maxUncompressedFrameDataLen)

  while input.readable(4):
    let (id, dataLen) = decodeFrameHeader(input.read(4))

    if dataLen.uint64 > maxCompressedFrameDataLen:
      raise newException(MalformedSnappyData, "Invalid frame length: " & $dataLen)

    if not input.readable(dataLen):
      raise newException(UnexpectedEofError, "Failed to read the entire snappy frame")

    if id == chunkCompressed:
      if dataLen < 4:
        raise newException(MalformedSnappyData, "Frame size too low to contain CRC checksum")

      let
        crc = uint32.fromBytesLE input.read(4)
        uncompressedLen = snappy.uncompress(input.read(dataLen - 4), uncompressedData).valueOr:
          raise newException(MalformedSnappyData, "Failed to decompress content")

      if not checkCrcAndAppend(Sync output, uncompressedData.toOpenArray(0, uncompressedLen-1), crc):
        raise newException(MalformedSnappyData, "Content CRC checksum failed")

    elif id == chunkUncompressed:
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

  if input.readable(1):
    raise newException(MalformedSnappyData, "Input contains unknown trailing bytes")

proc uncompressFramed*(input: openArray[byte], output: OutputStream) {.
    raises: [Defect, IOError, SnappyDecodingError].} =
  uncompressFramed(unsafeMemoryInput(input), output)