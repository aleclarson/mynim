import std/[assertions, atomics]

include "../src/mynim/audio.nim"

type TestDecoder = ref object of Decoder
  channelCount: int
  position, frameCount: int64
  gate, closed: Atomic[bool]
  waitAtStart: bool

method sampleRate(decoder: TestDecoder): int = outputSampleRate
method channels(decoder: TestDecoder): int = decoder.channelCount
method length(decoder: TestDecoder): int64 = decoder.frameCount
method setPosition(decoder: TestDecoder; frame: int64) =
  decoder.position = if decoder.frameCount < 0: max(frame, 0) else:
    min(max(frame, 0), decoder.frameCount)

method read(decoder: TestDecoder; samples: var seq[float32]): int =
  if decoder.waitAtStart:
    while not decoder.gate.load(moAcquire):
      sleep(1)
    decoder.waitAtStart = false
  let available = if decoder.frameCount < 0:
    samples.len div decoder.channelCount
  else:
    int(decoder.frameCount - decoder.position)
  let frames = min(samples.len div decoder.channelCount, available)
  if frames <= 0:
    return 0
  for frame in 0 ..< frames:
    let value = float32((decoder.position + int64(frame)) mod 1000) / 1000'f32
    for channel in 0 ..< decoder.channelCount:
      samples[frame * decoder.channelCount + channel] = value +
        float32(channel) * 0.25'f32
  decoder.position += int64(frames)
  frames * decoder.channelCount

method close(decoder: TestDecoder) =
  decoder.closed.store(true, moRelease)

proc waitBuffered(source: StreamSource; frames: int) =
  for attempt in 0 ..< 2000:
    acquire(source.lock)
    let ready = source.buffered div source.channelCount >= frames
    let ended = source.atEnd and source.buffered == 0
    release(source.lock)
    if ready:
      return
    doAssert not ended, "decoder reached the end before filling the ring"
    sleep(1)
  doAssert false, "stream decoder did not fill the ring"

proc waitClosed(decoder: TestDecoder) =
  for attempt in 0 ..< 2000:
    if decoder.closed.load(moAcquire):
      return
    sleep(1)
  doAssert false, "stream decoder did not close"

proc waitAtEnd(source: StreamSource) =
  for attempt in 0 ..< 2000:
    acquire(source.lock)
    let ended = source.atEnd
    release(source.lock)
    if ended:
      return
    sleep(1)
  doAssert false, "stream decoder did not reach the end"

proc frameTime(frame: int): Duration =
  initDuration(nanoseconds = int64(frame) * 1_000_000_000 div outputSampleRate)

proc addText(bytes: var seq[byte]; value: string) =
  for c in value:
    bytes.add byte(ord(c))

