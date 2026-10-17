## MPEG Layer III frame decoding from github.com/hajimehoshi/go-mp3.
## Copyright 2017 Hajime Hoshi. Licensed under Apache-2.0.

import std/math
import ./[bits, consts, frameheader, imdct, maindata, sideinfo, source,
  synthesis_table]

type Mp3Frame* = ref object
  header: FrameHeader
  sideInfo: SideInfo
  mainData: MainData
  mainDataBits: Bits
  store: array[2, array[32, array[18, float32]]]
  vVec: array[2, array[1024, float32]]

proc initPowTable(): array[8_207, float64] =
  for i in 0 ..< result.len:
    result[i] = pow(float64(i), 4.0 / 3.0)

let powtab34 = initPowTable()
const pretab = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
  1.0, 1.0, 1.0, 1.0, 2.0, 2.0, 3.0, 3.0, 3.0, 2.0, 0.0]

proc readCrc(source: Mp3Source) =
  var checksum: array[2, byte]
  try:
    discard source.readFull(checksum)
  except Mp3EofError:
    raise newException(UnexpectedMp3EofError,
      "mp3: unexpected EOF at readCRC")

proc readMp3Frame*(source: Mp3Source; position: int64;
    previous: Mp3Frame = nil): tuple[frame: Mp3Frame, startPosition: int64] =
  let parsedHeader = source.readFrameHeader(position)
  let header = parsedHeader.header
  if header.protectionBit() == 0:
    source.readCrc()
  if header.id() == version2_5:
    raise newException(ValueError, "mp3: MPEG version 2.5 is not supported")
  if header.layer() != layer3:
    raise newException(ValueError, "mp3: only layer III is supported")

  var side = source.readSideInfo(header)
  let previousBits = if previous.isNil: initBits(@[]) else: previous.mainDataBits
  let decodedData = source.readMainData(previousBits, header, side)
  result.frame = Mp3Frame(header: header, sideInfo: side,
    mainData: decodedData.data, mainDataBits: decodedData.bits)
  result.startPosition = parsedHeader.startPosition
  if not previous.isNil:
    result.frame.store = previous.store
    result.frame.vVec = previous.vVec

proc sampleRate*(frame: Mp3Frame): int =
  frame.header.samplingFrequencyValue()

proc sfBandIndices(header: FrameHeader):
    tuple[long, short: seq[int]] =
  let version = header.lowSamplingFrequency()
  let frequency = ord(header.samplingFrequency())
  result.long = consts.sfBandIndices[version][frequency][sfBandIndicesLong]
  result.short = consts.sfBandIndices[version][frequency][sfBandIndicesShort]

proc requantizeLong(frame: Mp3Frame; granule, channel, position, band: int) =
  let side = frame.sideInfo
  let scale = if side.scalefacScale[granule][channel] != 0: 1.0 else: 0.5
  let preemphasis = float64(side.preflag[granule][channel]) * pretab[band]
  let index = -(scale * (float64(frame.mainData.scalefacL[granule][channel][band]) +
    preemphasis)) + 0.25 * (float64(side.globalGain[granule][channel]) - 210.0)
  let magnitude = int(abs(frame.mainData.spectrum[granule][channel][position]))
  if magnitude >= powtab34.len:
    raise newException(ValueError, "mp3: spectral value exceeds requantization table")
  let signedMagnitude = if frame.mainData.spectrum[granule][channel][position] < 0:
    -powtab34[magnitude] else: powtab34[magnitude]
  frame.mainData.spectrum[granule][channel][position] =
    float32(pow(2.0, index) * signedMagnitude)

proc requantizeShort(frame: Mp3Frame; granule, channel, position, band,
    window: int) =
  let side = frame.sideInfo
  let scale = if side.scalefacScale[granule][channel] != 0: 1.0 else: 0.5
  let index = -(scale * float64(
    frame.mainData.scalefacS[granule][channel][band][window])) +
    0.25 * (float64(side.globalGain[granule][channel]) - 210.0 -
      8.0 * float64(side.subblockGain[granule][channel][window]))
  let magnitude = int(abs(frame.mainData.spectrum[granule][channel][position]))
  if magnitude >= powtab34.len:
    raise newException(ValueError, "mp3: spectral value exceeds requantization table")
  let signedMagnitude = if frame.mainData.spectrum[granule][channel][position] < 0:
    -powtab34[magnitude] else: powtab34[magnitude]
  frame.mainData.spectrum[granule][channel][position] =
    float32(pow(2.0, index) * signedMagnitude)

