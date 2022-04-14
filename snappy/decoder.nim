import
  stew/[endians2],
  ./codec

# These load templates assume there is enough data to read at the margin, which
# the code ensures via manual range checking - the built-in range check adds 40%
# execution time
template load16(input: openArray[byte], offsetParam: int): uint16 =
  let offset = offsetParam
  uint16.fromBytesLE(
    cast[ptr UncheckedArray[byte]](input).toOpenArray(offset, offset + 1))

template load32(input: openArray[byte], offsetParam: int): uint32 =
  let offset = offsetParam
  uint32.fromBytesLE(
    cast[ptr UncheckedArray[byte]](input).toOpenArray(offset, offset + 3))

func decodeAllTags*(
    input: openArray[byte],
    output: var openArray[byte]): Result[int, CodecError] =
  ## Decode all bytes of `input` into `output` and return the number of
  ## of bytes written. Returns error if input does not fit in output.

  if input.len <= 0: # let the optimizer know len > 0
    return ok(0)

  if output.len <= 0: # let the optimizer know len > 0
    return err(CodecError.bufferTooSmall)

  var
    op = 0
    ip = 0
    length: int
    offset: uint32

  # TODO https://github.com/nim-lang/Nim/issues/19653
  while uint(ip) < uint(input.len):
    let tag = input[ip]

    case (tag and 0x03)
    of tagLiteral:
      ip += 1

      length = int((tag shr 2) + 1) # 1 <= len32 <= 64

      if length <= 16 and (output.len - op) >= 16 and (input.len - ip) >= 16:
        copyMem(addr output[op], unsafeAddr input[ip], 16)
        op += length
        ip += length
        continue

      if length >= 61:
        if (input.len - ip) < 61:
          # There must be at least 61 bytes, else we wouldn't be in this branch
          return err(CodecError.invalidInput)

        const mask = [0'u32, 0xff'u32, 0xffff'u32, 0xffffff'u32, 0xffffffff'u32]

        # Length is actually in the little-endian bytes that follow
        # Decode 4 bytes then mask the excess (to avoid branching)
        let
          lenlen = length - 60 # 1-4
          len32 = (load32(input, ip) and mask[lenlen]) + 1

        if len32 == 0: # wrap-around for 4-byte length
          return err(CodecError.invalidInput)

        when sizeof(int) == sizeof(len32):
          if len32 > int.high.uint32: # Can't have this many bytes..
            return err(CodecError.invalidInput)

        length = int len32
        ip += lenlen

      if ((output.len - op) < length) or
          ((input.len - ip) < length):
        return err(CodecError.invalidInput)

      copyMem(addr output[op], unsafeAddr input[ip], length)

      op += length
      ip += length
      continue

    of tagCopy1:
      if (input.len - ip) < 2:
        return err(CodecError.invalidInput)

      length = int(4 + ((tag shr 2) and 0x07))
      offset = (uint32(tag and 0xe0) shl 3) or uint32(input[ip + 1])

      ip += 2
    of tagCopy2:
      if (input.len - ip) < 3:
        return err(CodecError.invalidInput)

      length = int(1 + (tag shr 2))
      offset = uint32(load16(input, ip + 1))

      ip += 3
    else: # tagCopy4:
      if (input.len - ip) < 5:
        return err(CodecError.invalidInput)

      length = int(1 + (tag shr 2))
      offset = load32(input, ip + 1)
      ip += 5

    # offset = 0 is invalid, and we catch it by doing a wrapping -1
    if op.uint32 <= (offset - 1'u32):
      return err(CodecError.invalidInput)

    var src = op - int offset # safe, because offset < op and op < int.high

    # Fast path: short non-overlapping copies
    if length <= 16 and offset >= 8 and (output.len - op) >= 16:
      # When offset is large enough, there is no overlap and we can use
      # bulk copy instructions - this is safe because we just checked that
      # there's enough space in the output buffer
      copyMem(addr output[op], addr output[src], 8)
      copyMem(addr output[op + 8], addr output[src + 8], 8)
      op += length
      continue

    if (output.len - op) < length:
      return err(CodecError.invalidInput)

    if (output.len - op) >= length + 10:
      var
        pos = op
        len = length

      while pos - src < 8:
        copyMem(addr output[pos], addr output[src], 8)
        len -= pos - src
        pos += pos - src

      while len > 0:
        copyMem(addr output[pos], addr output[src], 8)
        src += 8
        pos += 8
        len -= 8

    else:
      var pos = op
      while pos < op + length:
        output[pos] = output[src]
        pos += 1
        src += 1

    op += length

  ok(op)
