## Audio format decoding and in-memory sounds.
##
## WAV decoding is built in. Other codecs can register a decoder with
## `registerFormat`; the player and system output are separate parts of the
## audio package and are not implemented yet.

import std/[locks, streams, times]

type
  AudioError* = object of CatchableError ## An unsupported or malformed audio format.

  AudioChannels* = range[1..2] ## The number of channels retained by an in-memory sound.

  Decoder* = ref object of RootObj ## A streaming decoder that produces interleaved float samples in `[-1, 1]`.

  DecoderOpener* = proc(stream: Stream): Decoder {.closure.} ## Opens a decoder on a seekable stream at its current position.

  AudioFormat = object
    name: string
    magic: string
    open: DecoderOpener

  Sound* = object ## Audio decoded into memory for effects and repeated playback.
    samples: seq[float32]
    rate: int
    channelCount: int

  WavDecoder = ref object of Decoder
    stream: Stream
    rate: int
    channelCount: int
    bits: int
    isFloat: bool
    dataStart: int
    frameCount: int64
    framePosition: int64

var
  formatsLock: Lock
  formats: seq[AudioFormat]

initLock(formatsLock)

proc audioError(message: string): ref AudioError =
  newException(AudioError, "audio: " & message)

method sampleRate*(decoder: Decoder): int {.base.} =
  ## Returns the frames per second of the decoded audio.
  raiseAssert("mynim/audio: sampleRate on the base Decoder")

method channels*(decoder: Decoder): int {.base.} =
  ## Returns the number of interleaved samples per frame.
  raiseAssert("mynim/audio: channels on the base Decoder")

method read*(decoder: Decoder; samples: var seq[float32]): int {.base.} =
  ## Decodes whole frames into `samples`; returns zero at end of stream.
  raiseAssert("mynim/audio: read on the base Decoder")

method setPosition*(decoder: Decoder; frame: int64) {.base.} =
  ## Seeks to a source frame counted from the start.
  raiseAssert("mynim/audio: setPosition on the base Decoder")

method length*(decoder: Decoder): int64 {.base.} =
  ## Returns the frame count, or -1 when the length is unknown.
  raiseAssert("mynim/audio: length on the base Decoder")

proc registerFormat*(name, magic: string; open: DecoderOpener) =
  ## Registers a streaming decoder. In `magic`, `?` matches any byte.
  ## The opener receives the stream restored to its position before probing.
  if name.len == 0 or magic.len == 0 or open.isNil:
    raise newException(ValueError, "mynim/audio: invalid format registration")
  acquire(formatsLock)
  try:
    formats.add AudioFormat(name: name, magic: magic, open: open)
  finally:
    release(formatsLock)

proc matches(magic: string; bytes: openArray[byte]): bool =
  if magic.len > bytes.len:
    return false
  for i, c in magic:
    if c != '?' and ord(c) != int(bytes[i]):
      return false
  true

proc newDecoder*(stream: Stream): tuple[decoder: Decoder, format: string] =
  ## Opens the registered decoder whose magic matches the stream at its
  ## current position. The stream must support seeking.
  if stream.isNil:
    raise newException(ValueError, "mynim/audio: nil stream")
  let start = stream.getPosition()
  if start < 0:
    raise audioError("stream is not seekable")
  var head = newSeq[byte](16)
  var count = 0
  while count < head.len:
    let n = stream.readData(addr head[count], head.len - count)
    if n <= 0:
      break
    count += n
  stream.setPosition(start)
  head.setLen(count)

  var registered: seq[AudioFormat]
  acquire(formatsLock)
  try:
    for format in formats:
      registered.add format
  finally:
    release(formatsLock)

  for format in registered:
    if matches(format.magic, head):
      result.decoder = format.open(stream)
      if result.decoder.isNil:
        raise audioError("format opener returned no decoder: " & format.name)
      result.format = format.name
      return
  raise audioError("unknown format")

proc sampleRate*(sound: Sound): int =
  ## Returns the sound's source frames per second.
  sound.rate

proc channels*(sound: Sound): int =
  ## Returns the one or two channels retained in this sound.
  sound.channelCount

proc samples*(sound: Sound): lent seq[float32] =
  ## Borrows the interleaved samples without allowing mutation.
  sound.samples

