type
  SnappyError* = object of CatchableError

  SnappyDecodingError* = object of SnappyError
  SnappyEncodingError* = object of SnappyError

  UnexpectedEofError* = object of SnappyDecodingError
  MalformedSnappyData* = object of SnappyDecodingError

  InputTooLarge* = object of SnappyEncodingError

func raiseInputTooLarge*() {.noreturn, raises: [Defect, InputTooLarge].} =
  raise newException(InputTooLarge, "Input too large to be compressed with Snappy")
