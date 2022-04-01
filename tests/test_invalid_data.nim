{.used.}

import
  unittest2,
  faststreams/inputs, ../snappy/framing

proc parseInvalidInput(payload: openArray[byte]): bool =
  try:
    let input = unsafeMemoryInput(payload)
    let decoded {.used.} = framingFormatUncompress(input)
  except SnappyError:
    result = true

suite "invalid data":
  test "invalid header":
    check parseInvalidInput([byte 3, 2, 1, 0])
