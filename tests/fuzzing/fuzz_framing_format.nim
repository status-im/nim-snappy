import
  faststreams/inputs, testutils/fuzzing,
  ../../snappy/framing

test:
  block:
    try:
      let input = unsafeMemoryInput(payload)
      let decoded = framingFormatUncompress(input)
      if input.len.get > 0:
        break

      let encoded = framingFormatCompress(decoded)
      doAssert encoded == payload
    except SnappyError:
      discard

