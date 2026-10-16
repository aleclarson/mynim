## Audio decoding, in-memory sounds, and playback controls.
##
## WAV decoding is built in. Other codecs can register a decoder with
## `registerFormat`. Players mix and advance in real time. macOS uses CoreAudio;
## other platforms currently advance silently and report that through `err()`.

import std/[exitprocs, locks, math, monotimes, os, streams, times]
import ./internal/audio_output_types
when defined(macosx):
  import ./internal/darwin/audio_output as darwinAudioOutput

type
  AudioError* = object of CatchableError ## An unsupported or malformed audio format.

  AudioChannels* = range[1..2] ## The number of channels retained by an in-memory sound.

  Decoder* = ref object of RootObj ## A streaming decoder that produces interleaved float samples in `[-1, 1]`.

  DecoderOpener* = proc(stream: Stream): Decoder {.closure.} ## Opens a decoder on a seekable stream at its current position.

  AudioFormat = object
    name: string
    magic: string
    open: DecoderOpener

  Sound* = object ## In-memory audio samples for effects and repeated playback.
    samples: seq[float32]
    rate: int
    channelCount: int

  AudioSource = ref object of RootObj

  MemorySource = ref object of AudioSource
    samples: seq[float32]
    channelCount: int
    position: int
    looping: bool
    loopStart, loopEnd: int64

  StreamSource = ref object of AudioSource
    decoder: Decoder
    ownedStream: Stream
    sourceChannels, channelCount: int
    lock: Lock
    cond: Cond
    ring: seq[float32]
    readPosition, buffered: int
    looping: bool
    loopStart, loopEnd, decodedPosition: int64
    wrap, atEnd, closed: bool
    seekTo: int64
    generation: int
    worker: Thread[StreamSource]

  Voice = ref object
    source: AudioSource
    rate: float64
    mono: bool
    frameCount: int64
    playing, active, snap, fadeIn, closed: bool
    volume, pan, speed: float64
    looping: bool
    loopStart, loopEnd: int64
    history: array[4, array[2, float32]]
    index: int64
    phase: float64
    endFrame: int64
    input: seq[float32]
    inputPosition, inputLength: int
    gain, target, gainStep: array[4, float32]
    rampLeft: int

  Player* = ref object ## A sound player with independent position and controls.
    voice: Voice

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
  audioLock: Lock
  audioCond: Cond
  audioThread: Thread[void]
  audioThreadStarted = false
  audioClosing = false
  audioExitHookRegistered = false
  audioTestMode = false
  voices: seq[Voice]
  masterVolume = 1.0
  audioOutputError: ref CatchableError

initLock(formatsLock)
initLock(audioLock)
initCond(audioCond)

const
  outputSampleRate = 48_000
  outputChannels = 2
  rampFrames = outputSampleRate div 200
  nullFrames = outputSampleRate div 100

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

method close*(decoder: Decoder) {.base.} =
  ## Closes resources owned by this decoder, if any.
  discard

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

method readFrames(source: AudioSource; samples: var seq[float32]):
    tuple[frames: int, ended: bool] {.base, gcsafe.} =
  raiseAssert("mynim/audio: readFrames on the base source")

method seek(source: AudioSource; frame: int64) {.base, gcsafe.} =
  raiseAssert("mynim/audio: seek on the base source")

method setLoop(source: AudioSource; looping: bool; start, endFrame: int64)
    {.base, gcsafe.} =
  raiseAssert("mynim/audio: setLoop on the base source")

method close(source: AudioSource) {.base, gcsafe.} = discard

method readFrames(source: MemorySource; samples: var seq[float32]):
    tuple[frames: int, ended: bool] {.gcsafe.} =
  var written = 0
  while written < samples.len:
    var limit = source.samples.len
    if source.looping and source.loopEnd > 0:
      limit = min(limit, int(source.loopEnd) * source.channelCount)
    if source.position >= limit:
      if not source.looping or limit == 0:
        return (written div source.channelCount, true)
      source.position = int(source.loopStart) * source.channelCount
      if source.position >= limit:
        source.position = 0
    var count = min(samples.len - written, limit - source.position)
    count -= count mod source.channelCount
    if count <= 0:
      break
    for i in 0 ..< count:
      samples[written + i] = source.samples[source.position + i]
    written += count
    source.position += count
  (written div source.channelCount, false)

