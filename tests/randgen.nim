import
  random, sets

type
  RandGen*[T] = object
    minVal, maxVal: T

  KVPair* = ref object
    key*: string
    value*: string

proc randGen*[T](minVal, maxVal: T): RandGen[T] =
  assert(minVal <= maxVal)
  result.minVal = minVal
  result.maxVal = maxVal

proc getVal*[T](x: RandGen[T]): T =
  if x.minVal == x.maxVal: return x.minVal
  rand(x.minVal..x.maxVal)

proc randString*(len: int): string =
  result = newString(len)
  for i in 0..<len:
    result[i] = rand(255).char

proc randPrimitives*[T](val: int): T =
  when T is string:
    randString(val)
  elif T is int:
    result = val

iterator randList*(T: typedesc, strGen, listGen: RandGen, unique: bool = true): T =
  let listLen = listGen.getVal()
  if unique:
    var set = initHashSet[T]()
    for len in 0..<listLen:
      while true:
        let x = randPrimitives[T](strGen.getVal())
        if x notin set:
          yield x
          set.incl x
          break
  else:
    for len in 0..<listLen:
      let x = randPrimitives[T](strGen.getVal())
      yield x