proc requantize(frame: Mp3Frame; granule, channel: int) =
  let bands = frame.header.sfBandIndices()
  let side = frame.sideInfo
  if side.winSwitchFlag[granule][channel] == 1 and
      side.blockType[granule][channel] == 2:
    if side.mixedBlockFlag[granule][channel] != 0:
      var band = 0
      var nextBand = bands.long[band + 1]
      for i in 0 ..< 36:
        if i == nextBand:
          inc band
          nextBand = bands.long[band + 1]
        frame.requantizeLong(granule, channel, i, band)
      band = 3
      nextBand = bands.short[band + 1] * 3
      var windowLength = bands.short[band + 1] - bands.short[band]
      var i = 36
      while i < side.count1[granule][channel]:
        if i == nextBand:
          inc band
          nextBand = bands.short[band + 1] * 3
          windowLength = bands.short[band + 1] - bands.short[band]
        for window in 0 ..< 3:
          for _ in 0 ..< windowLength:
            frame.requantizeShort(granule, channel, i, band, window)
            inc i
    else:
      var band = 0
      var nextBand = bands.short[band + 1] * 3
      var windowLength = bands.short[band + 1] - bands.short[band]
      var i = 0
      while i < side.count1[granule][channel]:
        if i == nextBand:
          inc band
          nextBand = bands.short[band + 1] * 3
          windowLength = bands.short[band + 1] - bands.short[band]
        for window in 0 ..< 3:
          for _ in 0 ..< windowLength:
            frame.requantizeShort(granule, channel, i, band, window)
            inc i
  else:
    var band = 0
    var nextBand = bands.long[band + 1]
    for i in 0 ..< side.count1[granule][channel]:
      if i == nextBand:
        inc band
        nextBand = bands.long[band + 1]
      frame.requantizeLong(granule, channel, i, band)

proc reorder(frame: Mp3Frame; granule, channel: int) =
  var reordered: array[samplesPerGranule, float32]
  let bands = frame.header.sfBandIndices().short
  let side = frame.sideInfo
  if side.winSwitchFlag[granule][channel] != 1 or
      side.blockType[granule][channel] != 2:
    return
  var band = 0
  if side.mixedBlockFlag[granule][channel] != 0:
    band = 3
  var nextBand = bands[band + 1] * 3
  var windowLength = bands[band + 1] - bands[band]
  var i = if band == 0: 0 else: 36
  while i < samplesPerGranule:
    if i == nextBand:
      let copyStart = 3 * bands[band]
      for j in 0 ..< 3 * windowLength:
        frame.mainData.spectrum[granule][channel][copyStart + j] =
          reordered[j]
      if i >= side.count1[granule][channel]:
        return
      inc band
      nextBand = bands[band + 1] * 3
      windowLength = bands[band + 1] - bands[band]
    for window in 0 ..< 3:
      for j in 0 ..< windowLength:
        reordered[j * 3 + window] =
          frame.mainData.spectrum[granule][channel][i]
        inc i
  let copyStart = 3 * bands[12]
  for j in 0 ..< 3 * windowLength:
    frame.mainData.spectrum[granule][channel][copyStart + j] = reordered[j]

const isRatios = [0.0'f32, 0.267949'f32, 0.577350'f32, 1.0'f32,
  1.732051'f32, 3.732051'f32]

proc stereoIntensityLong(frame: Mp3Frame; granule, band: int) =
  let position = frame.mainData.scalefacL[granule][0][band]
  if position >= 7:
    return
  let sf = frame.header.sfBandIndices().long
  let leftRatio = if position == 6: 1.0'f32 else:
    isRatios[position] / (1.0'f32 + isRatios[position])
  let rightRatio = if position == 6: 0.0'f32 else:
    1.0'f32 / (1.0'f32 + isRatios[position])
  for i in sf[band] ..< sf[band + 1]:
    frame.mainData.spectrum[granule][0][i] *= leftRatio
    frame.mainData.spectrum[granule][1][i] *= rightRatio

