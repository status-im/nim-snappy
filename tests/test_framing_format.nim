import
  unittest, os,
  faststreams,
  ../snappy/framing

template check_uncompress(source, target: string) =
  test "uncompress " & source & " to " & target:
    var inStream = fileInput(compDir & source)
    var outStream = memoryOutput()

    framing_format_uncompress(inStream, outStream)

    let expected = readFile(uncompDir & target)
    let actual = outStream.getOutput(string)

    if actual != expected:
      check false
    else:
      check true

template check_roundtrip(source) =
  test "roundtrip " & source:
    let expected = readFile(uncompDir & source)
    var ost = memoryOutput()

    framing_format_compress(ost, expected.toOpenArrayByte(0, expected.len-1))
    let compressed = ost.getOutput(string)
    debugEcho "compressed len: ", compressed.len

    var inst = memoryInput(compressed)
    var outst = memoryOutput()
    framing_format_uncompress(inst, outst)
    let actual = outst.getOutput(string)
    check actual.len == expected.len

    if actual != expected:
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

    check_roundtrip("alice29.txt")
    check_roundtrip("house.jpg")
    check_roundtrip("html")
    check_roundtrip("urls.10K")
    check_roundtrip("fireworks.jpeg")

    check_roundtrip("paper-100k.pdf")

    check_roundtrip("html_x_4")
    check_roundtrip("asyoulik.txt")
    check_roundtrip("lcet10.txt")
    check_roundtrip("plrabn12.txt")
    check_roundtrip("geo.protodata")
    check_roundtrip("kppkn.gtb")
    check_roundtrip("Mark.Twain-Tom.Sawyer.txt")
main()
