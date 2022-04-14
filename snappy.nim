import
  stew/[arrayops, endians2, leb128, results],
  ./snappy/[codec, decoder, encoder]

export codec, results

{.push raises: [Defect].}

## Compression and decompression utilities for the snappy compression algorithm:
##
## * [Landing page](http://google.github.io/snappy/)
## * [Format description](https://github.com/google/snappy/blob/main/format_description.txt)
##
## This file contains the in-memory API - see
## `snappy/faststreams` and `snappy/streams` for `faststreams` and `std/streams`
## support.
##
## * `compress`/`uncompress` work with caller-allocated buffers
## * `encode`/`decode` are convenience wrappers for the above that take care of
##   memory allocation
##
## Framed encodings are also supported via functions carrying the `Framed` suffix
##
## * [Framing format](https://github.com/google/snappy/blob/main/framing_format.txt)

func compress*(
    input: openArray[byte],
    output: var openArray[byte]): Result[int, CodecError] =
  ## Compresses `input` and returns the number of bytes written to `output`.
  ##
  ## `input` may be no larger than 2^32-1 bytes, or `CodecError.invalidInput` is
  ## returned.
  ##
  ## `output` must be at least `maxCompressedLen(input.len)` bytes, or
  ## `CodecError.bufferTooSmall` is returned.
  ##
  ## See `compressFramed` for the framed format that supports arbitrary inputs.
  ## See `snappy/faststreams` and `snappy/streams` for stream-based versions.
  let
    lenU32 = checkInputLen(input.len).valueOr:
      return err(CodecError.invalidInput)

  if output.len.uint64 < maxCompressedLen(lenU32):
    return err(CodecError.bufferTooSmall)

  let
    # The block starts with the varint-encoded length of the unencoded bytes.
    header = lenU32.toBytes(Leb128)
  output[0..<header.len] = header.toOpenArray()

  var
    read = 0
    written = int(header.len)

  while (let remaining = input.len - read; remaining > 0):
    let
      blockSize = min(remaining, maxBlockLen.int)
    written += encodeBlock(
      input.toOpenArray(read, read + blockSize - 1),
      output.toOpenArray(written, output.high))
    read += blockSize

  ok(written)

func encode*(input: openArray[byte]): seq[byte] =
  ## Compresses `input` and returns the compressed output.
  ##
  ## `input` may be no larger than 2^32-1 bytes, or an empty buffer is returned.
  ## `input` must also be small enough that we can construct the output buffer
  ## with at least `maxCompressedLen(input.len)` bytes, or an empty buffer is
  ## returned.
  ##
  ## See `encodeFramed` for the framed format that supports arbitrary lengths.
  ## See `snappy/faststreams` and `snappy/streams` for stream-based versions.
  let
    maxCompressed = maxCompressedLen(input.len).valueOr:
      return
  # TODO https://github.com/nim-lang/Nim/issues/19357
  result = newSeqUninitialized[byte](maxCompressed)
  let written = compress(input, result).expect("we've checked lengths already")
  result.setLen(written)

func uncompress*(input: openArray[byte], output: var openArray[byte]):
    Result[int, CodecError] =
  ## Write the uncompressed bytes of `input` to `output` and return the number
  ## of bytes written.
  ##
  ## `output` must be at least `uncompressedLen` bytes.
  ##
  ## In case of errors, `output` may have been partially written to.
  let (lenU32, bytesRead) = uint32.fromBytes(input, Leb128)
  if bytesRead <= 0:
    return err(CodecError.invalidInput)

  if output.len.uint64 < lenU32.uint64:
    return err(CodecError.bufferTooSmall)

  if lenU32 == 0:
    if bytesRead != input.len():
      return err(CodecError.invalidInput)
    return ok(0)

  let written =
    ? decodeAllTags(input.toOpenArray(bytesRead, input.high), output)

  if written.uint64 != lenU32:
    return err(CodecError.invalidInput) # Header does not match content

  return ok(written)

func decode*(input: openArray[byte], maxSize = maxUncompressedLen): seq[byte] =
  ## Decode input returning the uncompressed output. On error, return an empty
  ## sequence, including when output would exceed `maxSize`.
  ##
  ## `maxSize` must be used for untrusted inputs to limit the amount of memory
  ## allocated by this function, which otherwise is read from the stream.
  let uncompressed = uncompressedLen(input).valueOr:
    return

  if uncompressed > maxSize.uint64 or uncompressed > int.high.uint64:
    return

  # TODO https://github.com/nim-lang/Nim/issues/19357
  result = newSeqUninitialized[byte](int uncompressed)

  if uncompress(input, result).isErr():
    result = @[] # Empty return on error

func compressFramed*(input: openArray[byte], output: var openArray[byte]):
    Result[int, FrameError] =
  ## Compresses `input` and returns the number of bytes written to `output`.
  ##
  ## `output` must be at least `maxCompressedLenFramed(input.len)` bytes, or
  ## `SnappyError.bufferTooSmall` is returned.
  ##
  ## See `compress` for the simple non-framed snappy format.
  ## See `snappy/faststreams` and `snappy/streams` for stream-based versions.
  if output.len.uint64 < maxCompressedLenFramed(input.len):
    return err(FrameError.bufferTooSmall)

  output[0..<framingHeader.len] = framingHeader
  var
    read = 0
    written = framingHeader.len
  while (let remaining = input.len - read; remaining > 0):
    let
      frameSize = min(remaining, int maxUncompressedFrameDataLen)
    written += encodeFrame(
      input.toOpenArray(read, read + frameSize - 1),
      output.toOpenArray(written, output.high))

    read += frameSize

  ok(written)

