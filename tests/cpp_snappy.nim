import std/os

const
  currentDir = currentSourcePath.parentDir

{.passl: "-lsnappy -L\"" & currentDir & "\" -lstdc++".}

proc snappy_compress*(input: cstring, input_length: csize_t, compressed: ptr cchar, compressed_length: var csize_t): cint {.importc, cdecl.}
proc snappy_uncompress*(compressed: cstring, compressed_length: csize_t, uncompressed: ptr cchar, uncompressed_length: var csize_t): cint {.importc, cdecl.}
proc snappy_max_compressed_length*(source_length: csize_t): csize_t {.importc, cdecl.}
proc snappy_uncompressed_length*(compressed: cstring, compressed_length: csize_t, res: var csize_t): cint {.importc, cdecl.}

proc encode*(input: openArray[byte]): seq[byte] =
  result = newSeqUninitialized[byte](
    snappy_max_compressed_length(input.len.csize_t))
  var bytes = result.len.csize_t
  let res = if input.len() == 0:
    snappy_compress(nil, 0, cast[ptr cchar](result[0].addr), bytes)
  else:
    snappy_compress(
      cast[cstring](unsafeAddr input[0]), input.len().csize_t,
      cast[ptr cchar](result[0].addr), bytes)
  if res != 0:
    raise (ref ValueError)(msg: "Cannot compress")

  result.setLen(bytes.int)

proc decode*(input: openArray[byte]): seq[byte] =
  if input.len() == 0:
    raise (ref ValueError)(msg: "empty input")

  var bytes: csize_t
  if snappy_uncompressed_length(
    cast[cstring](input[0].unsafeAddr), input.len.csize_t, bytes) != 0:
    raise (ref ValueError)(msg: "Cannot get length")

  if bytes == 0:
    return

  result = newSeqUninitialized[byte](bytes.int)

  if snappy_uncompress(
      cast[cstring](unsafeAddr input[0]), input.len().csize_t,
      cast[ptr cchar](result[0].addr), bytes) != 0:
    raise (ref ValueError)(msg: "Cannot uncompress")
