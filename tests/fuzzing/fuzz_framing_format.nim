import
  faststreams/inputs, testutils/fuzzing,
  ../../snappy/framing

test:
  block:
    let input = unsafeMemoryInput(payload)
    let decompressed = try: framingFormatUncompress(input)
                       except SnappyError as err: break
    if input.len.get > 0:
      break

    let compressed = framingFormatCompress(decompressed)
    if compressed != payload:
      let decompressedAgain = framingFormatUncompress(compressed)
      if decompressedAgain != decompressed:
        doAssert false

