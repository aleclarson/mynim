import std/[assertions, streams, times]
import mynim/audio

proc addText(bytes: var seq[byte]; text: string) =
  for c in text:
    bytes.add byte(ord(c))

proc addU16(bytes: var seq[byte]; value: uint16) =
  bytes.add byte(value and 0xff'u16)
  bytes.add byte(value shr 8)

proc addU32(bytes: var seq[byte]; value: uint32) =
  bytes.add byte(value and 0xff'u32)
  bytes.add byte((value shr 8) and 0xff'u32)
  bytes.add byte((value shr 16) and 0xff'u32)
  bytes.add byte(value shr 24)

proc wav(tag, channelCount, bits: uint16; payload: openArray[byte];
         streaming = false): seq[byte] =
  let paddedSize = payload.len + (payload.len and 1)
  result.addText("RIFF")
  result.addU32(uint32(36 + paddedSize))
  result.addText("WAVEfmt ")
  result.addU32(16)
  result.addU16(tag)
  result.addU16(channelCount)
  result.addU32(8000)
  result.addU32(uint32(8000 * int(channelCount) * int(bits) div 8))
  result.addU16(uint16(int(channelCount) * int(bits) div 8))
  result.addU16(bits)
  result.addText("data")
  result.addU32(if streaming: 0xffff_ffff'u32 else: uint32(payload.len))
  result.add payload
  if (payload.len and 1) != 0:
    result.add 0

proc extensibleWav(): seq[byte] =
  result.addText("RIFF")
  result.addU32(74)
  result.addText("WAVEJUNK")
  result.addU32(3)
  result.add @[1'u8, 2, 3, 0]
  result.addText("fmt ")
  result.addU32(40)
  result.addU16(0xfffe)
  result.addU16(1)
  result.addU32(8000)
  result.addU32(16000)
  result.addU16(2)
  result.addU16(16)
  result.addU16(22)
  result.addU16(16)
  result.addU32(0)
  result.add @[1'u8, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa,
    0, 0x38, 0x9b, 0x71]
  result.addText("data")
  result.addU32(2)
  result.add @[0'u8, 0x40]

proc bytesString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  if bytes.len > 0:
    copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)

proc closeTo(a, b: float32): bool = abs(a - b) < 0.00001'f32

block decodesIntegerPcmWidths:
  let eight = decodeSound(wav(1, 1, 8, @[0'u8, 128, 255]))
  doAssert eight.sampleRate() == 8000
  doAssert eight.channels() == 1
  doAssert eight.samples().len == 3
  doAssert closeTo(eight.samples()[0], -1.0'f32)
  doAssert closeTo(eight.samples()[1], 0.0'f32)
  doAssert closeTo(eight.samples()[2], 127.0'f32 / 128.0'f32)

  let sixteen = decodeSound(wav(1, 1, 16, @[
    0x00'u8, 0x80, 0x00, 0x00, 0xff, 0x7f]))
  doAssert sixteen.samples().len == 3
  doAssert closeTo(sixteen.samples()[0], -1.0'f32)
  doAssert closeTo(sixteen.samples()[1], 0.0'f32)
  doAssert closeTo(sixteen.samples()[2], 32767.0'f32 / 32768.0'f32)

  let twentyFour = decodeSound(wav(1, 1, 24, @[
    0x00'u8, 0x00, 0x80, 0x00, 0x00, 0x00, 0xff, 0xff, 0x7f]))
  doAssert closeTo(twentyFour.samples()[0], -1.0'f32)
  doAssert closeTo(twentyFour.samples()[1], 0.0'f32)
  doAssert closeTo(twentyFour.samples()[2], 8388607.0'f32 / 8388608.0'f32)

  let thirtyTwo = decodeSound(wav(1, 1, 32, @[
    0x00'u8, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0x7f]))
  doAssert closeTo(thirtyTwo.samples()[0], -1.0'f32)
  doAssert closeTo(thirtyTwo.samples()[1], 0.0'f32)
  doAssert closeTo(thirtyTwo.samples()[2], 1.0'f32)

block decodesFloatingPointPcm:
  var float32Data: seq[byte]
  float32Data.addU32(cast[uint32](0.5'f32))
  float32Data.addU32(cast[uint32](-0.25'f32))
  let float32Sound = decodeSound(wav(3, 1, 32, float32Data))
  doAssert closeTo(float32Sound.samples()[0], 0.5'f32)
  doAssert closeTo(float32Sound.samples()[1], -0.25'f32)

  var float64Data: seq[byte]
  let positive = cast[uint64](0.5)
  let negative = cast[uint64](-0.25)
  float64Data.addU32(uint32(positive and 0xffff_ffff'u64))
  float64Data.addU32(uint32(positive shr 32))
  float64Data.addU32(uint32(negative and 0xffff_ffff'u64))
  float64Data.addU32(uint32(negative shr 32))
  let float64Sound = decodeSound(wav(3, 1, 64, float64Data))
  doAssert closeTo(float64Sound.samples()[0], 0.5'f32)
  doAssert closeTo(float64Sound.samples()[1], -0.25'f32)

block acceptsExtensibleFormatAndSkipsPaddedChunks:
  let sound = decodeSound(extensibleWav())
  doAssert sound.sampleRate() == 8000
  doAssert sound.channels() == 1
  doAssert closeTo(sound.samples()[0], 0.5'f32)

block retainsStereoAndDropsLaterChannels:
  let sound = decodeSound(wav(1, 3, 16, @[
    0x00'u8, 0x40, 0x00, 0xc0, 0x00, 0x20,
    0x00, 0xe0, 0x00, 0x10, 0x00, 0xf0]))
  doAssert sound.channels() == 2
  doAssert sound.samples().len == 4
  doAssert closeTo(sound.samples()[0], 0.5'f32)
  doAssert closeTo(sound.samples()[1], -0.5'f32)
  doAssert closeTo(sound.samples()[2], -0.25'f32)
  doAssert closeTo(sound.samples()[3], 0.125'f32)
  doAssert sound.duration() == initDuration(nanoseconds = 250_000)

block readsUnknownLengthAndSeeks:
  let data = wav(1, 1, 8, @[128'u8, 255, 0, 128], streaming = true)
  let stream = newStringStream(bytesString(data))
  try:
    let (decoder, format) = newDecoder(stream)
    doAssert format == "wav"
    doAssert decoder.length() == -1
    var output = newSeq[float32](8)
    doAssert decoder.read(output) == 4
    doAssert decoder.read(output) == 0
    decoder.setPosition(1)
    doAssert decoder.read(output) == 3
    doAssert closeTo(output[0], 127.0'f32 / 128.0'f32)
    doAssert closeTo(output[1], -1.0'f32)
  finally:
    stream.close()

block reportsInvalidFormatsAndTruncatedData:
  doAssertRaises AudioError:
    discard decodeSound([1'u8, 2, 3])
  doAssertRaises AudioError:
    discard decodeSound(wav(6, 1, 16, @[0'u8, 0]))

  var truncated = wav(1, 1, 16, @[0'u8, 0, 1, 0, 2, 0])
  truncated.setLen(truncated.len - 2)
  doAssertRaises AudioError:
    discard decodeSound(truncated)

block storesGeneratedSamples:
  let sound = newSound(8000, 2, @[1.0'f32, -1.0, 0.5])
  doAssert sound.channels() == 2
  doAssert sound.samples() == @[1.0'f32, -1.0]
