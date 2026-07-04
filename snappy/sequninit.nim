{.push raises: [].}
{.used.}

when (NimMajor, NimMinor) < (2, 2):
  template newSeqUninit*[T: byte](len: Natural): seq[byte] =
    newSeqUninitialized[byte](len)
