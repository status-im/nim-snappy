import
  stew/[endians2, ptrops],
  ./codec

template load16(src: ptr byte): uint16 =
  uint16.fromBytesLE(cast[ptr UncheckedArray[byte]](src).toOpenArray(0, 1))

template load32(src: ptr byte): uint32 =
  uint32.fromBytesLE(cast[ptr UncheckedArray[byte]](src).toOpenArray(0, 3))

func decodeAllTags*(
    input: openArray[byte],
    output: var openArray[byte]): Result[int, CodecError] =
  ## Decode all bytes of `input` into `output` and return the number of
  ## of bytes written. Returns error if input does not fit in output.

  # `uint` / pointer arithmetic because:
  # TODO https://github.com/nim-lang/Nim/issues/19653
  if input.len == 0:
    return ok(0)

  if output.len == 0:
    return err(CodecError.bufferTooSMall)

  var
    op = addr output[0]
    baseOp = op
    opEnd = op.offset(output.len)
    ip = unsafeAddr input[0]
    ipEnd = ip.offset(input.len)
    offset = 0'u32
    length = 0'u32

  while ip < ipEnd:
    let tag = ip[]
    case (tag and 0x03)
    of tagLiteral:
      ip = ip.offset(1)

      length = uint32(tag shr 2) + 1 # 1 <= length <= 64

      if length <= 16 and op.distance(opEnd) >= 16 and ip.distance(ipEnd) >= 16:
        copyMem(op, ip, 16)
        op = op.offset(int length)
        ip = ip.offset(int length)
        continue

      if length >= 61:
        if ip.offset(61) > ipEnd:
          # There must be at least 61 bytes, else we wouldn't be in this branch
          return err(CodecError.invalidInput)

        # Length is actually in the little-endian bytes that follow
        let
          lenlen = length - 60 # 1-4 bytes
          len = load32(ip)

        const mask = [0'u32, 0xff'u32, 0xffff'u32, 0xffffff'u32, 0xffffffff'u32]

        # Decode 4 bytes (to avoid branching) then mask the excess
        length = (len and mask[lenlen]) + 1

        ip = ip.offset(int lenlen)

      if (op.distance(opEnd).uint32 < length) or
          (ip.distance(ipEnd).uint32 < length):
        return err(CodecError.invalidInput)

      copyMem(op, ip, length)

      op = op.offset(int length)
      ip = ip.offset(int length)
      continue

    of tagCopy1:
      ip = ip.offset(2)
      if ip > ipEnd:
        return err(CodecError.invalidInput)

      length = 4 + uint32((tag shr 2) and 0x07)
      offset = (uint32(tag and 0xe0) shl 3) or uint32(ip.offset(-1)[])

    of tagCopy2:
      ip = ip.offset(3)
      if ip > ipEnd:
        return err(CodecError.invalidInput)

      length = 1 + uint32(tag shr 2)
      offset = uint32(load16(ip.offset(-2)))

    else: # tagCopy4:
      ip = ip.offset(5)
      if ip > ipEnd:
        return err(CodecError.invalidInput)

      length = 1 + uint32(tag shr 2)
      offset = load32(ip.offset(-4))

    if offset <= 0 or
        baseOp.distance(op).uint32 < offset.uint32 or
        op.distance(opEnd).uint32 < length:
      return err(CodecError.invalidInput)

    var
      opOffset = op.offset(-int(offset))

    if offset >= 8:
      # When there is sufficient non-overlap, we can bulk-copyMem
      while length >= 8:
        copyMem(op, opOffset, 8)
        length -= 8
        op = op.offset(8)
        opOffset = opOffset.offset(8)

    # Copy from an earlier sub-slice of dst to a later sub-slice. Unlike
    # the built-in copy function, this byte-by-byte copy always runs
    # forwards, even if the slices overlap. Conceptually, this is:
    #
    # d += forwardCopy(dst[d:d+length], dst[d-offset:])
    while length >= 1:
      op[] = opOffset[]
      length -= 1
      op = op.offset(1)
      opOffset = opOffset.offset(1)

  ok(baseOp.distance(op))