proc duration*(sound: Sound): Duration =
  ## Returns the playback time represented by the sound's complete frames.
  if sound.rate <= 0 or sound.channelCount <= 0:
    return initDuration(nanoseconds = 0)
  let frames = sound.samples.len div sound.channelCount
  initDuration(nanoseconds = int64(float64(frames) * 1_000_000_000.0 /
    float64(sound.rate)))

proc newSound*(sampleRate: Positive; channels: AudioChannels;
               samples: sink seq[float32]): Sound =
  ## Stores interleaved mono or stereo samples, discarding an incomplete final frame.
  result = Sound(rate: int(sampleRate), channelCount: int(channels),
    samples: samples)
  result.samples.setLen(result.samples.len div int(channels) * int(channels))

proc readSound*(decoder: Decoder): Sound =
  ## Decodes the remaining stream into memory, retaining the first two channels.
  if decoder.isNil:
    raise newException(ValueError, "mynim/audio: nil decoder")
  let sourceChannels = decoder.channels()
  let rate = decoder.sampleRate()
  if sourceChannels < 1 or rate <= 0:
    raise audioError("decoder has no channels or sample rate")
  let keptChannels = AudioChannels(min(sourceChannels, 2))
  var output: seq[float32]
  let frames = decoder.length()
  if frames > 0 and frames <= int64(high(int) div int(keptChannels)):
    output = newSeqOfCap[float32](int(frames) * int(keptChannels))

  let bufferFrames = max(1, 4096 div sourceChannels)
  var buffer = newSeq[float32](bufferFrames * sourceChannels)
  while true:
    let count = decoder.read(buffer)
    if count == 0:
      break
    if count < 0 or count > buffer.len or count mod sourceChannels != 0:
      raise audioError("decoder returned an invalid sample count")
    var i = 0
    while i < count:
      for channel in 0 ..< int(keptChannels):
        output.add buffer[i + channel]
      i += sourceChannels

  result = newSound(Positive(rate), keptChannels, move(output))

proc decodeSound*(data: openArray[byte]): Sound =
  ## Detects and decodes an in-memory audio file.
  var bytes = newString(data.len)
  if data.len > 0:
    copyMem(addr bytes[0], unsafeAddr data[0], data.len)
  let stream = newStringStream(bytes)
  try:
    let (decoder, _) = newDecoder(stream)
    result = readSound(decoder)
  finally:
    stream.close()

proc readAvailable(stream: Stream; count: int): seq[byte] =
  result = newSeq[byte](count)
  var offset = 0
  while offset < count:
    let read = stream.readData(addr result[offset], count - offset)
    if read <= 0:
      break
    offset += read
  result.setLen(offset)

proc readBytes(stream: Stream; count: int): seq[byte] =
  result = readAvailable(stream, count)
  if result.len != count:
    raise audioError("invalid WAV")

proc readU16(bytes: openArray[byte]; offset: int): uint16 =
  uint16(bytes[offset]) or (uint16(bytes[offset + 1]) shl 8)

proc readU32(bytes: openArray[byte]; offset: int): uint32 =
  uint32(bytes[offset]) or (uint32(bytes[offset + 1]) shl 8) or
    (uint32(bytes[offset + 2]) shl 16) or (uint32(bytes[offset + 3]) shl 24)

proc fourCC(bytes: openArray[byte]; offset: int; text: string): bool =
  if offset < 0 or offset + 4 > bytes.len:
    return false
  for i in 0 ..< 4:
    if bytes[offset + i] != byte(ord(text[i])):
      return false
  true

proc wavFrameBytes(decoder: WavDecoder): int =
  decoder.channelCount * (decoder.bits div 8)

