type
  SnappyError* = object of CatchableError
  UnexpectedEofError* = object of SnappyError
  MalformedSnappyData* = object of SnappyError

