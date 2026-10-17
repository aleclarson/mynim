import std/[os, streams]
import mynim/audio
import mynim/audio/vorbis as vorbis

let dataDir = currentSourcePath().parentDir / "data"
# The Ogg stream and reference PCM come from oggvorbis v1.0.5's MIT testdata.
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
