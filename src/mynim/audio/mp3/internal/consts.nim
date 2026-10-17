## MPEG audio constants from github.com/hajimehoshi/go-mp3.
## Copyright 2017 Hajime Hoshi. Licensed under Apache-2.0.

type
  Mp3EofError* = object of CatchableError
    bytesRead*: int

  UnexpectedMp3EofError* = object of CatchableError
    location*: string

  MpegVersion* = enum
    version2_5, versionReserved, version2, version1

  MpegLayer* = enum
    layerReserved, layer3, layer2, layer1

  ChannelMode* = enum
    modeStereo, modeJointStereo, modeDualChannel, modeSingleChannel

  SamplingFrequency* = enum
    samplingFrequency44100, samplingFrequency48000,
    samplingFrequency32000, samplingFrequencyReserved

const
  samplesPerGranule* = 576
  granulesMpeg1* = 2
  sfBandIndicesLong* = 0
  sfBandIndicesShort* = 1

let sfBandIndices* = [
  [
    [
      @[0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 52, 62, 74, 90, 110, 134,
        162, 196, 238, 288, 342, 418, 576],
      @[0, 4, 8, 12, 16, 22, 30, 40, 52, 66, 84, 106, 136, 192]],
    [
      @[0, 4, 8, 12, 16, 20, 24, 30, 36, 42, 50, 60, 72, 88, 106, 128,
        156, 190, 230, 276, 330, 384, 576],
      @[0, 4, 8, 12, 16, 22, 28, 38, 50, 64, 80, 100, 126, 192]],
    [
      @[0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 54, 66, 82, 102, 126, 156,
        194, 240, 296, 364, 448, 550, 576],
      @[0, 4, 8, 12, 16, 22, 30, 42, 58, 78, 104, 138, 180, 192]]],
  [
    [
      @[0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 116, 140, 168,
        200, 238, 284, 336, 396, 464, 522, 576],
      @[0, 4, 8, 12, 18, 24, 32, 42, 56, 74, 100, 132, 174, 192]],
    [
      @[0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 114, 136, 162, 194,
        232, 278, 332, 394, 464, 540, 576],
      @[0, 4, 8, 12, 18, 26, 36, 48, 62, 80, 104, 136, 180, 192]],
    [
      @[0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 116, 140, 168,
        200, 238, 284, 336, 396, 464, 522, 576],
      @[0, 4, 8, 12, 18, 26, 36, 48, 62, 80, 104, 134, 174, 192]]]]