proc addU16(bytes: var seq[byte]; value: uint16) =
  bytes.add byte(value and 0xff'u16)
  bytes.add byte(value shr 8)

proc addU32(bytes: var seq[byte]; value: uint32) =
  bytes.add byte(value and 0xff'u32)
  bytes.add byte((value shr 8) and 0xff'u32)
  bytes.add byte((value shr 16) and 0xff'u32)
  bytes.add byte(value shr 24)

proc bytesString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  if bytes.len > 0:
    copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)

proc tinyWav(): string =
  var bytes: seq[byte]
  bytes.addText("RIFF")
  bytes.addU32(40)
  bytes.addText("WAVEfmt ")
  bytes.addU32(16)
  bytes.addU16(1)
  bytes.addU16(1)
  bytes.addU32(outputSampleRate)
  bytes.addU32(outputSampleRate)
  bytes.addU16(1)
  bytes.addU16(8)
  bytes.addText("data")
  bytes.addU32(4)
  bytes.add @[128'u8, 192, 64, 255]
  bytesString(bytes)

proc resetAudioTest() =
  withLock audioLock:
    audioTestMode = true
    for voice in voices:
      voice.active = false
      voice.playing = false
      voice.close()
    voices.setLen(0)
    masterVolume = 1
    audioOutputError = nil

proc render(frames: int): seq[float32] =
  result = newSeq[float32](frames * outputChannels)
  discard mix(result)

block streamKeepsFirstTwoChannelsAndClosesDecoder:
  resetAudioTest()
  let decoder = TestDecoder(channelCount: 3, frameCount: 5000)
  let player = newPlayer(decoder)
  let source = StreamSource(player.voice.source)
  waitBuffered(source, 1000)
  player.play()
  let output = render(1000)
  for frame in 0 ..< 1000:
    let value = float32(frame) / 1000'f32
    doAssert abs(output[frame * 2] - value) < 0.0001'f32
    doAssert abs(output[frame * 2 + 1] - min(value + 0.25'f32, 1'f32)) <
      0.0001'f32
  doAssert player.position() == frameTime(1000)
  player.close()
  waitClosed(decoder)

block openStreamUsesRegisteredDecoder:
  resetAudioTest()
  let stream = newStringStream(tinyWav())
  let player = openStream(stream)
  waitBuffered(StreamSource(player.voice.source), 4)
  player.play()
  let output = render(4)
  doAssert abs(output[0] - 0'f32) < 0.0001'f32
  doAssert abs(output[2] - 0.5'f32) < 0.0001'f32
  doAssert abs(output[4] + 0.5'f32) < 0.0001'f32
  doAssert abs(output[6] - 127'f32 / 128'f32) < 0.0001'f32
  player.close()

block unknownLengthStreamKeepsPlaying:
  resetAudioTest()
  let decoder = TestDecoder(channelCount: 1, frameCount: -1)
  let player = newPlayer(decoder)
  waitBuffered(StreamSource(player.voice.source), 1000)
  doAssert player.duration() == initDuration(nanoseconds = 0)
  player.play()
  let output = render(500)
  for frame in 0 ..< 500:
    let expected = float32(frame mod 1000) / 1000'f32
    doAssert abs(output[frame * 2] - expected) < 0.0001'f32
  doAssert player.playing()
  player.close()
  waitClosed(decoder)

block streamLoopRangeAndSeek:
  resetAudioTest()
  let rangedDecoder = TestDecoder(channelCount: 1, frameCount: 5000,
    waitAtStart: true)
  let ranged = newPlayer(rangedDecoder).setLoopRange(frameTime(1000),
    frameTime(3000))
  rangedDecoder.gate.store(true, moRelease)
  let rangedSource = StreamSource(ranged.voice.source)
  waitBuffered(rangedSource, 9000)
  ranged.play()
  let output = render(9000)
  for frame in 0 ..< 9000:
    let sourceFrame = if frame < 3000: frame else: 1000 + (frame - 3000) mod 2000
    let value = float32(sourceFrame mod 1000) / 1000'f32
    doAssert abs(output[frame * 2] - value) < 0.0001'f32
  doAssert ranged.position() == frameTime(1000)
  ranged.close()
  waitClosed(rangedDecoder)

  resetAudioTest()
  let seekDecoder = TestDecoder(channelCount: 1, frameCount: 48000)
  let seekPlayer = newPlayer(seekDecoder)
  let seekSource = StreamSource(seekPlayer.voice.source)
  waitBuffered(seekSource, 2000)
  seekPlayer.seek(frameTime(700))
  waitBuffered(seekSource, 2000)
  seekPlayer.play()
  let seekOutput = render(rampFrames + 20)
  let checkFrame = rampFrames + 10
  let expected = float32((700 + checkFrame) mod 1000) / 1000'f32
  doAssert abs(seekOutput[checkFrame * 2] - expected) < 0.0001'f32
  seekPlayer.close()
  waitClosed(seekDecoder)

block droppedPausedPlayerClosesDecoder:
  resetAudioTest()
  let decoder = TestDecoder(channelCount: 1, frameCount: -1)
  var player = newPlayer(decoder)
  let source = StreamSource(player.voice.source)
  waitBuffered(source, 1000)
  player = nil
  waitClosed(decoder)
  doAssert source.closed

block droppedPlayingPlayerRunsToEndThenClosesDecoder:
  resetAudioTest()
  let decoder = TestDecoder(channelCount: 1, frameCount: 64)
  var player = newPlayer(decoder)
  let voice = player.voice
  let source = StreamSource(voice.source)
  waitBuffered(source, 64)
  waitAtEnd(source)
  player.play()
  player = nil
  doAssert voice.orphan
  doAssert not decoder.closed.load(moAcquire)

  var output = newSeq[float32](128 * outputChannels)
  doAssert not mix(output)
  doAssert not voice.active
  doAssert voice.closed
  waitClosed(decoder)
