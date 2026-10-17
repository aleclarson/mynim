import std/[os, streams, times]
import mynim/audio
import mynim/audio/vorbis as vorbis

let dataDir = currentSourcePath().parentDir / "data"
# The Ogg stream and reference PCM come from oggvorbis v1.0.5's MIT testdata.
# The stereo tone is audio/vorbis/testdata/tone.ogg from pinned Mygo.
let oggStream = newFileStream(dataDir / "vorbis_test.ogg", fmRead)
doAssert not oggStream.isNil
let opened = newDecoder(oggStream)
doAssert opened.format == vorbis.vorbisFormatName
doAssert opened.decoder.sampleRate() == 44_100
doAssert opened.decoder.channels() == 1
doAssert opened.decoder.length() == 44_100

let raw = readFile(dataDir / "vorbis_test.raw")
doAssert raw.len mod 4 == 0
var expected = newSeq[float32](raw.len div 4)
for i in 0 ..< expected.len:
  let offset = i * 4
  let bits = uint32(ord(raw[offset])) or
    (uint32(ord(raw[offset + 1])) shl 8) or
    (uint32(ord(raw[offset + 2])) shl 16) or
    (uint32(ord(raw[offset + 3])) shl 24)
  expected[i] = cast[float32](bits)

var actual = newSeqOfCap[float32](expected.len)
var buffer = newSeq[float32](2_048)
while true:
  let count = opened.decoder.read(buffer)
  if count == 0:
    break
  actual.add buffer.toOpenArray(0, count - 1)
doAssert actual.len == expected.len
for i in 0 ..< actual.len:
  doAssert abs(actual[i] - expected[i]) <= 0.00002'f32,
    "sample " & $i & " differs: " & $actual[i] & " vs " & $expected[i]

opened.decoder.setPosition(22_050)
var seekBuffer = newSeq[float32](256)
doAssert opened.decoder.read(seekBuffer) == seekBuffer.len
for i in 0 ..< seekBuffer.len:
  doAssert abs(seekBuffer[i] - expected[22_050 + i]) <= 0.00002'f32
opened.decoder.setPosition(opened.decoder.length())
doAssert opened.decoder.read(seekBuffer) == 0

let toneBytes = readFile(dataDir / "vorbis_tone.ogg")
var toneData = newSeq[byte](toneBytes.len)
for i, value in toneBytes:
  toneData[i] = byte(ord(value))
let toneSound = decodeSound(toneData)
doAssert toneSound.sampleRate() == 22_050
doAssert toneSound.channels() == 2
doAssert toneSound.duration() >= initDuration(milliseconds = 500)
doAssert toneSound.duration() <= initDuration(milliseconds = 510)

let toneStream = newFileStream(dataDir / "vorbis_tone.ogg", fmRead)
doAssert not toneStream.isNil
let tone = newDecoder(toneStream)
doAssert tone.format == vorbis.vorbisFormatName
doAssert tone.decoder.sampleRate() == 22_050
doAssert tone.decoder.channels() == 2
let toneFrames = tone.decoder.length()
doAssert toneFrames >= 11_025 and toneFrames <= 11_025 + 128
var toneSamples = newSeqOfCap[float32](int(toneFrames) * 2)
var toneBuffer = newSeq[float32](2_048)
while true:
  let count = tone.decoder.read(toneBuffer)
  if count == 0:
    break
  toneSamples.add toneBuffer.toOpenArray(0, count - 1)
doAssert toneSamples.len == int(toneFrames) * 2

var zeroCrossings = 0
for i in countup(2, toneSamples.high, 2):
  if (toneSamples[i - 2] < 0'f32) != (toneSamples[i] < 0'f32):
    inc zeroCrossings
let frequency = float64(zeroCrossings) / 2.0 /
  (float64(toneSamples.len div 2) / 22_050.0)
doAssert abs(frequency - 440.0) <= 5.0

tone.decoder.setPosition(5_000)
var toneSeek = newSeq[float32](512)
let toneSeekCount = tone.decoder.read(toneSeek)
doAssert toneSeekCount > 0 and toneSeekCount mod 2 == 0
var nonzeroSeek = false
for i in 0 ..< toneSeekCount:
  if toneSeek[i] != 0'f32:
    nonzeroSeek = true
    break
doAssert nonzeroSeek