method seek(source: MemorySource; frame: int64) {.gcsafe.} =
  let sample = max(frame * int64(source.channelCount), 0)
  source.position = int(min(sample, int64(source.samples.len)))

method setLoop(source: MemorySource; looping: bool; start, endFrame: int64)
    {.gcsafe.} =
  source.looping = looping
  source.loopStart = start
  source.loopEnd = endFrame

proc decodeStream(source: StreamSource) {.thread.} =
  {.cast(gcsafe).}:
    const chunkFrames = 2048
    var input = newSeq[float32](chunkFrames * source.sourceChannels)
    var kept: seq[float32]
    if source.sourceChannels != source.channelCount:
      kept = newSeq[float32](chunkFrames * source.channelCount)

    acquire(source.lock)
    while true:
      while not source.closed and source.seekTo < 0 and not source.wrap and
          not (source.atEnd and source.looping) and
          (source.atEnd or source.ring.len - source.buffered <
            chunkFrames * source.channelCount):
        wait(source.cond, source.lock)
      if source.closed:
        release(source.lock)
        try:
          source.decoder.close()
        except CatchableError:
          discard
        if not source.ownedStream.isNil:
          try:
            source.ownedStream.close()
          except CatchableError:
            discard
        return

      if source.seekTo >= 0 or source.wrap or source.atEnd and source.looping:
        let destination = if source.seekTo >= 0:
          source.seekTo else: source.loopStart
        source.seekTo = -1
        source.wrap = false
        let generation = source.generation
        release(source.lock)
        var failed = false
        try:
          source.decoder.setPosition(destination)
        except CatchableError:
          failed = true
        acquire(source.lock)
        if generation == source.generation:
          source.atEnd = failed
          if failed:
            source.looping = false
          source.decodedPosition = destination
        continue

      let generation = source.generation
      release(source.lock)
      var count = 0
      var failed = false
      try:
        count = source.decoder.read(input)
      except CatchableError:
        failed = true
      acquire(source.lock)
      if generation != source.generation:
        continue
      if failed or count <= 0 or count > input.len or
          count mod source.sourceChannels != 0:
        source.atEnd = true
        if failed or count < 0 or count > input.len or
            count mod source.sourceChannels != 0:
          source.looping = false
        continue

      let frames = count div source.sourceChannels
      var sampleCount = count
      if source.looping and source.loopEnd > 0 and
          source.decodedPosition + int64(frames) >= source.loopEnd:
        sampleCount = int(max(source.loopEnd - source.decodedPosition, 0)) *
          source.sourceChannels
        source.wrap = true
      source.decodedPosition += int64(frames)

      let samples = if source.sourceChannels == source.channelCount:
        input else:
        block:
          var output = kept
          var at = 0
          for frame in 0 ..< sampleCount div source.sourceChannels:
            for channel in 0 ..< source.channelCount:
              output[at] = input[frame * source.sourceChannels + channel]
              inc at
          output
      let outputCount = if source.sourceChannels == source.channelCount:
        sampleCount else:
        sampleCount div source.sourceChannels * source.channelCount
      var copied = 0
      while copied < outputCount:
        let writeAt = (source.readPosition + source.buffered) mod source.ring.len
        let amount = min(outputCount - copied, source.ring.len - writeAt)
        for i in 0 ..< amount:
          source.ring[writeAt + i] = samples[copied + i]
        source.buffered += amount
        copied += amount

    release(source.lock)

method readFrames(source: StreamSource; samples: var seq[float32]):
    tuple[frames: int, ended: bool] {.gcsafe.} =
  acquire(source.lock)
  defer: release(source.lock)
  let channels = source.channelCount
  let requested = samples.len - samples.len mod channels
  let available = min(requested, source.buffered)
  var copied = 0
  while copied < available:
    let amount = min(available - copied, source.ring.len - source.readPosition)
    for i in 0 ..< amount:
      samples[copied + i] = source.ring[source.readPosition + i]
    source.readPosition = (source.readPosition + amount) mod source.ring.len
    source.buffered -= amount
    copied += amount
  if copied > 0:
    signal(source.cond)
  let ended = copied < requested and source.buffered == 0 and source.atEnd and
    not source.looping and source.seekTo < 0
  (copied div channels, ended)

method seek(source: StreamSource; frame: int64) {.gcsafe.} =
  withLock source.lock:
    source.seekTo = max(frame, 0)
    source.atEnd = false
    source.wrap = false
    source.readPosition = 0
    source.buffered = 0
    inc source.generation
    signal(source.cond)

