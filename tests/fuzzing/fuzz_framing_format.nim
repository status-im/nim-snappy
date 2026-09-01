{.push raises: [].}

import
  ../../snappy, testutils/fuzzing

const MaxLen = 128 * 1024 * 1024

test:
  discard decodeFramed(payload, MaxLen)
  doAssert decodeFramed(encodeFramed(payload)) == @payload
