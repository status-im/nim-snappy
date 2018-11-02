# Snappy
[![Build Status (Travis)](https://img.shields.io/travis/jangko/snappy/master.svg?label=Linux%20/%20macOS "Linux/macOS build status (Travis)")](https://travis-ci.org/jangko/snappy)
[![Windows build status (Appveyor)](https://img.shields.io/appveyor/ci/jangko/snappy/master.svg?label=Windows "Windows build status (Appveyor)")](https://ci.appveyor.com/project/jangko/snappy)
![nimble](https://img.shields.io/badge/available%20on-nimble-yellow.svg?style=flat-square)
![license](https://img.shields.io/github/license/citycide/cascade.svg?style=flat-square)

Nim implementation of Snappy compression algorithm

Currently, this implementation only support block compression and 
no stream compression support at all.

## API
* proc encode*(src: openArray[byte]): seq[byte]
* proc decode*(src: openArray[byte]): seq[byte]
* template compress --- an alias to encode
* template uncompress --- an alias to decode

## Examples
```Nim
import snappy
var source = readFile("readme.md")
var encoded = snappy.encode(toOpenArrayByte(source, 0, source.len-1))
var decoded = snappy.decode(encoded)
assert equalMem(decoded[0].addr, source[0].addr, source.len)
```

## Installation via nimble
> nimble install snappy