method setLoop(source: StreamSource; looping: bool; start, endFrame: int64)
    {.gcsafe.} =
  withLock source.lock:
    if source.wrap and not looping:
      source.wrap = false
      source.seekTo = source.loopEnd
      source.atEnd = false
      inc source.generation
    source.looping = looping
    source.loopStart = start
    source.loopEnd = endFrame
    signal(source.cond)

method close(source: StreamSource) {.gcsafe.} =
  withLock source.lock:
    if not source.closed:
      source.closed = true
      signal(source.cond)

proc reset(voice: Voice; frame: int64) =
  voice.history = default(typeof(voice.history))
  voice.index = frame - 3
  voice.phase = 3
  voice.endFrame = -1
  voice.inputPosition = 0
  voice.inputLength = 0

proc close(voice: Voice) =
  if voice.closed:
    return
  voice.closed = true
  voice.playing = false
  voice.source.close()

proc ended(voice: Voice): bool =
  voice.endFrame >= 0 and voice.index >= voice.endFrame

proc position(voice: Voice): float64 =
  var value = max(float64(voice.index) + voice.phase, 0.0)
  if voice.frameCount == 0:
    return 0
  if voice.looping:
    var endFrame = float64(voice.loopEnd)
    if endFrame <= 0:
      endFrame = float64(voice.frameCount)
    let startFrame = float64(voice.loopStart)
    if endFrame > startFrame and value >= endFrame:
      let loopLength = endFrame - startFrame
      let elapsed = value - startFrame
      value = startFrame + elapsed - floor(elapsed / loopLength) * loopLength
    return value
  if voice.frameCount > 0:
    value = min(value, float64(voice.frameCount))
  value

proc shift(voice: Voice; left, right: float32) =
  voice.history[0] = voice.history[1]
  voice.history[1] = voice.history[2]
  voice.history[2] = voice.history[3]
  voice.history[3] = [left, right]
  inc voice.index

proc nextFrame(voice: Voice): bool =
  let sourceChannels = if voice.mono: 1 else: 2
  if voice.inputPosition >= voice.inputLength:
    if voice.endFrame >= 0:
      voice.shift(0, 0)
      return true
    if voice.input.len == 0:
      voice.input = newSeq[float32](256 * sourceChannels)
    let (frames, ended) = voice.source.readFrames(voice.input)
    voice.inputPosition = 0
    voice.inputLength = frames * sourceChannels
    if frames == 0:
      if not ended:
        return false
      voice.endFrame = voice.index + 3
      voice.shift(0, 0)
      return true
  let left = voice.input[voice.inputPosition]
  let right = if voice.mono: left else: voice.input[voice.inputPosition + 1]
  voice.inputPosition += sourceChannels
  voice.shift(left, right)
  true

proc gains(voice: Voice; master: float64): array[4, float32] =
  var gain = voice.volume * master
  if not voice.playing:
    gain = 0
  if voice.mono:
    let angle = (voice.pan + 1) / 2 * PI / 2
    return [float32(gain * sqrt(2.0) * cos(angle)), 0'f32, 0'f32,
      float32(gain * sqrt(2.0) * sin(angle))]
  if voice.pan <= 0:
    let angle = (voice.pan + 1) * PI / 2
    return [float32(gain), 0'f32, float32(gain * cos(angle)),
      float32(gain * sin(angle))]
  let angle = voice.pan * PI / 2
  [float32(gain * cos(angle)), float32(gain * sin(angle)), 0'f32,
    float32(gain)]

proc retarget(voice: Voice; target: array[4, float32]) =
  if voice.snap:
    voice.snap = false
    voice.fadeIn = false
    voice.gain = target
    voice.target = target
    voice.rampLeft = 0
    return
  if voice.fadeIn:
    voice.fadeIn = false
    voice.gain = default(typeof(voice.gain))
  elif target == voice.target:
    return
  voice.target = target
  for i in 0 ..< target.len:
    voice.gainStep[i] = (target[i] - voice.gain[i]) / float32(rampFrames)
  voice.rampLeft = rampFrames

proc interpolated(voice: Voice): array[2, float32] =
  let t = float32(voice.phase)
  template catmull(p0, p1, p2, p3: float32): float32 =
    p1 + 0.5'f32 * t * (p2 - p0 + t * (2'f32 * p0 - 5'f32 * p1 +
      4'f32 * p2 - p3 + t * (3'f32 * (p1 - p2) + p3 - p0)))
  [catmull(voice.history[0][0], voice.history[1][0],
      voice.history[2][0], voice.history[3][0]),
    catmull(voice.history[0][1], voice.history[1][1],
      voice.history[2][1], voice.history[3][1])]

