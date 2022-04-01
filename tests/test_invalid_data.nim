{.used.}

import
  unittest2,
  ../snappy

proc parseInvalidInput(payload: openArray[byte]) =
  var tmp = newSeqUninitialized[byte](256)
  check:
    uncompress(payload, tmp).isErr()

  let decoded {.used.} = decodeFramed(payload)
  check: decoded.len == 0

suite "invalid data":
  test "invalid header":
    parseInvalidInput([byte 3, 2, 1, 0])
