import std/streams
import mynim/audio/mp3/internal/[
  bits, consts, frame, frameheader, huffman, maindata, sideinfo, source]

let header = frameHeader(0xFFFB_9064'u32)
doAssert header.isValid()
doAssert header.id() == version1
doAssert header.layer() == layer3
doAssert header.bitrateIndex() == 9
doAssert header.bitrate() == 128_000
doAssert header.samplingFrequencyValue() == 44_100
doAssert header.frameSize() == 417
doAssert header.sideInfoSize() == 32
doAssert header.numberOfChannels() == 2
doAssert header.bytesPerFrame() == 4_608

let mono = frameHeader(0xFFFB_90C4'u32)
doAssert mono.isValid()
doAssert mono.mode() == modeSingleChannel
doAssert mono.numberOfChannels() == 1
doAssert mono.sideInfoSize() == 17

var bitReader = initBits(@[0b1011_0010'u8, 0b0110_1001'u8])
doAssert bitReader.bit() == 1
doAssert bitReader.bits(3) == 3
doAssert bitReader.bitPos() == 4
doAssert bitReader.bits(4) == 2
doAssert bitReader.bits(8) == 0b0110_1001
doAssert bitReader.bitPos() == 16
doAssert bitReader.tail(1) == @[0b0110_1001'u8]

var side = readSideInfo(newMp3Source(newStringStream(newString(32))), header)
doAssert side.mainDataBegin == 0
doAssert side.part23Length[0][0] == 0
doAssert side.mainDataSize == 381
doAssert side.count1[1][1] == 0
let decoded = readMainData(newMp3Source(newStringStream(newString(381))),
  initBits(@[]), header, side)
doAssert decoded.bits.lenInBytes() == 381
doAssert decoded.data.spectrum[0][0][0] == 0

var huffmanBits = initBits(@[0b0000_0000'u8])
let pair = decode(huffmanBits, 1)
doAssert pair.x == 1 and pair.y == 1
doAssert pair.v == 0 and pair.w == 0
doAssert huffmanBits.bitPos() == 5
var emptyPairBits = initBits(@[0b1000_0000'u8])
let emptyPair = decode(emptyPairBits, 1)
doAssert emptyPair.x == 0 and emptyPair.y == 0
doAssert emptyPairBits.bitPos() == 1

let mpeg2 = frameHeader(0xFFF3_9064'u32)
doAssert mpeg2.isValid()
doAssert mpeg2.id() == version2
doAssert mpeg2.samplingFrequencyValue() == 22_050
doAssert mpeg2.granules() == 1
let mpeg2Side = readSideInfo(
  newMp3Source(newStringStream(newString(mpeg2.sideInfoSize()))), mpeg2)
doAssert mpeg2Side.mainDataSize == 240

let zeroFrameBytes = "\xFF\xFB\x90\x64" & newString(417 - 4)
let zeroFrameSource = newMp3Source(newStringStream(zeroFrameBytes))
let zeroFrame = readMp3Frame(zeroFrameSource, 0).frame
doAssert zeroFrame.sampleRate() == 44_100
let pcm = zeroFrame.decode()
doAssert pcm.len == 4_608
for sample in pcm:
  doAssert sample == 0

let tagged = newStringStream("ID3\x04\x00\x00\x00\x00\x00\x03XYZ" &
  "\xFF\xFB\x90\x64")
let taggedSource = newMp3Source(tagged)
taggedSource.skipTags()
doAssert taggedSource.position() == 13
let parsed = taggedSource.readFrameHeader(taggedSource.position())
doAssert parsed.header.raw() == 0xFFFB_9064'u32
doAssert parsed.startPosition == 13

let untagged = newStringStream("ABCD")
let untaggedSource = newMp3Source(untagged)
untaggedSource.skipTags()
doAssert untaggedSource.position() == 0
var prefix: array[4, byte]
discard untaggedSource.readFull(prefix)
doAssert prefix == [byte('A'), byte('B'), byte('C'), byte('D')]
doAssert untaggedSource.position() == 4

let shortSource = newMp3Source(newStringStream("xy"))
var shortBuffer: array[4, byte]
try:
  discard shortSource.readFull(shortBuffer)
  doAssert false
except Mp3EofError as error:
  doAssert error.bytesRead == 2
