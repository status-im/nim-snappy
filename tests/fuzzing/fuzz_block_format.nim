import
  testutils/fuzzing,
  ../../snappy

{.push raises: [Defect].}

{.passl: "-lsnappy".}

proc snappy_compress(input: cstring, input_length: csize, compressed: cstring, compressed_length: var csize): cint {.importc, cdecl.}
proc snappy_uncompress(compressed: cstring, compressed_length: csize, uncompressed: cstring, uncompressed_length: var csize): cint {.importc, cdecl.}
proc snappy_max_compressed_length(source_length: csize): csize {.importc, cdecl.}
proc snappy_uncompressed_length(compressed: cstring, compressed_length: csize, res: var csize): cint {.importc, cdecl.}

proc startsWith(lhs, rhs: openarray[byte]): bool =
  if lhs.len < rhs.len:
    return false

  equalMem(unsafeAddr lhs[0], unsafeAddr rhs[0], rhs.len)

test:
  block:
    if payload.len == 0:
      break
    let decoded = snappy.decode(payload, 128*1024*1024)
    if decoded.len > 0:
      let encoded = snappy.encode(decoded)
      if not payload.startsWith(encoded):
        var cppDecompressedLen: csize
        let payload = @payload
        if snappy_uncompressed_length(cast[cstring](unsafeAddr payload[0]),
                                      payload.len.csize, cppDecompressedLen) == 0:
          var cppDecompressed = newSeq[byte](cppDecompressedLen)
          if snappy_uncompress(cast[cstring](unsafeAddr payload[0]), payload.len.csize,
                                cast[cstring](addr cppDecompressed[0]), cppDecompressedLen) == 0:
            if cppDecompressed == decoded:
              discard
              # echo "C++ decompression matches ours"
            else:
              echo "C++ decompression doesn't match ours"

            var cppCompressedLen = snappy_max_compressed_length(cppDecompressed.len.csize)
            var cppCompressed = newSeq[byte](cppCompressedLen)
            if snappy_compress(cast[cstring](addr cppDecompressed[0]), cppDecompressed.len,
                                cast[cstring](addr cppCompressed[0]), cppCompressedLen) == 0:
              cppCompressed.setLen cppCompressedLen
              if payload.startsWith(cppCompressed):
                echo "C++ result matches original payload"
              elif cppCompressed == encoded:
                break
                # echo "C++ result matches ours"
              else:
                echo "C++ result differs both from payload and ours"
            else:
              echo "C++ failed to compress back the payload"
          else:
            echo "C++ failed to decompress the payload"
        else:
          echo "C++ failed to obtain the payload decompressed length++"

        echo "encoded len ", encoded.len
        # echo encoded
        echo "orig payload len ", payload.len
        # echo payload
        doAssert false
