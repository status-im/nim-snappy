{.used.}

import
  os, strformat, stats, times,
  snappy, openarrays_snappy, nimstreams_snappy, cpp_snappy

const
  currentDir = currentSourcePath.parentDir
  dataDir = currentDir & DirSep & "data" & DirSep

type
  TestTimes = object
    fastStreams: array[2, RunningStat]
    openArrays: array[2, RunningStat]
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
    echo &"{\"fastStreams\" :>16}, {\"openArrays\" :>16}, {\"nimStreams\" :>16}, " &
      &"{\"cppLib\" :>16}, {\"Samples\" :>12}, {\"Size\" :>12}, {\"Test\" :>12}"

  echo f(t.fastStreams),
    f(t.openArrays),
    f(t.nimStreams),
    f(t.cppLib),
    &"{t.fastStreams[0].n :>12}, ",
    &"{t.size :>12}, ",
    name

proc readSource(sourceName: string): seq[byte] =
  var f = open(sourceName, fmRead)
  if f.isNil: return
  let size = f.getFileSize()
  result = newSeq[byte](size)
  doAssert(size == f.readBytes(result, 0, size))
  f.close()

proc timedRoundTrip(msg: string, source: openarray[byte], iterations = 100) =
  when declared(GC_fullCollect):
    GC_fullCollect()

  var timers: TestTimes
  timers.size = source.len()

  for i in 0..<iterations:
    timeit(timers.fastStreams[0]):
      let encodedWithFastStreams = snappy.encode(source)

    timeit(timers.fastStreams[1]):
      var decodedWithFastStreams = snappy.decode(encodedWithFastStreams)

    timeit(timers.nimStreams[0]):
      var encodedWithNimStreams = nimstreams_snappy.encode(source)

    timeit(timers.nimStreams[1]):
      var decodedWithNimStreams = nimstreams_snappy.decode(encodedWithNimStreams)

    timeit(timers.openArrays[0]):
      var encodedWithOpenArrays = openarrays_snappy.encode(source)

    timeit(timers.openArrays[1]):
      var decodedWithOpenArrays = openarrays_snappy.decode(encodedWithOpenArrays)

    timeit(timers.cppLib[0]):
      var encodedWithCpp = cpp_snappy.encode(source)

    timeit(timers.cppLib[1]):
      var decodedWithCpp = cpp_snappy.decode(encodedWithCpp)

    doAssert decodedWithFastStreams == source
    doAssert decodedWithNimStreams == source
    doAssert decodedWithOpenArrays == source
    doAssert decodedWithCpp == source

  printTimes(timers, msg)

proc roundTrip(msg: string, source: openArray[byte], iterations = 100) =
  timedRoundTrip(msg, source, iterations)

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
  roundTrip(dataDir & "state-2560000-114a593d-0d5e08e8.ssz", 10)
