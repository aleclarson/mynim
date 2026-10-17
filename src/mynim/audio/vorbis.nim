## Ogg Vorbis decoder registration. Import this module to enable the format.
## Copyright (c) 2016 Johann Freymuth. Licensed under the MIT License.

import std/streams
import ../audio as audioApi
import ./vorbis/internal/reader as internalReader

const vorbisFormatName* = "vorbis"

type VorbisAudioDecoder = ref object of audioApi.Decoder
  reader: internalReader.VorbisReader

method sampleRate(decoder: VorbisAudioDecoder): int =
  decoder.reader.sampleRate()

method channels(decoder: VorbisAudioDecoder): int =
  decoder.reader.channels()

method length(decoder: VorbisAudioDecoder): int64 =
  let sampleCount = decoder.reader.length()
  if sampleCount > 0: sampleCount else: -1

method read(decoder: VorbisAudioDecoder; samples: var seq[float32]): int =
  try:
    decoder.reader.read(samples)
  except CatchableError as error:
    raise newException(audioApi.AudioError, error.msg)

method setPosition(decoder: VorbisAudioDecoder; frame: int64) =
  try:
    decoder.reader.setPosition(frame)
  except CatchableError as error:
    raise newException(audioApi.AudioError, error.msg)

proc openVorbis(stream: Stream): audioApi.Decoder =
  try:
    VorbisAudioDecoder(reader: internalReader.newVorbisReader(stream))
  except CatchableError as error:
    raise newException(audioApi.AudioError, error.msg)

audioApi.registerFormat(vorbisFormatName, "OggS", openVorbis)
