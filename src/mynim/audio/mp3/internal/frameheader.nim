## MPEG audio frame-header parsing from github.com/hajimehoshi/go-mp3.
## Copyright 2017 Hajime Hoshi. Licensed under Apache-2.0.

import std/strutils
import ./consts
import ./source

type FrameHeader* = distinct uint32

proc frameHeader*(raw: uint32): FrameHeader = FrameHeader(raw)

proc raw*(header: FrameHeader): uint32 = uint32(header)

proc id*(header: FrameHeader): MpegVersion =
  MpegVersion((header.raw and 0x0018_0000'u32) shr 19)

proc layer*(header: FrameHeader): MpegLayer =
  MpegLayer((header.raw and 0x0006_0000'u32) shr 17)

proc protectionBit*(header: FrameHeader): int =
  int((header.raw and 0x0001_0000'u32) shr 16)

proc bitrateIndex*(header: FrameHeader): int =
  int((header.raw and 0x0000_F000'u32) shr 12)

proc samplingFrequency*(header: FrameHeader): SamplingFrequency =
  SamplingFrequency((header.raw and 0x0000_0C00'u32) shr 10)

proc lowSamplingFrequency*(header: FrameHeader): int =
  if header.id() == version1: 0 else: 1

proc samplingFrequencyValue*(header: FrameHeader): int =
  let lowSamplingFrequency = header.lowSamplingFrequency()
  case header.samplingFrequency()
  of samplingFrequency44100: 44_100 shr lowSamplingFrequency
  of samplingFrequency48000: 48_000 shr lowSamplingFrequency
  of samplingFrequency32000: 32_000 shr lowSamplingFrequency
  of samplingFrequencyReserved:
    raise newException(ValueError,
      "mp3: frame header has invalid sample frequency")

proc paddingBit*(header: FrameHeader): int =
  int((header.raw and 0x0000_0200'u32) shr 9)

proc privateBit*(header: FrameHeader): int =
  int((header.raw and 0x0000_0100'u32) shr 8)

proc mode*(header: FrameHeader): ChannelMode =
  ChannelMode((header.raw and 0x0000_00C0'u32) shr 6)

proc modeExtension(header: FrameHeader): int =
  int((header.raw and 0x0000_0030'u32) shr 4)

proc useMsStereo*(header: FrameHeader): bool =
  header.mode() == modeJointStereo and (header.modeExtension() and 2) != 0

proc useIntensityStereo*(header: FrameHeader): bool =
  header.mode() == modeJointStereo and (header.modeExtension() and 1) != 0

proc copyright*(header: FrameHeader): int =
  int((header.raw and 0x0000_0008'u32) shr 3)

proc originalOrCopy*(header: FrameHeader): int =
  int((header.raw and 0x0000_0004'u32) shr 2)

proc emphasis*(header: FrameHeader): int = int(header.raw and 3)

proc granules*(header: FrameHeader): int =
  granulesMpeg1 shr header.lowSamplingFrequency()

proc bytesPerFrame*(header: FrameHeader): int =
  samplesPerGranule * header.granules() * 4

proc isValid*(header: FrameHeader): bool =
  const sync = 0xFFE0_0000'u32
  (header.raw and sync) == sync and header.id() != versionReserved and
    header.bitrateIndex() != 15 and
    header.samplingFrequency() != samplingFrequencyReserved and
    header.layer() != layerReserved and header.emphasis() != 2

proc bitrate*(header: FrameHeader): int =
  const bitrates = [
    [
      [0, 32_000, 40_000, 48_000, 56_000, 64_000, 80_000, 96_000,
        112_000, 128_000, 160_000, 192_000, 224_000, 256_000, 320_000, 0],
      [0, 32_000, 48_000, 56_000, 64_000, 80_000, 96_000, 112_000,
        128_000, 160_000, 192_000, 224_000, 256_000, 320_000, 384_000, 0],
      [0, 32_000, 64_000, 96_000, 128_000, 160_000, 192_000, 224_000,
        256_000, 288_000, 320_000, 352_000, 384_000, 416_000, 448_000, 0]],
    [
      [0, 8_000, 16_000, 24_000, 32_000, 40_000, 48_000, 56_000,
        64_000, 80_000, 96_000, 112_000, 128_000, 144_000, 160_000, 0],
      [0, 8_000, 16_000, 24_000, 32_000, 40_000, 48_000, 56_000,
        64_000, 80_000, 96_000, 112_000, 128_000, 144_000, 160_000, 0],
      [0, 32_000, 48_000, 56_000, 64_000, 80_000, 96_000, 112_000,
        128_000, 144_000, 160_000, 176_000, 192_000, 224_000, 256_000, 0]]]
  bitrates[header.lowSamplingFrequency()][ord(header.layer()) - 1][
    header.bitrateIndex()]

proc frameSize*(header: FrameHeader): int =
  let rate = header.samplingFrequencyValue()
  ((144 * header.bitrate()) div rate + header.paddingBit()) shr
    header.lowSamplingFrequency()

proc sideInfoSize*(header: FrameHeader): int =
  let mono = header.mode() == modeSingleChannel
  if header.lowSamplingFrequency() == 1:
    if mono: 9 else: 17
  else:
    if mono: 17 else: 32

proc numberOfChannels*(header: FrameHeader): int =
  if header.mode() == modeSingleChannel: 1 else: 2

proc readFrameHeader*(source: Mp3Source; position: int64):
    tuple[header: FrameHeader, startPosition: int64] =
  var bytes: array[4, byte]
  try:
    discard source.readFull(bytes)
  except Mp3EofError as error:
    if error.bytesRead == 0:
      raise
    raise newException(UnexpectedMp3EofError,
      "mp3: unexpected EOF at readHeader (1)")

  var b1 = uint32(bytes[0])
  var b2 = uint32(bytes[1])
  var b3 = uint32(bytes[2])
  var b4 = uint32(bytes[3])
  result.header = frameHeader((b1 shl 24) or (b2 shl 16) or
    (b3 shl 8) or b4)
  result.startPosition = position
  while not result.header.isValid():
    b1 = b2
    b2 = b3
    b3 = b4
    var next: array[1, byte]
    try:
      discard source.readFull(next)
    except Mp3EofError:
      raise newException(UnexpectedMp3EofError,
        "mp3: unexpected EOF at readHeader (2)")
    b4 = uint32(next[0])
    result.startPosition += 1
    result.header = frameHeader((b1 shl 24) or (b2 shl 16) or
      (b3 shl 8) or b4)

  if result.header.bitrateIndex() == 0:
    raise newException(ValueError,
      "mp3: free bitrate format is not supported; header 0x" &
      toHex(result.header.raw(), 8) & " at position " &
      $result.startPosition)
