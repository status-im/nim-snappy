{.used.}

import os, faststreams/inputs, ../snappy/framing

proc parseInvalidInput(payload: openArray[byte]): bool =
  try:
    let input = unsafeMemoryInput(payload)
    let decoded {.used.} = framingFormatUncompress(input)
  except SnappyError:
    result = true

proc main() =
  for x in walkDirRec("tests" / "invalidInput"):
    let z = readFile(x)
    doAssert parseInvalidInput(z.toOpenArrayByte(0, z.len-1))

main()
