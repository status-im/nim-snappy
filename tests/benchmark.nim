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

proc streamsEncode(input: openArray[byte]): seq[byte] =
  let
    ins = newStringStream(string.fromBytes(input))
    outs = newStringStream()
  compress(ins, input.len, outs)
  outs.setPosition(0)
  outs.readAll().toBytes() # This line is a hotspot due to missing RVO

proc faststreamsEncode(input: openArray[byte]): seq[byte] =
  let
    ins = unsafeMemoryInput(input)
    outs = memoryOutput()
  compress(ins, outs)
  outs.getOutput() # This line is a hotspot due to missing RVO

proc faststreamsEncodeFramed(input: openArray[byte]): seq[byte] =
  let
    ins = unsafeMemoryInput(input)
    outs = memoryOutput()
  compressFramed(ins, outs)
  outs.getOutput() # This line is a hotspot due to missing RVO

proc faststreamsDecodeFramed(input: openArray[byte]): seq[byte] =
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
      let encodedWithSnappy = snappy.encode(source)
    timeit(timers.inMemory[1]):
      let decodedWithSnappy = snappy.decode(encodedWithSnappy)

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
      let encodedWithSnappy = snappy.encodeFramed(source)
    timeit(timers.inMemory[1]):
      let decodedWithSnappy = snappy.decodeFramed(encodedWithSnappy)

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

# ncli_db --db:db dumpState 0x114a593d248af2ad05580299b803657d4b78a3b6578f47425cc396c9644e800e 2560000
if fileExists(dataDir & "state-2560000-114a593d-0d5e08e8.ssz"):
  roundTrip(dataDir & "state-2560000-114a593d-0d5e08e8.ssz", 50)
