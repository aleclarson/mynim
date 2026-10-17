## Raw DEFLATE streams for update deltas.
##
## The encoder writes a fixed-Huffman block with bounded-window LZ77 matches.
## The decoder accepts every DEFLATE block kind supported by image.inflate.

import ../image as mynimImage

type BitWriter = object
  bytes: seq[byte]
  buffer: uint32
  bits: int

proc writeBits(w: var BitWriter; value: uint32; count: int) =
  if count > 0:
    let mask = (1'u32 shl count) - 1
    w.buffer = w.buffer or ((value and mask) shl w.bits)
    w.bits += count
    while w.bits >= 8:
      w.bytes.add byte(w.buffer and 0xff)
      w.buffer = w.buffer shr 8
      w.bits -= 8

proc reverseBits(code, count: int): uint32 =
  for i in 0 ..< count:
    result = (result shl 1) or uint32((code shr i) and 1)

proc writeFixedSymbol(w: var BitWriter; symbol: int) =
  var code, count: int
  if symbol <= 143:
    code = 0x30 + symbol
    count = 8
  elif symbol <= 255:
    code = 0x190 + symbol - 144
    count = 9
  elif symbol <= 279:
    code = symbol - 256
    count = 7
  else:
    code = 0xc0 + symbol - 280
    count = 8
  w.writeBits(reverseBits(code, count), count)

const
  lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27,
    31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3,
    3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
  distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97,
    129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
    8193, 12289, 16385, 24577]
  distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

proc emitLengthDistance(w: var BitWriter; length, distance: int) =
  var lengthCode = -1
  for i, base in lengthBase:
    let limit = base + (1 shl lengthExtra[i]) - 1
    if length >= base and length <= limit:
      lengthCode = i
      break
  if lengthCode < 0:
    raise newException(ValueError, "deflate: invalid match length")
  w.writeFixedSymbol(257 + lengthCode)
  w.writeBits(uint32(length - lengthBase[lengthCode]),
    lengthExtra[lengthCode])

  var distanceCode = -1
  for i, base in distanceBase:
    let limit = base + (1 shl distanceExtra[i]) - 1
    if distance >= base and distance <= limit:
      distanceCode = i
      break
  if distanceCode < 0:
    raise newException(ValueError, "deflate: invalid match distance")
  w.writeBits(reverseBits(distanceCode, 5), 5)
  w.writeBits(uint32(distance - distanceBase[distanceCode]),
    distanceExtra[distanceCode])

proc hashAt(data: openArray[byte]; pos: int): int {.inline.} =
  ((int(data[pos]) * 251 + int(data[pos + 1])) * 251 +
    int(data[pos + 2])) and 0xffff

proc deflateRaw*(data: openArray[byte]): seq[byte] =
  ## Compresses data into one RFC 1951 raw DEFLATE stream.
  let input = @data
  const windowSize = 1 shl 15
  const windowMask = windowSize - 1
  const hashSize = 1 shl 16
  var head = newSeq[int32](hashSize)
  var previous = newSeq[int32](windowSize)
  for item in head.mitems: item = -1
  for item in previous.mitems: item = -1

  proc insert(pos: int) =
    if pos + 2 >= input.len: return
    let h = hashAt(input, pos)
    previous[pos and windowMask] = head[h]
    head[h] = int32(pos)

  var writer: BitWriter
  writer.writeBits(1, 1) ## final block
  writer.writeBits(1, 2) ## fixed Huffman block
  var pos = 0
  while pos < input.len:
    var bestLength = 0
    var bestDistance = 0
    if pos + 2 < input.len:
      var candidate = int(head[hashAt(input, pos)])
      let earliest = max(0, pos - windowSize)
      var tries = 0
      let maxLength = min(258, input.len - pos)
      while candidate >= earliest and candidate < pos and tries < 64:
        let distance = pos - candidate
        var length = 0
        while length < maxLength and
            input[candidate + length] == input[pos + length]:
          inc length
        if length > bestLength:
          bestLength = length
          bestDistance = distance
          if length == maxLength: break
        candidate = int(previous[candidate and windowMask])
        inc tries
    if bestLength >= 3:
      writer.emitLengthDistance(bestLength, bestDistance)
      for i in 0 ..< bestLength:
        insert(pos + i)
      pos += bestLength
    else:
      writer.writeFixedSymbol(int(input[pos]))
      insert(pos)
      inc pos
  writer.writeFixedSymbol(256)
  if writer.bits > 0:
    writer.bytes.add byte(writer.buffer and 0xff)
  writer.bytes

proc inflateRaw*(data: openArray[byte]; maxOutput: int): seq[byte] =
  ## Inflates a raw DEFLATE stream with an explicit output limit.
  if maxOutput < 0:
    raise newException(ValueError, "deflate: invalid output limit")
  var wrapped = newSeq[byte](data.len + 6)
  wrapped[0] = 0x78
  wrapped[1] = 0x9c
  for i, value in data:
    wrapped[i + 2] = value
  ## image.inflate checks block bounds and caps expansion; it does not use
  ## the RFC 1950 checksum, so the wrapper trailer is only a sentinel.
  result = mynimImage.inflate(wrapped, maxOutput)
