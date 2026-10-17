## Ogg Vorbis packet streaming, ported from github.com/jfreymuth/oggvorbis.
## Copyright (c) 2016 Johann Freymuth. Licensed under the MIT License.

import std/streams
import ./[codec, ogg]

type VorbisReader* = ref object
  pageReader: OggPageReader
  decoder: VorbisDecoder
  position, length: int64
  buffer, originalBuffer: seq[float32]
  toSkip: int

proc readPacket(reader: VorbisReader; output: var seq[float32]): int =
  let packet = reader.pageReader.nextPacket()
  result = reader.decoder.decodeInto(packet, output)
  reader.position += int64(result div reader.decoder.channels())
  if reader.pageReader.isLastPacket():
    let granulePosition = reader.pageReader.currentGranulePosition()
    let discardFrames = reader.position - granulePosition
    if discardFrames > 0:
      result -= int(discardFrames) * reader.decoder.channels()
    reader.position = granulePosition
    reader.length = granulePosition

proc fillBuffer(reader: VorbisReader) =
  while true:
    reader.originalBuffer.setLen(reader.decoder.bufferSize())
    let count = reader.readPacket(reader.originalBuffer)
    reader.buffer.setLen(count)
    for i in 0 ..< count:
      reader.buffer[i] = reader.originalBuffer[i]
    if count > 0 or reader.pageReader.isLastPacket():
      return

proc skip(reader: VorbisReader) =
  while reader.toSkip > 0:
    reader.fillBuffer()
    if reader.buffer.len > reader.toSkip:
      reader.buffer = reader.buffer[reader.toSkip .. ^1]
      reader.toSkip = 0
      return
    reader.toSkip -= reader.buffer.len
    reader.buffer.setLen(0)
    if reader.pageReader.isLastPacket():
      return

proc newVorbisReader*(stream: Stream): VorbisReader =
  result = VorbisReader(
    pageReader: newOggPageReader(stream),
    decoder: newVorbisDecoder(),
    length: -1)
  result.length = result.pageReader.length()
  result.pageReader.seek(0)
  for _ in 0 ..< 3:
    result.decoder.readHeader(result.pageReader.nextPacket())
  result.originalBuffer = newSeq[float32](result.decoder.bufferSize())
  result.fillBuffer()
  if result.pageReader.atPageEnd():
    let offset = result.pageReader.currentGranulePosition() - result.position
    if offset < 0:
      let skipSamples = min(int(-offset) * result.decoder.channels(),
        result.buffer.len)
      result.buffer = result.buffer[skipSamples .. ^1]
    result.position = result.pageReader.currentGranulePosition()

proc sampleRate*(reader: VorbisReader): int = reader.decoder.sampleRate()

proc channels*(reader: VorbisReader): int = reader.decoder.channels()

proc length*(reader: VorbisReader): int64 = reader.length

proc read*(reader: VorbisReader; output: var seq[float32]): int =
  let channels = reader.decoder.channels()
  let outputSize = output.len - output.len mod channels
  if outputSize == 0 or reader.pageReader.isLastPacket() and
      reader.buffer.len == 0:
    return
  if reader.toSkip > 0:
    reader.skip()
  if reader.buffer.len > 0:
    result = min(outputSize, reader.buffer.len)
    for i in 0 ..< result:
      output[i] = reader.buffer[i]
    reader.buffer = reader.buffer[result .. ^1]
  while outputSize - result >= reader.originalBuffer.len and
      reader.originalBuffer.len > 0:
    let count = reader.readPacket(reader.originalBuffer)
    for i in 0 ..< count:
      output[result + i] = reader.originalBuffer[i]
    result += count
    if count == 0 or reader.pageReader.isLastPacket():
      return
  if result == 0:
    reader.fillBuffer()
    result = min(outputSize, reader.buffer.len)
    for i in 0 ..< result:
      output[i] = reader.buffer[i]
    reader.buffer = reader.buffer[result .. ^1]

proc setPosition*(reader: VorbisReader; position: int64) =
  if position < 0:
    raise newException(ValueError, "vorbis: seek position is negative")
  if reader.length >= 0 and position >= reader.length:
    reader.buffer.setLen(0)
    reader.pageReader.markEnd()
    reader.position = reader.length
    reader.toSkip = 0
    return
  reader.buffer.setLen(0)
  let start = reader.pageReader.seekPageBefore(position)
  let packet = reader.pageReader.nextPacket()
  reader.decoder.clear()
  discard reader.decoder.decodeInto(packet, reader.originalBuffer)
  reader.position = start
  reader.toSkip = int(position - start) * reader.decoder.channels()
