# Snappy
[![Build Status](https://travis-ci.org/status-im/nim-snappy.svg?branch=master)](https://travis-ci.org/status-im/nim-snappy)
[![Build status](https://ci.appveyor.com/api/projects/status/g4y9874tx0biv3t1/branch/master?svg=true)](https://ci.appveyor.com/project/nimbus/nim-snappy/branch/master)
![nimble](https://img.shields.io/badge/available%20on-nimble-yellow.svg?style=flat-square)
![license](https://img.shields.io/github/license/citycide/cascade.svg?style=flat-square)
![Github action](https://github.com/status-im/nim-snappy/workflows/CI/badge.svg)

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
