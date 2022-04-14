# Snappy
[![Build Status](https://travis-ci.org/status-im/nim-snappy.svg?branch=master)](https://travis-ci.org/status-im/nim-snappy)
[![Build status](https://ci.appveyor.com/api/projects/status/g4y9874tx0biv3t1/branch/master?svg=true)](https://ci.appveyor.com/project/nimbus/nim-snappy/branch/master)
![nimble](https://img.shields.io/badge/available%20on-nimble-yellow.svg?style=flat-square)
![license](https://img.shields.io/github/license/citycide/cascade.svg?style=flat-square)
![Github action](https://github.com/status-im/nim-snappy/workflows/CI/badge.svg)

Compression and decompression utilities for the `snappy` compression algorithm:

* [Overview](http://google.github.io/snappy/)
* [Format description](https://github.com/google/snappy/blob/main/format_description.txt)

The main module, `snappy`, contains in-memory encoders and decoders:

* `compress`/`uncompress` work with caller-allocated buffers
  * No dynamic memory allocation (the functions require ~20kb stack space)
  * Exception-free
* `encode`/`decode` are convenience wrappers for the above that take care of
  memory allocation
  * Simplified error reporting
  * Suitable for small buffers mainly

Framed encodings are also supported via functions carrying the `Framed` suffix.

* [Framing format](https://github.com/google/snappy/blob/main/framing_format.txt)

## Stream support

The library supports compression and decompression for the following libraries

* [faststreams](https://github.com/status-im/nim-faststreams)
  * `import snappy/faststreams`
* [std/streams](https://nim-lang.org/docs/streams.html)
  * `import snappy/streams` (incomplete)

## API

### In-memory

```nim
import snappy

func compress*(
  input: openArray[byte],
  output: var openArray[byte]): Result[int, CodecError]
func encode*(input: openArray[byte]): seq[byte]
func uncompress*(input: openArray[byte], output: var openArray[byte]):
  Result[int, CodecError]
func decode*(input: openArray[byte], maxSize = maxUncompressedLen): seq[byte]
```

### faststreams

:warning: BETA API, subject to change

When using faststreams, errors are reported via exceptions.

Uncompressing raw snappy is not covered in streaming mode due to the requirement that full uncompressed data must be available during decompression.

```nim
import snappy/faststreams

proc compress*(input: InputStream, output: OutputStream)
proc compressFramed*(input: InputStream, output: OutputStream)
proc uncompressFramed*(input: InputStream, output: OutputStream)
```

### std/streams

:warning: BETA API, subject to change

```nim
import snappy/streams

proc compress*(input: Stream, inputLen: int, output: Stream)
# TODO compressFramed
# TODO uncompressFramed
```

## Examples
```Nim
import snappy
var source = readFile("readme.md")
var encoded = snappy.encode(toOpenArrayByte(source, 0, source.len-1))
var decoded = snappy.decode(encoded)
assert equalMem(decoded[0].addr, source[0].addr, source.len)
```

## Performance

Generally, performance is on par with the C++ implementation, shown as `cppLib`.

Framed encoding is slower due to the extra CRC32C processing.

The table shows average time to compress data in `ms` on x86_64. Lower is better.

```
        inMemory,      fastStreams,       nimStreams,           cppLib,      Samples,         Size,         Test
  0.086 /  0.056,   0.087 /  0.000,   0.112 /  0.000,   0.088 /  0.029,          100,       102400, html
  0.117 /  0.093,   0.118 /  0.094,   0.000 /  0.000,   0.000 /  0.000,          100,       102400, html(framed)
  1.052 /  0.480,   1.073 /  0.000,   1.322 /  0.000,   1.005 /  0.335,          100,       702087, urls.10K
  1.260 /  0.775,   1.286 /  0.785,   0.000 /  0.000,   0.000 /  0.000,          100,       702087, urls.10K(framed)
  0.008 /  0.005,   0.022 /  0.000,   0.092 /  0.000,   0.008 /  0.005,          100,       123093, fireworks.jpeg
  0.051 /  0.047,   0.067 /  0.057,   0.000 /  0.000,   0.000 /  0.000,          100,       123093, fireworks.jpeg(framed)
  0.010 /  0.006,   0.021 /  0.000,   0.066 /  0.000,   0.009 /  0.005,          100,       102400, paper-100k.pdf
  0.046 /  0.050,   0.057 /  0.054,   0.000 /  0.000,   0.000 /  0.000,          100,       102400, paper-100k.pdf(framed)
  0.374 /  0.218,   0.378 /  0.000,   0.451 /  0.000,   0.357 /  0.118,          100,       409600, html_x_4
  0.491 /  0.386,   0.498 /  0.392,   0.000 /  0.000,   0.000 /  0.000,          100,       409600, html_x_4(framed)
  0.334 /  0.186,   0.345 /  0.000,   0.399 /  0.000,   0.331 /  0.126,          100,       152089, alice29.txt
  0.382 /  0.251,   0.392 /  0.251,   0.000 /  0.000,   0.000 /  0.000,          100,       152089, alice29.txt(framed)
  0.300 /  0.165,   0.311 /  0.000,   0.354 /  0.000,   0.300 /  0.114,          100,       129301, asyoulik.txt
  0.343 /  0.220,   0.352 /  0.222,   0.000 /  0.000,   0.000 /  0.000,          100,       129301, asyoulik.txt(framed)
  0.907 /  0.483,   0.932 /  0.000,   1.086 /  0.000,   0.880 /  0.327,          100,       426754, lcet10.txt
  1.053 /  0.675,   1.075 /  0.680,   0.000 /  0.000,   0.000 /  0.000,          100,       426754, lcet10.txt(framed)
  1.241 /  0.646,   1.272 /  0.000,   1.477 /  0.000,   1.201 /  0.466,          100,       481861, plrabn12.txt
  1.387 /  0.856,   1.425 /  0.861,   0.000 /  0.000,   0.000 /  0.000,          100,       481861, plrabn12.txt(framed)
  0.076 /  0.050,   0.075 /  0.000,   0.096 /  0.000,   0.076 /  0.025,          100,       118588, geo.protodata
  0.110 /  0.095,   0.112 /  0.098,   0.000 /  0.000,   0.000 /  0.000,          100,       118588, geo.protodata(framed)
  0.279 /  0.183,   0.287 /  0.000,   0.338 /  0.000,   0.273 /  0.121,          100,       184320, kppkn.gtb
  0.346 /  0.261,   0.354 /  0.263,   0.000 /  0.000,   0.000 /  0.000,          100,       184320, kppkn.gtb(framed)
  0.024 /  0.018,   0.026 /  0.000,   0.032 /  0.000,   0.024 /  0.014,          100,        14564, Mark.Twain-Tom.Sawyer.txt
  0.030 /  0.021,   0.031 /  0.021,   0.000 /  0.000,   0.000 /  0.000,          100,        14564, Mark.Twain-Tom.Sawyer.txt(framed)
 23.814 /  8.608,  27.362 /  0.000,  48.342 /  0.000,  22.157 /  6.958,           50,     38942424, state-2560000-114a593d-0d5e08e8.ssz
 36.075 / 25.389,  39.979 / 28.497,   0.000 /  0.000,   0.000 /  0.000,           50,     38942424, state-2560000-114a593d-0d5e08e8.ssz(framed)```
```

## Installation via nimble

```bash
nimble install snappy
```
