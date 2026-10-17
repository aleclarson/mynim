## Streaming MP3 decoder from github.com/hajimehoshi/go-mp3.
## Copyright 2017 Hajime Hoshi. Licensed under Apache-2.0.

import std/streams
import ./[consts, frame, frameheader, source]

type Mp3FrameIndex = object
  sourcePosition: int64
  outputPosition: int64
  outputBytes: int64

type Mp3Decoder* = ref object
  source: Mp3Source
  sampleRate: int
  length: int64
  frameIndex: seq[Mp3FrameIndex]
  buffer: seq[byte]
  bufferPosition: int
  frame: Mp3Frame
  position: int64
  atEnd: bool

proc readFrame(decoder: Mp3Decoder): bool =
  try:
    let decoded = decoder.source.readMp3Frame(decoder.source.position(),
      decoder.frame)
    decoder.frame = decoded.frame
    decoder.buffer = decoder.frame.decode()
    decoder.bufferPosition = 0
    return true
  except Mp3EofError, UnexpectedMp3EofError:
    return false

proc ensureFrameStartsAndLength(decoder: Mp3Decoder) =
  let savedPosition = decoder.source.position()
  decoder.source.rewind()
  decoder.source.skipTags()
  var totalBytes = 0'i64
  while true:
    var parsed: tuple[header: FrameHeader, startPosition: int64]
    try:
      parsed = decoder.source.readFrameHeader(decoder.source.position())
    except Mp3EofError, UnexpectedMp3EofError:
      break
    let remaining = parsed.header.frameSize() - 4
    if remaining < 0:
      raise newException(ValueError, "mp3: invalid frame size")
    try:
      discard decoder.source.readExact(remaining)
    except Mp3EofError:
      break
    let outputBytes = int64(parsed.header.bytesPerFrame())
    decoder.frameIndex.add Mp3FrameIndex(
      sourcePosition: parsed.startPosition,
      outputPosition: totalBytes,
      outputBytes: outputBytes)
    totalBytes += outputBytes
  decoder.length = totalBytes
  discard decoder.source.seek(savedPosition)

proc newMp3Decoder*(stream: Stream): Mp3Decoder =
  let source = newMp3Source(stream)
  source.skipTags()
  result = Mp3Decoder(source: source, length: -1)
  if not result.readFrame():
    raise newException(ValueError, "mp3: no decodable frame")
  result.sampleRate = result.frame.sampleRate()
  result.ensureFrameStartsAndLength()

proc sampleRate*(decoder: Mp3Decoder): int = decoder.sampleRate

proc length*(decoder: Mp3Decoder): int64 = decoder.length

proc readBytes*(decoder: Mp3Decoder; destination: var openArray[byte]): int =
  if destination.len == 0 or decoder.atEnd:
    return
  if decoder.bufferPosition >= decoder.buffer.len:
    decoder.buffer.setLen(0)
    decoder.bufferPosition = 0
    if not decoder.readFrame():
      return
  result = min(destination.len, decoder.buffer.len - decoder.bufferPosition)
  copyMem(addr destination[0], unsafeAddr decoder.buffer[decoder.bufferPosition],
    result)
  decoder.bufferPosition += result
  decoder.position += int64(result)

proc setPosition*(decoder: Mp3Decoder; bytePosition: int64) =
  if bytePosition < 0 or decoder.length >= 0 and bytePosition > decoder.length:
    raise newException(ValueError, "mp3: seek out of range")
  decoder.position = bytePosition
  decoder.buffer.setLen(0)
  decoder.bufferPosition = 0
  decoder.frame = nil
  decoder.atEnd = bytePosition == decoder.length
  if decoder.atEnd:
    return
  if decoder.frameIndex.len == 0:
    raise newException(ValueError, "mp3: stream has no seek index")

  var low = 0
  var high = decoder.frameIndex.len
  while low + 1 < high:
    let middle = low + (high - low) div 2
    if decoder.frameIndex[middle].outputPosition <= bytePosition:
      low = middle
    else:
      high = middle
  let frameNumber = low
  let withinFrame = bytePosition - decoder.frameIndex[frameNumber].outputPosition
  if withinFrame >= decoder.frameIndex[frameNumber].outputBytes:
    raise newException(ValueError, "mp3: seek out of range")

  if frameNumber > 0:
    discard decoder.source.seek(decoder.frameIndex[frameNumber - 1].sourcePosition)
    if not decoder.readFrame():
      raise newException(ValueError, "mp3: could not seek to previous frame")
    discard decoder.source.seek(decoder.frameIndex[frameNumber].sourcePosition)
    if not decoder.readFrame():
      raise newException(ValueError, "mp3: could not seek to target frame")
  else:
    discard decoder.source.seek(decoder.frameIndex[0].sourcePosition)
    if not decoder.readFrame():
      raise newException(ValueError, "mp3: could not seek to first frame")
  if withinFrame > int64(decoder.buffer.len):
    raise newException(ValueError, "mp3: decoded frame is shorter than expected")
  decoder.bufferPosition = int(withinFrame)
