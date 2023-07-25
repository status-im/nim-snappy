{.used.}

import
  stew/byteutils,
  os, strformat, stats, times,
  snappy, cpp_snappy, ../snappy/[faststreams, streams]

const
  currentDir = currentSourcePath.parentDir
  dataDir = currentDir & DirSep & "data" & DirSep

type
  TestTimes = object
    inMemory: array[2, RunningStat]
    fastStreams: array[2, RunningStat]
    nimStreams: array[2, RunningStat]
    cppLib: array[2, RunningStat]
    size: int

template timeit(timerVar: var RunningStat, code: untyped) =
  let t0 = cpuTime()
  code
  timerVar.push cpuTime() - t0

var printedHeader = false

proc printTimes(t: TestTimes, name: string) =
  func f(t: array[2, RunningStat]): string =
    &"{t[0].mean * 1000 :>7.3f} /{t[1].mean * 1000 :>7.3f}, "

  if not printedHeader:
    printedHeader = true
    echo &"{\"inMemory\" :>16}, {\"fastStreams\" :>16}, {\"nimStreams\" :>16}, " &
      &"{\"cppLib\" :>16}, {\"Samples\" :>12}, {\"Size\" :>12}, {\"Test\" :>12}"

  echo f(t.inMemory),
    f(t.fastStreams),
    f(t.nimStreams),
    f(t.cppLib),
    &"{t.fastStreams[0].n :>12}, ",
    &"{t.size :>12}, ",
    name

proc readSource(sourceName: string): seq[byte] =
  var f = open(sourceName, fmRead)
  if f.isNil: return
  let size = f.getFileSize()
  result = newSeqUninitialized[byte](size)
  doAssert(size == f.readBytes(result, 0, size))
  f.close()

proc memEncode(input: openArray[byte]): seq[byte] {.noinline.} =
  snappy.encode(input)

proc memDecode(input: openArray[byte]): seq[byte] {.noinline.} =
  snappy.decode(input)

proc streamsEncode(input: openArray[byte]): seq[byte] {.noinline.} =
  let
    ins = newStringStream(string.fromBytes(input))
    outs = newStringStream()
  compress(ins, input.len, outs)
  outs.setPosition(0)
  outs.readAll().toBytes() # This line is a hotspot due to missing RVO

proc faststreamsEncode(input: openArray[byte]): seq[byte] {.noinline.} =
  let
    ins = unsafeMemoryInput(input)
    outs = memoryOutput()
  compress(ins, outs)
  outs.getOutput() # This line is a hotspot due to missing RVO

proc memEncodeFramed(input: openArray[byte]): seq[byte] {.noinline.} =
  snappy.encodeFramed(input)

proc memDecodeFramed(input: openArray[byte]): seq[byte] {.noinline.} =
  snappy.decodeFramed(input)

proc faststreamsEncodeFramed(input: openArray[byte]): seq[byte] {.noinline.} =
  let
    ins = unsafeMemoryInput(input)
    outs = memoryOutput()
  compressFramed(ins, outs)
  outs.getOutput() # This line is a hotspot due to missing RVO

proc faststreamsDecodeFramed(input: openArray[byte]): seq[byte] {.noinline.} =
  let
    ins = unsafeMemoryInput(input)
    outs = memoryOutput()
  uncompressFramed(ins, outs)
  outs.getOutput() # This line is a hotspot due to missing RVO

proc timedRoundTrip(msg: string, source: openArray[byte], iterations = 100) =
  when declared(GC_fullCollect):
    GC_fullCollect()

  var timers: TestTimes
  timers.size = source.len()

  for i in 0..<iterations:
    timeit(timers.inMemory[0]):
      let encodedWithSnappy = memEncode(source)
    timeit(timers.inMemory[1]):
      let decodedWithSnappy = memDecode(encodedWithSnappy)

    timeit(timers.fastStreams[0]):
      let encodedWithFastStreams = faststreamsEncode(source)
    # timeit(timers.fastStreams[1]):
    #   var decodedWithFastStreams = snappy.decode(encodedWithFastStreams)

    timeit(timers.nimStreams[0]):
      var encodedWithNimStreams = streamsEncode(source)
    # timeit(timers.nimStreams[1]):
    #   var decodedWithNimStreams = streamsDecode(encodedWithNimStreams)

    timeit(timers.cppLib[0]):
      var encodedWithCpp = cpp_snappy.encode(source)
    timeit(timers.cppLib[1]):
      var decodedWithCpp = cpp_snappy.decode(encodedWithCpp)

    # doAssert decodedWithFastStreams == source
    # doAssert decodedWithNimStreams == source
    doAssert decodedWithSnappy == source
    doAssert decodedWithCpp == source

  printTimes(timers, msg)

proc timedRoundTripFramed(msg: string, source: openArray[byte], iterations = 100) =
  when declared(GC_fullCollect):
    GC_fullCollect()

  var timers: TestTimes
  timers.size = source.len()

  for i in 0..<iterations:
    timeit(timers.inMemory[0]):
      let encodedWithSnappy = memEncodeFramed(source)
    timeit(timers.inMemory[1]):
      let decodedWithSnappy = memDecodeFramed(encodedWithSnappy)

    timeit(timers.fastStreams[0]):
      let encodedWithFastStreams = faststreamsEncodeFramed(source)
    timeit(timers.fastStreams[1]):
      var decodedWithFastStreams = faststreamsDecodeFramed(encodedWithFastStreams)

    # timeit(timers.nimStreams[0]):
    #   var encodedWithNimStreams = streamsEncode(source)
    # timeit(timers.nimStreams[1]):
    #   var decodedWithNimStreams = streamsDecode(encodedWithNimStreams)

    doAssert decodedWithFastStreams == source
    # doAssert decodedWithNimStreams == source
    doAssert decodedWithSnappy == source

  printTimes(timers, msg & "(framed)")

proc roundTrip(msg: string, source: openArray[byte], iterations = 100) =
  timedRoundTrip(msg, source, iterations)
  timedRoundTripFramed(msg, source, iterations)

proc roundTrip(sourceName: string, iterations = 100) =
  var src = readSource(sourceName)
  roundTrip(extractFilename(sourceName), src, iterations)

roundTrip(dataDir & "html")
roundTrip(dataDir & "urls.10K")
roundTrip(dataDir & "fireworks.jpeg")
roundTrip(dataDir & "paper-100k.pdf")
roundTrip(dataDir & "html_x_4")
roundTrip(dataDir & "alice29.txt")
roundTrip(dataDir & "asyoulik.txt")
roundTrip(dataDir & "lcet10.txt")
roundTrip(dataDir & "plrabn12.txt")
roundTrip(dataDir & "geo.protodata")
roundTrip(dataDir & "kppkn.gtb")
roundTrip(dataDir & "Mark.Twain-Tom.Sawyer.txt")

# ncli_db --db:db rewindState 0x488b7150f092949f1dfc3137c4e2909a20fe9739d67a5185d75dbd0440c51edd 6800000
if fileExists(dataDir & "state-6800000-488b7150-d613b584.ssz"):
  roundTrip(dataDir & "state-6800000-488b7150-d613b584.ssz", 50)
