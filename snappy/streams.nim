import
  std/streams,
  "."/[codec, encoder, exceptions]

export streams, exceptions

{.push raises: [Defect].}

proc compress*(input: Stream, inputLen: int, output: Stream) {.
    raises: [Defect, InputTooLarge, OSError, IOError].} =
  ## Compress the first `inputLen` of `input`, writing into `output`.
  ##
  ## If fewer than `inputLen` bytes are read, an exception is raised but
  ## `output` will have been written partially.
  ##
  ## Input length must not exceed `maxUncompressedLen == 2^32-1` or
  ## `InputTooLarge` will be raised. Other errors are raised as they happen on
  ## the given streams.
  let
    lenU32 = checkInputLen(inputLen).valueOr:
      raiseInputTooLarge()
    header = lenU32.toBytes(Leb128)

  output.writeData(unsafeAddr header.data[0], header.len)

  var
    tmpIn = newSeqUninitialized[byte](int maxBlockLen)
    tmpOut = newSeqUninitialized[byte](int maxCompressedBlockLen)
    read = 0

  while read < inputLen:
    let
      bytes = input.readData(addr tmpIn[0], tmpIn.len)
    if bytes == 0:
      break

    let
      written = encodeBlock(tmpIn.toOpenArray(0, bytes - 1), tmpOut)

    output.writeData(addr tmpOut[0], written)
    read += bytes

# TODO compressFramed
# TODO uncompressFramed