proc mixVoice(voice: Voice; output: var seq[float32]; master: float64): bool =
  retarget(voice, gains(voice, master))
  let step = voice.rate / float64(outputSampleRate) * voice.speed
  var i = 0
  while i < output.len:
    while voice.phase >= 1:
      if not voice.nextFrame():
        return true
      voice.phase -= 1
    if voice.ended():
      voice.playing = false
      return false
    if voice.rampLeft > 0:
      for k in 0 ..< voice.gain.len:
        voice.gain[k] += voice.gainStep[k]
      dec voice.rampLeft
      if voice.rampLeft == 0:
        voice.gain = voice.target
    elif not voice.playing:
      return false
    let sample = voice.interpolated()
    output[i] += sample[0] * voice.gain[0] + sample[1] * voice.gain[2]
    output[i + 1] += sample[0] * voice.gain[1] + sample[1] * voice.gain[3]
    voice.phase += step
    i += outputChannels
  true

proc mix(output: var seq[float32]): bool =
  if output.len mod outputChannels != 0:
    raise newException(ValueError, "mynim/audio: output must contain stereo frames")
  for i in 0 ..< output.len:
    output[i] = 0
  acquire(audioLock)
  defer: release(audioLock)
  var write = 0
  for voice in voices:
    if voice.closed or not voice.mixVoice(output, masterVolume):
      voice.active = false
      if voice.closed:
        voice.source.close()
      continue
    voices[write] = voice
    inc write
  for i in write ..< voices.len:
    voices[i] = nil
  voices.setLen(write)
  for i in 0 ..< output.len:
    output[i] = min(max(output[i], -1'f32), 1'f32)
  write > 0

proc closeAudioOutput(device: AudioOutput) =
  try:
    device.close()
  except CatchableError as error:
    withLock audioLock:
      audioOutputError = error

proc runAudioOutput() {.thread.} =
  {.cast(gcsafe).}:
    var output = newSeq[float32](nullFrames * outputChannels)
    let nullInterval = initDuration(nanoseconds =
      int64(nullFrames) * 1_000_000_000 div outputSampleRate)
    let retryDelay = initDuration(nanoseconds = 2_000_000_000)
    let idleLimit = 5_000_000_000'i64
    while true:
      acquire(audioLock)
      while voices.len == 0 and not audioClosing:
        wait(audioCond, audioLock)
      let shuttingDown = audioClosing
      release(audioLock)
      if shuttingDown:
        return

      var device: AudioOutput
      var deviceFrames = nullFrames
      var canRetry = false
      var retryAt = getMonoTime() + retryDelay
      when defined(macosx):
        try:
          device = darwinAudioOutput.openAudioQueue()
          deviceFrames = darwinAudioOutput.aqBufferFrames
        except CatchableError as error:
          withLock audioLock:
            audioOutputError = error
          canRetry = true
      if device.isNil:
        withLock audioLock:
          if audioOutputError.isNil:
            audioOutputError = newException(AudioError,
              "audio: no audio output on this platform")
      else:
        withLock audioLock:
          audioOutputError = nil
        output.setLen(deviceFrames * outputChannels)

      var idleTime = 0'i64
      var deadline = getMonoTime()
      while true:
        acquire(audioLock)
        let shuttingDown = audioClosing
        release(audioLock)
        if shuttingDown:
          break

        if device.isNil and canRetry and getMonoTime() >= retryAt:
          when defined(macosx):
            try:
              device = darwinAudioOutput.openAudioQueue()
              deviceFrames = darwinAudioOutput.aqBufferFrames
              output.setLen(deviceFrames * outputChannels)
              deadline = getMonoTime()
              idleTime = 0
              canRetry = false
              withLock audioLock:
                audioOutputError = nil
            except CatchableError as error:
              retryAt = getMonoTime() + retryDelay
              withLock audioLock:
                audioOutputError = error

        let busy = mix(output)
        let interval = initDuration(nanoseconds =
          int64(output.len div outputChannels) * 1_000_000_000 div
          outputSampleRate)
        if device.isNil:
          deadline = deadline + nullInterval
          let delay = deadline - getMonoTime()
          if delay.inNanoseconds < -100_000_000:
            deadline = getMonoTime()
          elif delay.inNanoseconds > 0:
            sleep(max(1, int(delay.inMilliseconds)))
        else:
          try:
            device.write(output)
          except CatchableError as error:
            closeAudioOutput(device)
            device = nil
            deviceFrames = nullFrames
            output.setLen(nullFrames * outputChannels)
            deadline = getMonoTime()
            retryAt = getMonoTime() + retryDelay
            canRetry = true
            withLock audioLock:
              audioOutputError = error

        if busy:
          idleTime = 0
        else:
          idleTime += interval.inNanoseconds
          if idleTime >= idleLimit:
            break
      if not device.isNil:
        closeAudioOutput(device)

proc shutdownAudioOutput() =
  var started = false
  withLock audioLock:
    audioClosing = true
    started = audioThreadStarted
    signal(audioCond)
  if started:
    joinThread(audioThread)

proc wakeOutput() =
  if audioTestMode or audioClosing:
    return
  if not audioThreadStarted:
    if not audioExitHookRegistered:
      addExitProc(shutdownAudioOutput)
      audioExitHookRegistered = true
    audioThreadStarted = true
    createThread(audioThread, runAudioOutput)
  signal(audioCond)

proc makePlayer(sound: Sound): Player =
  if sound.rate <= 0 or sound.channelCount notin [1, 2]:
    raise newException(ValueError, "mynim/audio: invalid sound")
  let source = MemorySource(samples: sound.samples,
    channelCount: sound.channelCount)
  let voice = Voice(source: source, rate: float64(sound.rate),
    mono: sound.channelCount == 1,
    frameCount: int64(sound.samples.len div sound.channelCount),
    volume: 1, speed: 1)
  voice.reset(0)
  Player(voice: voice)

proc makeStreamPlayer(decoder: Decoder; ownedStream: Stream = nil): Player =
  if decoder.isNil:
    raise newException(ValueError, "mynim/audio: nil decoder")
  let sourceChannels = decoder.channels()
  let channelCount = min(sourceChannels, 2)
  let rate = decoder.sampleRate()
  if sourceChannels < 1 or rate <= 0:
    raise audioError("decoder has no channels or sample rate")
  let ringFrames = max(rate, 4096)
  if ringFrames > high(int) div channelCount:
    raise newException(ValueError, "mynim/audio: decoder buffer is too large")
  let source = StreamSource(decoder: decoder, ownedStream: ownedStream,
    sourceChannels: sourceChannels, channelCount: channelCount,
    ring: newSeq[float32](ringFrames * channelCount), seekTo: -1)
  initLock(source.lock)
  initCond(source.cond)
  let voice = Voice(source: source, rate: float64(rate),
    mono: channelCount == 1, frameCount: decoder.length(), volume: 1,
    speed: 1)
  voice.reset(0)
  createThread(source.worker, decodeStream, source)
  Player(voice: voice)

proc newPlayer*(sound: Sound): Player =
  ## Creates a paused player that shares this sound's immutable samples.
  makePlayer(sound)

proc newPlayer*(decoder: Decoder): Player =
  ## Creates a paused player that decodes ahead from a streaming decoder.
  ## Close the player when finished to close the decoder.
  makeStreamPlayer(decoder)

proc openStream*(stream: Stream): Player =
  ## Creates a paused player that decodes ahead from a seekable stream.
  ## The stream is closed when the player is closed.
  if stream.isNil:
    raise newException(ValueError, "mynim/audio: nil stream")
  let (decoder, _) = newDecoder(stream)
  makeStreamPlayer(decoder, stream)

proc play*(player: Player)

proc play*(sound: Sound): Player =
  ## Starts a new player of this sound and returns it.
  result = makePlayer(sound)
  result.play()

proc play*(player: Player) =
  ## Starts or resumes playback from the player's current position.
  acquire(audioLock)
  defer: release(audioLock)
  let voice = player.voice
  if voice.closed or voice.playing:
    return
  if voice.ended():
    voice.source.seek(0)
    voice.reset(0)
  voice.playing = true
  if not voice.active:
    voice.snap = voice.index + 3 <= 0
    voice.fadeIn = not voice.snap
    voice.active = true
    voices.add voice
    wakeOutput()

proc pause*(player: Player) =
  ## Pauses the player at its current position, fading out smoothly.
  withLock audioLock:
    player.voice.playing = false

proc stop*(player: Player) =
  ## Pauses the player and returns it to the start.
  withLock audioLock:
    let voice = player.voice
    if voice.closed:
      return
    voice.playing = false
    voice.source.seek(0)
    voice.reset(0)

proc playing*(player: Player): bool =
  ## Reports whether the player is currently playing.
  withLock audioLock:
    result = player.voice.playing

proc seek*(player: Player; time: Duration) =
  ## Moves the player to a time from its start.
  withLock audioLock:
    let voice = player.voice
    if voice.closed:
      return
    var frame = max(int64(round(float64(time.inNanoseconds) * voice.rate /
      1_000_000_000.0)), 0)
    if voice.frameCount >= 0:
      frame = min(frame, voice.frameCount)
    voice.source.seek(frame)
    voice.reset(frame)

proc position*(player: Player): Duration =
  ## Returns how far the player has progressed from its start.
  withLock audioLock:
    let voice = player.voice
    result = initDuration(nanoseconds = int64(voice.position() / voice.rate *
      1_000_000_000.0))

proc duration*(player: Player): Duration =
  ## Returns the player's duration, or zero when the source length is unknown.
  withLock audioLock:
    let voice = player.voice
    if voice.frameCount < 0:
      return initDuration(nanoseconds = 0)
    result = initDuration(nanoseconds = int64(float64(voice.frameCount) *
      1_000_000_000.0 / voice.rate))

proc setVolume*(player: Player; value: float64): Player =
  ## Sets the player's gain, with changes ramped to avoid clicks.
  withLock audioLock:
    player.voice.volume = max(value, 0.0)
  player

proc volume*(player: Player): float64 =
  ## Returns the player's gain.
  withLock audioLock:
    result = player.voice.volume

proc setPan*(player: Player; value: float64): Player =
  ## Places the sound between the left speaker (-1) and the right speaker (1).
  withLock audioLock:
    player.voice.pan = min(max(value, -1.0), 1.0)
  player

proc pan*(player: Player): float64 =
  ## Returns the player's pan.
  withLock audioLock:
    result = player.voice.pan

proc setSpeed*(player: Player; value: float64): Player =
  ## Sets playback speed and pitch; nonpositive and nonfinite values are ignored.
  if value > 0 and classify(value) notin {fcInf, fcNegInf, fcNan}:
    withLock audioLock:
      player.voice.speed = min(value, 16.0)
  player

proc speed*(player: Player): float64 =
  ## Returns the playback speed.
  withLock audioLock:
    result = player.voice.speed

proc setLoop*(player: Player; looping: bool): Player =
  ## Sets whether playback restarts at the end of the source.
  withLock audioLock:
    let voice = player.voice
    if not voice.closed:
      voice.looping = looping
      voice.source.setLoop(looping, voice.loopStart, voice.loopEnd)
  player

proc setLoopRange*(player: Player; startTime, endTime: Duration): Player =
  ## Loops a range; an end time of zero means the source's end.
  withLock audioLock:
    let voice = player.voice
    if voice.closed:
      return player
    var startFrame = max(int64(round(float64(startTime.inNanoseconds) *
      voice.rate / 1_000_000_000.0)), 0)
    var endFrame = max(int64(round(float64(endTime.inNanoseconds) *
      voice.rate / 1_000_000_000.0)), 0)
    if voice.frameCount >= 0:
      startFrame = min(startFrame, voice.frameCount)
      endFrame = min(endFrame, voice.frameCount)
    if endFrame != 0 and endFrame <= startFrame:
      startFrame = 0
      endFrame = 0
    voice.loopStart = startFrame
    voice.loopEnd = endFrame
    voice.looping = true
    voice.source.setLoop(true, startFrame, endFrame)
  player

proc loop*(player: Player): bool =
  ## Reports whether the player loops.
  withLock audioLock:
    result = player.voice.looping

proc close*(player: Player) =
  ## Stops the player and releases its audio source.
  withLock audioLock:
    let voice = player.voice
    voice.playing = false
    if not voice.closed:
      voice.close()

proc setVolume*(value: float64) =
  ## Sets the gain applied to all players.
  withLock audioLock:
    masterVolume = max(value, 0.0)

proc volume*(): float64 =
  ## Returns the gain applied to all players.
  withLock audioLock:
    result = masterVolume

proc err*(): ref CatchableError =
  ## Returns the most recent audio output error, or nil before output starts.
  withLock audioLock:
    result = audioOutputError

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
