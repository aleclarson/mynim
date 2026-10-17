## Seekable byte source and ID3 tag skipping from
## github.com/hajimehoshi/go-mp3. Copyright 2017 Hajime Hoshi.
## Licensed under Apache-2.0.

import std/streams
import ./consts

type Mp3Source* = ref object
  stream: Stream
  basePosition: int
  buffer: seq[byte]
  position: int64

proc newMp3Source*(stream: Stream): Mp3Source =
  if stream.isNil:
    raise newException(ValueError, "mp3: nil source")
  result = Mp3Source(stream: stream, basePosition: stream.getPosition())
  if result.basePosition < 0:
    raise newException(ValueError, "mp3: source must be seekable")

proc position*(source: Mp3Source): int64 = source.position

proc seek*(source: Mp3Source; position: int64): int64 =
  if position < 0 or position > int64(high(int) - source.basePosition):
    raise newException(ValueError, "mp3: seek out of range")
  source.stream.setPosition(source.basePosition + int(position))
  source.position = position
  source.buffer.setLen(0)
  result = position

proc unread*(source: Mp3Source; data: openArray[byte]) =
  if data.len == 0:
    return
  var buffered = newSeqOfCap[byte](data.len + source.buffer.len)
  buffered.add data
  buffered.add source.buffer
  source.buffer = move(buffered)
  source.position -= int64(data.len)

proc readFull*(source: Mp3Source; destination: var openArray[byte]): int =
  if destination.len == 0:
    return
  if source.buffer.len > 0:
    result = min(destination.len, source.buffer.len)
    copyMem(addr destination[0], unsafeAddr source.buffer[0], result)
    if result == source.buffer.len:
      source.buffer.setLen(0)
    else:
      source.buffer = source.buffer[result .. ^1]
    source.position += int64(result)
    if result == destination.len:
      return

  while result < destination.len:
    let n = source.stream.readData(addr destination[result],
      destination.len - result)
    if n <= 0:
      var error = newException(Mp3EofError, "mp3: unexpected end of input")
      error.bytesRead = result
      raise error
    result += n
    source.position += int64(n)

proc readExact*(source: Mp3Source; count: int): seq[byte] =
  if count < 0:
    raise newException(ValueError, "mp3: invalid read size")
  result = newSeq[byte](count)
  discard source.readFull(result)

proc skipTags*(source: Mp3Source) =
  var prefix: array[3, byte]
  discard source.readFull(prefix)
  if prefix == [byte('T'), byte('A'), byte('G')]:
    discard source.readExact(125)
  elif prefix == [byte('I'), byte('D'), byte('3')]:
    discard source.readExact(3) # version and flags
    let sizeBytes = source.readExact(4)
    let size = (uint32(sizeBytes[0]) shl 21) or
      (uint32(sizeBytes[1]) shl 14) or (uint32(sizeBytes[2]) shl 7) or
      uint32(sizeBytes[3])
    if size > uint32(high(int)):
      raise newException(ValueError, "mp3: ID3 tag is too large")
    discard source.readExact(int(size))
  else:
    source.unread(prefix)

proc rewind*(source: Mp3Source) =
  discard source.seek(0)