func encodeFramed*(input: openArray[byte]): seq[byte] =
  let maxCompressed = maxCompressedLenFramed(input.len)
  if maxCompressed > int.high.uint64:
    return

  # TODO https://github.com/nim-lang/Nim/issues/19357
  result = newSeqUninitialized[byte](int maxCompressed)
  let
    written = compressFramed(input, result).expect("lengths checked")

  result.setLen(written)

func uncompressFramed*(
    input: openArray[byte], output: var openArray[byte], checkHeader = true):
    Result[tuple[read: int, written: int], FrameError] =
  ## Uncompress as many frames as possible from `input` and write them to
  ## `output`, returning the number of bytes read and written.
  ##
  ## When the `output` buffer is too small to hold the uncompressed data,
  ## the function will return the number of bytes consumed from the input and
  ## the number of correctly written bytes in the output (which may be smaller
  ## than the length of the output buffer).
  ##
  ## Decompression can be resumed by calling `uncompressFramed` again with
  ## `checkHeader = false` and the input positioned at the returned read offset
  ## and a new output buffer.
  ##
  ## In case of errors, `output` may be partially overwritten with invalid data.
  var
    read =
      if checkHeader:
        if input.len < framingHeader.len:
          return err(FrameError.invalidInput)

        if input.toOpenArray(0, framingHeader.len - 1) != framingHeader:
          return err(FrameError.invalidInput)
        framingHeader.len
      else:
        0
    written = 0

  while (let remaining = input.len - read; remaining > 0):
    if remaining < 4:
      return err(FrameError.invalidInput)
    let
      (id, dataLen) = decodeFrameHeader(input.toOpenArray(read, read + 3))
    read += 4

    if remaining - 4 < dataLen:
      return err(FrameError.invalidInput)

    if id == chunkCompressed:
      if dataLen < 4:
        return err(FrameError.invalidInput)

      let
        crc = uint32.fromBytesLE input.toOpenArray(read, read + 3)
        maxOutput = min(maxUncompressedFrameDataLen.int, output.len - written)
        uncompressed = uncompress(
          input.toOpenArray(read + 4, read + dataLen - 1),
          output.toOpenArray(written, written + maxOutput - 1)).valueOr:
            let res = case error
            of CodecError.bufferTooSmall:
              let uncompressed =
                uncompressedLen(input.toOpenArray(read + 4, read + dataLen - 1))
              if uncompressed.isErr() or
                  uncompressed.get() > maxUncompressedFrameDataLen:
                err(FrameError.invalidInput)
              else:
                ok((read - 4, written))
            of CodecError.invalidInput: err(FrameError.invalidInput)
            return res

      if maskedCrc(
          output.toOpenArray(written, written + (uncompressed - 1))) != crc:
        return err(FrameError.crcMismatch)

      written += uncompressed

    elif id == chunkUncompressed:
      if dataLen < 4:
        return err(FrameError.invalidInput)

      let
        crc = uint32.fromBytesLE input.toOpenArray(read, read + 3)

      if maskedCrc(input.toOpenArray(read + 4, read + (dataLen - 1))) != crc:
        return err(FrameError.crcMismatch)

      let uncompressed = dataLen - 4 # dataLen includes CRC length

      if uncompressed > maxUncompressedFrameDataLen.int:
        return err(FrameError.invalidInput)

      if uncompressed > output.len - written:
        return ok((read - 4, written))

      copyMem(addr output[written], unsafeAddr input[read + 4], uncompressed)
      written += uncompressed

    elif id < 0x80:
      return err(FrameError.unknownChunk) # Reserved unskippable chunk

    else:
      discard # Reserved skippable chunk (for example framing format header)

    read += dataLen

  ok((read, written))

func decodeFramed*(input: openArray[byte], maxSize = int.high): seq[byte] =
  ## Uncompress as many frames as possible from `input` and return the
  ## uncompressed output.
  ##
  ## `maxSize` puts a cap on actual memory consumption, not the final length
  ## of the data - reading will continue until we run out of space based on
  ## the margins in maxCompresssedLen!
  ##
  ## In case of errors, an empty buffer is returned.
  let uncompressed = uncompressedLenFramed(input).valueOr:
    return

  if uncompressed > maxSize.uint64 or uncompressed > int.high.uint64:
    return

  # TODO https://github.com/nim-lang/Nim/issues/19357
  result = newSeqUninitialized[byte](int uncompressed)

  if uncompressFramed(input, result).isErr():
    result = @[] # Empty return on error

template compress*(input: openArray[byte]): seq[byte] {.
    deprecated: "use `encode` - compress is for user-supplied buffers".} =
  encode(input)
template uncompress*(input: openArray[byte]): seq[byte] {.
    deprecated: "use `decode` - uncompress is for user-supplied buffers".} =
  decode(input)
