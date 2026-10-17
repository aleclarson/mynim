import std/[os, streams]
import mynim/audio
import mynim/audio/mp3 as mp3

let frame = "\xFF\xFB\x90\x64" & newString(417 - 4)
let stream = newStringStream(frame & frame)
let opened = newDecoder(stream)
doAssert opened.format == mp3.mp3FormatName
doAssert opened.decoder.sampleRate() == 44_100
doAssert opened.decoder.channels() == 2
doAssert opened.decoder.length() == 2_304

var samples = newSeq[float32](512)
doAssert opened.decoder.read(samples) == samples.len
for sample in samples:
  doAssert sample == 0.0'f32

opened.decoder.setPosition(1_152)
var seekSamples = newSeq[float32](2)
doAssert opened.decoder.read(seekSamples) == 2
doAssert seekSamples == @[0.0'f32, 0.0'f32]

opened.decoder.setPosition(opened.decoder.length())
doAssert opened.decoder.read(seekSamples) == 0

let taggedStream = newStringStream("ID3\x04\x00\x00\x00\x00\x00\x03XYZ" & frame)
doAssert newDecoder(taggedStream).format == mp3.mp3FormatName

let fixturePath = currentSourcePath().parentDir / "data" / "mp3_tone.mp3"
let fixture = newFileStream(fixturePath, fmRead)
doAssert not fixture.isNil
let compressed = newDecoder(fixture).decoder
doAssert compressed.sampleRate() == 22_050
doAssert compressed.channels() == 2
doAssert compressed.length() > 0
var decoded = newSeq[float32](4_096)
var decodedSamples = 0
var peak = 0.0'f32
while true:
  let count = compressed.read(decoded)
  if count == 0:
    break
  decodedSamples += count
  for i in 0 ..< count:
    peak = max(peak, abs(decoded[i]))
doAssert decodedSamples == int(compressed.length() * 2)
doAssert peak > 0.01'f32
