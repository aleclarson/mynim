## Vorbis bit access, ported from github.com/jfreymuth/vorbis.
## Copyright (c) 2016 Johann Freymuth. Licensed under the MIT License.

type BitReader* = object
  data: seq[byte]
  position: int
  bitOffset: int
  eof: bool

proc initBitReader*(data: openArray[byte]): BitReader =
  result.data = @data

proc atEof*(reader: BitReader): bool = reader.eof

proc read1*(reader: var BitReader): uint32 =
  if reader.position >= reader.data.len:
    reader.eof = true
    return 0
  if (reader.data[reader.position] and (1'u8 shl reader.bitOffset)) != 0:
    result = 1
  if reader.bitOffset < 7:
    inc reader.bitOffset
  else:
    reader.bitOffset = 0
    inc reader.position

proc read*(reader: var BitReader; count, width: int): uint32 =
  if count < 0 or count > width or width > 32:
    raise newException(ValueError, "vorbis: invalid bit count")
  let size = count
  var remaining = count
  var written = 0
  while remaining > 0:
    if reader.position >= reader.data.len:
      reader.eof = true
      return 0
    result = result or (uint32(reader.data[reader.position] shr
      reader.bitOffset) shl written)
    let available = 8 - reader.bitOffset
    written += available
    if remaining < available:
      reader.bitOffset += remaining
      break
    remaining -= available
    reader.bitOffset = 0
    inc reader.position
  if size == 32:
    return result
  result = result and ((1'u32 shl size) - 1)

proc read8*(reader: var BitReader; count: int): uint8 =
  uint8(reader.read(count, 8))

proc read16*(reader: var BitReader; count: int): uint16 =
  uint16(reader.read(count, 16))

proc read32*(reader: var BitReader; count: int): uint32 =
  reader.read(count, 32)

proc readBool*(reader: var BitReader): bool = reader.read8(1) == 1

proc ilog*(value: int): int =
  var remaining = value
  while remaining > 0:
    inc result
    remaining = remaining shr 1