proc stereoIntensityShort(frame: Mp3Frame; granule, band: int) =
  let sf = frame.header.sfBandIndices().short
  let windowLength = sf[band + 1] - sf[band]
  for window in 0 ..< 3:
    let position = frame.mainData.scalefacS[granule][0][band][window]
    if position >= 7:
      continue
    let start = sf[band] * 3 + windowLength * window
    let leftRatio = if position == 6: 1.0'f32 else:
      isRatios[position] / (1.0'f32 + isRatios[position])
    let rightRatio = if position == 6: 0.0'f32 else:
      1.0'f32 / (1.0'f32 + isRatios[position])
    for i in start ..< start + windowLength:
      frame.mainData.spectrum[granule][0][i] *= leftRatio
      frame.mainData.spectrum[granule][1][i] *= rightRatio

proc stereo(frame: Mp3Frame; granule: int) =
  let side = frame.sideInfo
  if frame.header.useMsStereo():
    let channel = if side.count1[granule][0] > side.count1[granule][1]: 0 else: 1
    let maxPosition = side.count1[granule][channel]
    let inverseSqrt2 = float32(sqrt(2.0) / 2.0)
    for i in 0 ..< maxPosition:
      let left = (frame.mainData.spectrum[granule][0][i] +
        frame.mainData.spectrum[granule][1][i]) * inverseSqrt2
      let right = (frame.mainData.spectrum[granule][0][i] -
        frame.mainData.spectrum[granule][1][i]) * inverseSqrt2
      frame.mainData.spectrum[granule][0][i] = left
      frame.mainData.spectrum[granule][1][i] = right

  if not frame.header.useIntensityStereo():
    return
  let bands = frame.header.sfBandIndices()
  if side.winSwitchFlag[granule][0] == 1 and
      side.blockType[granule][0] == 2:
    if side.mixedBlockFlag[granule][0] != 0:
      for band in 0 ..< 8:
        if bands.long[band] >= side.count1[granule][1]:
          frame.stereoIntensityLong(granule, band)
      for band in 3 ..< 12:
        if bands.short[band] * 3 >= side.count1[granule][1]:
          frame.stereoIntensityShort(granule, band)
    else:
      for band in 0 ..< 12:
        if bands.short[band] * 3 >= side.count1[granule][1]:
          frame.stereoIntensityShort(granule, band)
  else:
    for band in 0 ..< 21:
      if bands.long[band] >= side.count1[granule][1]:
        frame.stereoIntensityLong(granule, band)

