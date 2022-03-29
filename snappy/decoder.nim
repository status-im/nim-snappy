import
  stew/[arrayops],
  ./codec

const
  decodeErrCodeCorrupt = 1
  decodeErrCodeUnsupportedLiteralLength = 2

func decode*(dst: var openArray[byte], src: openArray[byte]): int =
  var
    d = 0
    s = 0
    offset = 0
    length = 0

  while s < src.len:
    let tag = src[s] and 0x03
    case tag
    of tagLiteral:
      var x = int(src[s]) shr 2
      if x < 60:
        inc s
      elif x == 60:
        inc(s, 2)
        if s > src.len:
          return decodeErrCodeCorrupt
        x = int(src[s-1])
      elif x == 61:
        inc(s, 3)
        if s > src.len:
          return decodeErrCodeCorrupt
        x = int(src[s-2]) or (int(src[s-1]) shl 8)
      elif x == 62:
        inc(s, 4)
        if s > src.len:
          return decodeErrCodeCorrupt
        x = int(src[s-3]) or (int(src[s-2]) shl 8) or (int(src[s-1]) shl 16)
      elif x == 63:
        inc(s, 5)
        if s > src.len:
          return decodeErrCodeCorrupt
        x = int(src[s-4]) or (int(src[s-3]) shl 8) or (int(src[s-2]) shl 16) or (int(src[s-1]) shl 24)
      length = x + 1
      if length <= 0:
        return decodeErrCodeUnsupportedLiteralLength

      if (length > (dst.len-d)) or (length > (src.len-s)):
        return decodeErrCodeCorrupt

      dst[d..<d+length] = src.toOpenArray(s, s+length-1)
      inc(d, length)
      inc(s, length)
      continue

    of tagCopy1:
      inc(s, 2)
      if s > src.len:
        return decodeErrCodeCorrupt
      length = 4 + ((int(src[s-2]) shr 2) and 0x07)
      offset = ((int(src[s-2]) and 0xe0) shl 3) or int(src[s-1])

    of tagCopy2:
      s += 3
      if s > src.len:
        return decodeErrCodeCorrupt
      length = 1 + (int(src[s-3]) shr 2)
      offset = int(src[s-2]) or (int(src[s-1]) shl 8)

    of tagCopy4:
      s += 5
      if s > src.len:
        return decodeErrCodeCorrupt
      length = 1 + (int(src[s-5]) shr 2)
      offset = int(src[s-4]) or (int(src[s-3]) shl 8) or (int(src[s-2]) shl 16) or (int(src[s-1]) shl 24)

    else: discard

    if offset <= 0 or d < offset or (length > (dst.len-d)):
      return decodeErrCodeCorrupt

    # Copy from an earlier sub-slice of dst to a later sub-slice. Unlike
    # the built-in copy function, this byte-by-byte copy always runs
    # forwards, even if the slices overlap. Conceptually, this is:
    #
    # d += forwardCopy(dst[d:d+length], dst[d-offset:])
    let stop = d + length
    while d != stop:
      dst[d] = dst[d-offset]
      inc d

  if d != dst.len:
    return decodeErrCodeCorrupt
  return 0
