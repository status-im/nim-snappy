import
  testutils/fuzzing,
  ../../snappy

test:
  block:
    try:
      let decoded = snappy.decode(payload)
      let encoded = snappy.encode(decoded)
      doAssert encoded == payload
    except SnappyError:
      discard

