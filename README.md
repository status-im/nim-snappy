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
  0.086 /  0.087,   0.090 /  0.000,   0.106 /  0.000,   0.093 /  0.033,          100,       102400, html
  0.118 /  0.116,   0.121 /  0.129,   0.000 /  0.000,   0.000 /  0.000,          100,       102400, html(framed)
  1.017 /  0.786,   1.045 /  0.000,   1.322 /  0.000,   1.045 /  0.374,          100,       702087, urls.10K
  1.219 /  0.984,   1.246 /  1.081,   0.000 /  0.000,   0.000 /  0.000,          100,       702087, urls.10K(framed)
  0.007 /  0.004,   0.015 /  0.000,   0.094 /  0.000,   0.008 /  0.004,          100,       123093, fireworks.jpeg
  0.053 /  0.050,   0.071 /  0.063,   0.000 /  0.000,   0.000 /  0.000,          100,       123093, fireworks.jpeg(framed)
  0.009 /  0.007,   0.019 /  0.000,   0.075 /  0.000,   0.010 /  0.006,          100,       102400, paper-100k.pdf
  0.047 /  0.044,   0.058 /  0.057,   0.000 /  0.000,   0.000 /  0.000,          100,       102400, paper-100k.pdf(framed)
  0.354 /  0.343,   0.356 /  0.000,   0.438 /  0.000,   0.372 /  0.131,          100,       409600, html_x_4
  0.474 /  0.468,   0.482 /  0.516,   0.000 /  0.000,   0.000 /  0.000,          100,       409600, html_x_4(framed)
  0.328 /  0.317,   0.330 /  0.000,   0.389 /  0.000,   0.341 /  0.135,          100,       152089, alice29.txt
  0.379 /  0.367,   0.389 /  0.386,   0.000 /  0.000,   0.000 /  0.000,          100,       152089, alice29.txt(framed)
  0.300 /  0.278,   0.301 /  0.000,   0.354 /  0.000,   0.313 /  0.125,          100,       129301, asyoulik.txt
  0.342 /  0.316,   0.348 /  0.330,   0.000 /  0.000,   0.000 /  0.000,          100,       129301, asyoulik.txt(framed)
  0.861 /  0.843,   0.884 /  0.000,   1.053 /  0.000,   0.901 /  0.350,          100,       426754, lcet10.txt
  1.011 /  0.981,   1.031 /  1.029,   0.000 /  0.000,   0.000 /  0.000,          100,       426754, lcet10.txt(framed)
  1.177 /  1.009,   1.215 /  0.000,   1.423 /  0.000,   1.221 /  0.496,          100,       481861, plrabn12.txt
  1.345 /  1.177,   1.387 /  1.229,   0.000 /  0.000,   0.000 /  0.000,          100,       481861, plrabn12.txt(framed)
  0.068 /  0.067,   0.072 /  0.000,   0.096 /  0.000,   0.081 /  0.027,          100,       118588, geo.protodata
  0.110 /  0.098,   0.111 /  0.112,   0.000 /  0.000,   0.000 /  0.000,          100,       118588, geo.protodata(framed)
  0.269 /  0.330,   0.272 /  0.000,   0.325 /  0.000,   0.279 /  0.122,          100,       184320, kppkn.gtb
  0.338 /  0.391,   0.347 /  0.409,   0.000 /  0.000,   0.000 /  0.000,          100,       184320, kppkn.gtb(framed)
  0.020 /  0.024,   0.020 /  0.000,   0.030 /  0.000,   0.030 /  0.013,          100,        14564, Mark.Twain-Tom.Sawyer.txt
  0.024 /  0.021,   0.028 /  0.022,   0.000 /  0.000,   0.000 /  0.000,          100,        14564, Mark.Twain-Tom.Sawyer.txt(framed)
 22.617 / 10.822,  24.874 /  0.000,  48.604 /  0.000,  22.640 /  7.456,           50,     38942424, state-2560000-114a593d-0d5e08e8.ssz
 35.458 / 23.883,  39.628 / 31.175,   0.000 /  0.000,   0.000 /  0.000,           50,     38942424, state-2560000-114a593d-0d5e08e8.ssz(framed)
```

## Installation via nimble

```bash
nimble install snappy
```
