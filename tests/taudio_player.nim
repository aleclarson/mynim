import std/[assertions, sequtils]

include "../src/mynim/audio.nim"

proc resetAudioTest() =
  withLock audioLock:
    audioTestMode = true
    for voice in voices:
      voice.active = false
      voice.playing = false
    voices.setLen(0)
    masterVolume = 1.0
    audioOutputError = nil

proc render(frames: int): seq[float32] =
  result = newSeq[float32](frames * outputChannels)
  discard mix(result)

proc ramp(count: int): seq[float32] =
  for i in 0 ..< count:
    result.add float32(i mod 100) / 200.0'f32

proc near(a, b: float32): bool = abs(a - b) < 0.0001'f32

proc frameTime(frame, rate: int): Duration =
  initDuration(nanoseconds = int64(frame) * 1_000_000_000 div rate)

block soundPlaybackMatchesSourceFrames:
  resetAudioTest()
  let samples = ramp(1000)
  let player = newSound(48_000, 1, samples).play()
  let output = render(1200)
  for i, sample in samples:
    doAssert near(output[i * 2], sample)
    doAssert near(output[i * 2 + 1], sample)
  for i in 1000 ..< 1200:
    doAssert output[i * 2] == 0
  doAssert not player.playing()
  doAssert player.position() == player.duration()
  doAssert voices.len == 0

block stereoOverlapAndClipping:
  resetAudioTest()
  let stereo = newSound(48_000, 2, @[0.1'f32, 0.2, 0.3, 0.4])
  discard stereo.play()
  let output = render(2)
  doAssert near(output[0], 0.1'f32)
  doAssert near(output[1], 0.2'f32)
  doAssert near(output[2], 0.3'f32)
  doAssert near(output[3], 0.4'f32)

  resetAudioTest()
  let loud = newSound(48_000, 1, @[0.8'f32, 0.8])
  discard loud.play()
  discard loud.play()
  doAssert render(1)[0] == 1'f32

block replayAfterEndAndSeek:
  resetAudioTest()
  let samples = ramp(100)
  let player = newSound(48_000, 1, samples).newPlayer()
  player.play()
  discard render(200)
  doAssert not player.playing()
  player.play()
  doAssert player.playing()
  doAssert near(render(100)[100], samples[50])

  player.seek(frameTime(15, 48_000))
  player.play()
  doAssert near(render(1)[0], samples[15])
  player.stop()
  doAssert player.position() == initDuration(nanoseconds = 0)
  doAssert not player.playing()

block loopsAndLoopRanges:
  resetAudioTest()
  let samples = ramp(100)
  let looping = newSound(48_000, 1, samples).newPlayer().setLoop(true)
  looping.play()
  let output = render(350)
  for i in 0 ..< 350:
    doAssert near(output[2 * i], samples[i mod samples.len])
  doAssert looping.playing()
  doAssert looping.position() == frameTime(50, 48_000)

  resetAudioTest()
  let ranged = newSound(48_000, 1, samples).newPlayer().setLoopRange(
    frameTime(30, 48_000), frameTime(60, 48_000))
  ranged.play()
  let introOutput = render(200)
  for i in 0 ..< 200:
    let frame = if i < 60: i else: 30 + (i - 60) mod 30
    doAssert near(introOutput[2 * i], samples[frame])
  doAssert ranged.position() == frameTime(50, 48_000)
  discard ranged.setLoop(false)
  let ending = render(1000)
  var last = -1
  for i in 0 ..< 1000:
    if ending[2 * i] != 0:
      last = i
  doAssert last >= 0 and near(ending[2 * last], samples[99])
  doAssert not ranged.playing()
  doAssert near(ending[2 * (last - 39)], samples[60])

block gainPanSpeedAndClose:
  resetAudioTest()
  let constant = newSound(48_000, 1, newSeqWith(10_000, 0.5'f32))
  let player = constant.newPlayer().setPan(-1).setVolume(0.5)
  player.play()
  let left = render(1)
  doAssert left[0] > 0.35'f32 and left[1] == 0
  discard player.setPan(1).setVolume(1)
  let right = render(300)
  doAssert right[2 * (rampFrames + 5)] < 0.05'f32
  doAssert near(right[2 * (rampFrames + 5) + 1], 0.5'f32 * sqrt(2.0'f32))

  resetAudioTest()
  var increasing = newSeq[float32](1000)
  for i in 0 ..< increasing.len:
    increasing[i] = float32(i) / 1000'f32
  let fast = newSound(48_000, 1, increasing).newPlayer().setSpeed(2)
  fast.play()
  let fastOutput = render(60)
  doAssert near(fastOutput[100], increasing[100])
  let oldSpeed = fast.speed()
  discard fast.setSpeed(0).setSpeed(Inf)
  doAssert fast.speed() == oldSpeed
  fast.close()
  doAssert not fast.playing()

block pauseFadesAndFreezes:
  resetAudioTest()
  let player = newSound(48_000, 1,
    newSeqWith(10_000, 0.5'f32)).play()
  discard render(1000)
  player.pause()
  doAssert not player.playing()
  let fadeOut = render(rampFrames + 10)
  doAssert fadeOut[0] > 0.45'f32
  doAssert fadeOut[2 * (rampFrames div 2)] < 0.3'f32
  doAssert fadeOut[2 * (rampFrames div 2)] > 0.2'f32
  doAssert fadeOut[2 * (rampFrames + 5)] == 0
  let position = player.position()
  discard render(500)
  doAssert player.position() == position
  player.play()
  let fadeIn = render(rampFrames + 10)
  doAssert fadeIn[0] < 0.05'f32
  doAssert near(fadeIn[2 * (rampFrames + 5)], 0.5'f32)

block masterVolumeAndValidation:
  resetAudioTest()
  setVolume(0)
  doAssert volume() == 0
  let player = newSound(48_000, 1, @[0.5'f32, 0.5]).newPlayer()
  doAssert player.volume() == 1
  doAssert player.pan() == 0
  doAssert player.speed() == 1
  player.play()
  doAssert render(1)[0] == 0
  player.close()
  setVolume(1)
