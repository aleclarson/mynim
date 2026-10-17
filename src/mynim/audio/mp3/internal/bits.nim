## MSB-first bit access from github.com/hajimehoshi/go-mp3.
## Copyright 2017 Hajime Hoshi. Licensed under Apache-2.0.

type Bits* = object
  data: seq[byte]
  bitPosition, bytePosition: int

proc initBits*(data: sink seq[byte]): Bits =
  Bits(data: data)

proc append*(bits: Bits; data: openArray[byte]): Bits =
  result.data = newSeqOfCap[byte](bits.data.len + data.len)
  result.data.add bits.data
  result.data.add data

proc bit*(bits: var Bits): int =
  if bits.bytePosition >= bits.data.len:
    return 0
  result = (int(bits.data[bits.bytePosition]) shr (7 - bits.bitPosition)) and 1
  bits.bytePosition += (bits.bitPosition + 1) shr 3
  bits.bitPosition = (bits.bitPosition + 1) and 7

proc bits*(bits: var Bits; count: int): int =
  if count == 0 or bits.bytePosition >= bits.data.len:
    return 0
  var word: uint32
  for i in 0 ..< min(4, bits.data.len - bits.bytePosition):
    word = word or (uint32(bits.data[bits.bytePosition + i]) shl
      (24 - 8 * i))
  word = word shl bits.bitPosition
  word = word shr (32 - count)
  bits.bytePosition += (bits.bitPosition + count) shr 3
  bits.bitPosition = (bits.bitPosition + count) and 7
  int(word)

proc bitPos*(bits: Bits): int = (bits.bytePosition shl 3) + bits.bitPosition

proc setPos*(bits: var Bits; position: int) =
  bits.bytePosition = position shr 3
  bits.bitPosition = position and 7

proc lenInBytes*(bits: Bits): int = bits.data.len

proc tail*(bits: Bits; offset: int): seq[byte] =
  bits.data[bits.data.len - offset ..< bits.data.len]
