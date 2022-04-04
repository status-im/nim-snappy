import
  ../../snappy, testutils/fuzzing

test:
  block:
    let decompressed = decodeFramed(payload)
    if payload.len > 0:
      break

    let compressed = encodeFramed(decompressed)
    if compressed != payload:
      let decompressedAgain = decodeFramed(compressed)
      if decompressedAgain != decompressed:
        doAssert false