proc openWav(stream: Stream): Decoder =
  let start = stream.getPosition()
  if start < 0 or start > high(int) - 12:
    raise audioError("invalid WAV")
  let riff = readBytes(stream, 12)
  if not fourCC(riff, 0, "RIFF") or not fourCC(riff, 8, "WAVE"):
    raise audioError("invalid WAV")
  var decoder = WavDecoder(stream: stream, frameCount: -1)
  var offset = start + 12
  var haveFormat = false
  while true:
    let header = readBytes(stream, 8)
    let chunkSize = int64(readU32(header, 4))
    offset += 8
    if fourCC(header, 0, "fmt "):
      if chunkSize < 16 or chunkSize > 1 shl 16:
        raise audioError("invalid WAV")
      let format = readBytes(stream, int(chunkSize))
      var tag = readU16(format, 0)
      decoder.channelCount = int(readU16(format, 2))
      decoder.rate = int(readU32(format, 4))
      decoder.bits = int(readU16(format, 14))
      if tag == 0xfffe'u16 and chunkSize >= 40:
        tag = readU16(format, 24)
      if tag == 1'u16 and decoder.bits >= 8 and decoder.bits <= 32 and
          decoder.bits mod 8 == 0:
        discard
      elif tag == 3'u16 and decoder.bits in [32, 64]:
        decoder.isFloat = true
      else:
        raise audioError("WAV encoding is not PCM or float")
      if decoder.channelCount < 1 or decoder.rate < 1:
        raise audioError("invalid WAV")
      haveFormat = true
    elif fourCC(header, 0, "data"):
      if not haveFormat:
        raise audioError("invalid WAV")
      decoder.dataStart = offset
      if chunkSize != 0 and chunkSize != 0xffff_ffff'i64:
        decoder.frameCount = chunkSize div int64(decoder.wavFrameBytes())
      return decoder

    let paddedSize = chunkSize + (chunkSize and 1)
    if paddedSize > int64(high(int)) - int64(offset):
      raise audioError("invalid WAV")
    offset += int(paddedSize)
    stream.setPosition(offset)

method sampleRate*(decoder: WavDecoder): int = decoder.rate
method channels*(decoder: WavDecoder): int = decoder.channelCount
method length*(decoder: WavDecoder): int64 = decoder.frameCount

method read*(decoder: WavDecoder; samples: var seq[float32]): int =
  let frameBytes = decoder.wavFrameBytes()
  var frames = samples.len div decoder.channelCount
  let remaining = if decoder.frameCount >= 0:
    decoder.frameCount - decoder.framePosition else: -1
  if decoder.frameCount >= 0:
    frames = min(frames, int(remaining))
  if frames <= 0:
    return 0

  let bytes = readAvailable(decoder.stream, frames * frameBytes)
  if bytes.len mod frameBytes != 0:
    raise audioError("truncated WAV frame")
  let decodedFrames = bytes.len div frameBytes
  if decodedFrames == 0:
    if remaining > 0:
      raise audioError("truncated WAV data")
    return 0
  let bytesPerSample = decoder.bits div 8
  result = decodedFrames * decoder.channelCount
  for i in 0 ..< result:
    let offset = i * bytesPerSample
    var value: float32
    case decoder.bits
    of 8:
      value = (float32(bytes[offset]) - 128.0) / 128.0
    of 16:
      value = float32(cast[int16](readU16(bytes, offset))) / 32768.0
    of 24:
      var raw = uint32(bytes[offset]) or (uint32(bytes[offset + 1]) shl 8) or
        (uint32(bytes[offset + 2]) shl 16)
      if (raw and 0x800000'u32) != 0:
        raw = raw or 0xff000000'u32
      value = float32(cast[int32](raw)) / 8388608.0
    of 32:
      let raw = readU32(bytes, offset)
      if decoder.isFloat:
        value = cast[float32](raw)
      else:
        value = float32(cast[int32](raw)) / 2147483648.0
    of 64:
      var raw = uint64(readU32(bytes, offset)) or
        (uint64(readU32(bytes, offset + 4)) shl 32)
      value = float32(cast[float64](raw))
    else:
      raise audioError("unsupported WAV sample width")
    samples[i] = value
  decoder.framePosition += int64(decodedFrames)

method setPosition*(decoder: WavDecoder; frame: int64) =
  if frame < 0 or decoder.frameCount >= 0 and frame > decoder.frameCount:
    raise audioError("WAV seek out of range")
  let position = int64(decoder.dataStart) + frame * int64(decoder.wavFrameBytes())
  if position > int64(high(int)):
    raise audioError("WAV seek out of range")
  decoder.stream.setPosition(int(position))
  decoder.framePosition = frame

registerFormat("wav", "RIFF????WAVE", openWav)