const antialiasCs = [0.857493'f32, 0.881742'f32, 0.949629'f32,
  0.983315'f32, 0.995518'f32, 0.999161'f32, 0.999899'f32, 0.999993'f32]
const antialiasCa = [-0.514496'f32, -0.471732'f32, -0.313377'f32,
  -0.181913'f32, -0.094574'f32, -0.040966'f32, -0.014199'f32, -0.003700'f32]

proc antialias(frame: Mp3Frame; granule, channel: int) =
  let side = frame.sideInfo
  if side.winSwitchFlag[granule][channel] == 1 and
      side.blockType[granule][channel] == 2 and
      side.mixedBlockFlag[granule][channel] == 0:
    return
  let subbandLimit = if side.winSwitchFlag[granule][channel] == 1 and
      side.blockType[granule][channel] == 2 and
      side.mixedBlockFlag[granule][channel] == 1: 2 else: 32
  for subband in 1 ..< subbandLimit:
    for i in 0 ..< 8:
      let lower = 18 * subband - 1 - i
      let upper = 18 * subband + i
      let lowerBand = frame.mainData.spectrum[granule][channel][lower] *
        antialiasCs[i] - frame.mainData.spectrum[granule][channel][upper] *
        antialiasCa[i]
      let upperBand = frame.mainData.spectrum[granule][channel][upper] *
        antialiasCs[i] + frame.mainData.spectrum[granule][channel][lower] *
        antialiasCa[i]
      frame.mainData.spectrum[granule][channel][lower] = lowerBand
      frame.mainData.spectrum[granule][channel][upper] = upperBand

proc hybridSynthesis(frame: Mp3Frame; granule, channel: int) =
  for subband in 0 ..< 32:
    var blockType = frame.sideInfo.blockType[granule][channel]
    if frame.sideInfo.winSwitchFlag[granule][channel] == 1 and
        frame.sideInfo.mixedBlockFlag[granule][channel] == 1 and subband < 2:
      blockType = 0
    var input: array[18, float32]
    for i in 0 ..< input.len:
      input[i] = frame.mainData.spectrum[granule][channel][subband * 18 + i]
    let rawOutput = imdct.win(input, blockType)
    for i in 0 ..< 18:
      frame.mainData.spectrum[granule][channel][subband * 18 + i] =
        rawOutput[i] + frame.store[channel][subband][i]
      frame.store[channel][subband][i] = rawOutput[i + 18]

proc frequencyInversion(frame: Mp3Frame; granule, channel: int) =
  for subband in countup(1, 31, 2):
    for i in countup(1, 17, 2):
      frame.mainData.spectrum[granule][channel][subband * 18 + i] =
        -frame.mainData.spectrum[granule][channel][subband * 18 + i]

proc initSynthesisWindow(): array[64, array[32, float32]] =
  for i in 0 ..< 64:
    for j in 0 ..< 32:
      result[i][j] = float32(cos(float64((16 + i) * (2 * j + 1)) *
        (PI / 64.0)))

let synthNWin = initSynthesisWindow()

proc subbandSynthesis(frame: Mp3Frame; granule, channel: int;
    output: var seq[byte]; outputOffset: int) =
  var uVec: array[512, float32]
  var sVec: array[32, float32]
  let channelCount = frame.header.numberOfChannels()
  for sample in 0 ..< 18:
    for i in countdown(1023 - 64, 0):
      frame.vVec[channel][i + 64] = frame.vVec[channel][i]
    for i in 0 ..< 32:
      sVec[i] = frame.mainData.spectrum[granule][channel][i * 18 + sample]
    for i in 0 ..< 64:
      var sum = 0'f32
      for j in 0 ..< 32:
        sum += synthNWin[i][j] * sVec[j]
      frame.vVec[channel][i] = sum
    for i in countup(0, 448, 64):
      for j in 0 ..< 32:
        uVec[i + j] = frame.vVec[channel][2 * i + j]
        uVec[i + 32 + j] = frame.vVec[channel][2 * i + 96 + j]
    for i in 0 ..< 512:
      uVec[i] *= synthDTable[i]
    for i in 0 ..< 32:
      var sum = 0'f32
      for j in countup(0, 480, 32):
        sum += uVec[j + i]
      var sampleValue = int(sum * 32767)
      sampleValue = min(max(sampleValue, -32767), 32767)
      let sampleBits = cast[uint16](int16(sampleValue))
      let index = outputOffset + 4 * (32 * sample + i)
      if channelCount == 1 or channel == 0:
        output[index] = byte(sampleBits and 0xFF'u16)
        output[index + 1] = byte(sampleBits shr 8)
      if channelCount == 1 or channel == 1:
        output[index + 2] = byte(sampleBits and 0xFF'u16)
        output[index + 3] = byte(sampleBits shr 8)

proc decode*(frame: Mp3Frame): seq[byte] =
  result = newSeq[byte](frame.header.bytesPerFrame())
  let channelCount = frame.header.numberOfChannels()
  for granule in 0 ..< frame.header.granules():
    for channel in 0 ..< channelCount:
      frame.requantize(granule, channel)
      frame.reorder(granule, channel)
    frame.stereo(granule)
    for channel in 0 ..< channelCount:
      frame.antialias(granule, channel)
      frame.hybridSynthesis(granule, channel)
      frame.frequencyInversion(granule, channel)
      frame.subbandSynthesis(granule, channel, result,
        samplesPerGranule * 4 * granule)
