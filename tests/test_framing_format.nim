import
  unittest, os,
  faststreams,
  ../snappy/framing

template check_uncompress(source, target: string) =
  test "uncompress " & source & " to " & target:
    var inStream = openFile(compDir & source)
    var outStream = OutputStream.init

    framing_format_uncompress(inStream, outStream)

    var okResult = readFile(uncompDir & target)
    if outStream.getOutput(string) != okResult:
      check false
    else:
      check true

proc main() =
  suite "framing":
    setup:
      let
        compDir = getAppDir() & DirSep & "stream_compressed" & DirSep
        uncompDir = getAppDir() & DirSep & "data" & DirSep

    check_uncompress("alice29.txt.sz-32k", "alice29.txt")
    check_uncompress("alice29.txt.sz-64k", "alice29.txt")
    check_uncompress("house.jpg.sz", "house.jpg")

main()
