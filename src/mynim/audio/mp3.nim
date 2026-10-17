## MP3 decoder registration backed by a pure Nim port of go-mp3.
## Copyright 2017 Hajime Hoshi. Licensed under Apache-2.0.

import std/streams
import ../audio as audioApi
import ./mp3/internal/decoder as internalDecoder

const mp3FormatName* = "mp3"

type Mp3AudioDecoder = ref object of audioApi.Decoder
  decoder: internalDecoder.Mp3Decoder

method sampleRate(decoder: Mp3AudioDecoder): int =
  decoder.decoder.sampleRate()

method channels(decoder: Mp3AudioDecoder): int = 2

method length(decoder: Mp3AudioDecoder): int64 =
  decoder.decoder.length() div 4

method read(decoder: Mp3AudioDecoder; samples: var seq[float32]): int =
  let frameCount = samples.len div 2
  if frameCount == 0:
    return
  var bytes = newSeq[byte](frameCount * 4)
  let byteCount = decoder.decoder.readBytes(bytes)
  result = byteCount div 4 * 2
  for i in 0 ..< result:
    let raw = uint16(bytes[i * 2]) or (uint16(bytes[i * 2 + 1]) shl 8)
    samples[i] = float32(cast[int16](raw)) / 32768.0'f32

method setPosition(decoder: Mp3AudioDecoder; frame: int64) =
  if frame < 0 or frame > high(int64) div 4:
    raise newException(audioApi.AudioError, "MP3 seek out of range")
  try:
    decoder.decoder.setPosition(frame * 4)
  except ValueError as error:
    raise newException(audioApi.AudioError, error.msg)

proc openMp3(stream: Stream): audioApi.Decoder =
  try:
    Mp3AudioDecoder(decoder: internalDecoder.newMp3Decoder(stream))
  except CatchableError as error:
    raise newException(audioApi.AudioError, error.msg)

audioApi.registerFormat(mp3FormatName, "ID3", openMp3)
audioApi.registerFormat(mp3FormatName, "\xFF\xFB", openMp3)
audioApi.registerFormat(mp3FormatName, "\xFF\xFA", openMp3)
audioApi.registerFormat(mp3FormatName, "\xFF\xF3", openMp3)
audioApi.registerFormat(mp3FormatName, "\xFF\xF2", openMp3)
audioApi.registerFormat(mp3FormatName, "\xFF\xE3", openMp3)
audioApi.registerFormat(mp3FormatName, "\xFF\xE2", openMp3)
