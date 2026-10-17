## Layer III scale-factor and spectral-data parsing from
## github.com/hajimehoshi/go-mp3. Copyright 2017 Hajime Hoshi.
## Licensed under Apache-2.0.

import ./[bits, consts, frameheader, huffman, sideinfo, source]

type MainData* = object
  scalefacL*: array[2, array[2, array[22, int]]]
  scalefacS*: array[2, array[2, array[13, array[3, int]]]]
  spectrum*: array[2, array[2, array[576, float32]]]

const scalefacSizesMpeg1 = [
  [0, 0], [0, 1], [0, 2], [0, 3], [3, 0], [1, 1], [1, 2], [1, 3],
  [2, 1], [2, 2], [2, 3], [3, 1], [3, 2], [3, 3], [4, 2], [4, 3]]

const scalefacSizesMpeg2 = [
  [
    [6, 5, 5, 5], [6, 5, 7, 3], [11, 10, 0, 0],
    [7, 7, 7, 0], [6, 6, 6, 3], [8, 8, 5, 0]],
  [
    [9, 9, 9, 9], [9, 9, 12, 6], [18, 18, 0, 0],
    [12, 12, 12, 0], [12, 9, 9, 6], [15, 12, 9, 0]],
  [
    [6, 9, 9, 9], [6, 9, 12, 6], [15, 18, 0, 0],
    [6, 15, 12, 0], [6, 12, 9, 6], [6, 18, 9, 0]]]

proc initSlen(): array[512, int] =
  for i in 0 ..< 4:
    for j in 0 ..< 3:
      let n = j + i * 3
      result[n + 500] = i or (j shl 3) or (2 shl 12) or (1 shl 15)
  for i in 0 ..< 5:
    for j in 0 ..< 5:
      for k in 0 ..< 4:
        for l in 0 ..< 4:
          let n = l + k * 4 + j * 16 + i * 80
          result[n] = i or (j shl 3) or (k shl 6) or (l shl 9)
  for i in 0 ..< 5:
    for j in 0 ..< 5:
      for k in 0 ..< 4:
        let n = k + j * 4 + i * 20
        result[n + 400] = i or (j shl 3) or (k shl 6) or (1 shl 12)

let nSlen2 = initSlen()

proc readHuffman(reader: var Bits; header: FrameHeader;
    sideInfo: var SideInfo; mainData: var MainData;
    part2Start, granule, channel: int) =
  if sideInfo.part23Length[granule][channel] == 0:
    for i in 0 ..< 576:
      mainData.spectrum[granule][channel][i] = 0
    return

  let bitPositionEnd = part2Start +
    sideInfo.part23Length[granule][channel] - 1
  var region1Start, region2Start: int
  if sideInfo.winSwitchFlag[granule][channel] == 1 and
      sideInfo.blockType[granule][channel] == 2:
    region1Start = 36
    region2Start = 576
  else:
    let longBands = sfBandIndices[header.lowSamplingFrequency()][
      ord(header.samplingFrequency())][sfBandIndicesLong]
    let i = sideInfo.region0Count[granule][channel] + 1
    if i < 0 or i >= longBands.len:
      raise newException(ValueError,
        "mp3: readHuffman failed: invalid region 0 index " & $i)
    region1Start = longBands[i]
    let j = sideInfo.region0Count[granule][channel] +
      sideInfo.region1Count[granule][channel] + 2
    if j < 0 or j >= longBands.len:
      raise newException(ValueError,
        "mp3: readHuffman failed: invalid region 1 index " & $j)
    region2Start = longBands[j]

  let bigValueLines = sideInfo.bigValues[granule][channel] * 2
  var isPosition = 0
  while isPosition < bigValueLines:
    if isPosition >= 576:
      raise newException(ValueError,
        "mp3: Huffman spectral position exceeds 575")
    var tableNumber: int
    if isPosition < region1Start:
      tableNumber = sideInfo.tableSelect[granule][channel][0]
    elif isPosition < region2Start:
      tableNumber = sideInfo.tableSelect[granule][channel][1]
    else:
      tableNumber = sideInfo.tableSelect[granule][channel][2]
    let decoded = huffman.decode(reader, tableNumber)
    mainData.spectrum[granule][channel][isPosition] = float32(decoded.x)
    inc isPosition
    mainData.spectrum[granule][channel][isPosition] = float32(decoded.y)
    inc isPosition

  let tableNumber = sideInfo.count1TableSelect[granule][channel] + 32
  isPosition = bigValueLines
  while isPosition <= 572 and reader.bitPos() <= bitPositionEnd:
    let decoded = huffman.decode(reader, tableNumber)
    mainData.spectrum[granule][channel][isPosition] = float32(decoded.v)
    inc isPosition
    if isPosition >= 576: break
    mainData.spectrum[granule][channel][isPosition] = float32(decoded.w)
    inc isPosition
    if isPosition >= 576: break
    mainData.spectrum[granule][channel][isPosition] = float32(decoded.x)
    inc isPosition
    if isPosition >= 576: break
    mainData.spectrum[granule][channel][isPosition] = float32(decoded.y)
    inc isPosition

  if reader.bitPos() > bitPositionEnd + 1:
    isPosition -= 4
  isPosition = max(isPosition, 0)
  sideInfo.count1[granule][channel] = isPosition
  while isPosition < 576:
    mainData.spectrum[granule][channel][isPosition] = 0
    inc isPosition
  reader.setPos(bitPositionEnd + 1)

proc readMainData*(source: Mp3Source; previous: Bits; header: FrameHeader;
    sideInfo: var SideInfo): tuple[data: MainData, bits: Bits] =
  let channelCount = header.numberOfChannels()
  let frameSize = header.frameSize()
  if frameSize > 2_000:
    raise newException(ValueError, "mp3: frame size exceeds 2000 bytes")
  var mainDataSize = frameSize - header.sideInfoSize() - 4
  if header.protectionBit() == 0:
    mainDataSize -= 2
  if mainDataSize < 0 or mainDataSize > 1_500:
    raise newException(ValueError, "mp3: invalid main data size " &
      $mainDataSize)

  var current = newSeq[byte](mainDataSize)
  try:
    discard source.readFull(current)
  except Mp3EofError:
    raise newException(UnexpectedMp3EofError,
      "mp3: unexpected EOF at maindata.Read")
  var dataBytes: seq[byte]
  if previous.lenInBytes() > 0 and sideInfo.mainDataBegin > 0:
    if sideInfo.mainDataBegin > previous.lenInBytes():
      result.bits = previous.append(current)
      return
    dataBytes = previous.tail(sideInfo.mainDataBegin)
  dataBytes.add current
  result.bits = initBits(move(dataBytes))

  if header.lowSamplingFrequency() == 1:
    for channel in 0 ..< channelCount:
      let part2Start = result.bits.bitPos()
      var bitCount = 0
      var slen = nSlen2[sideInfo.scalefacCompress[0][channel]]
      sideInfo.preflag[0][channel] = (slen shr 15) and 1
      var blockType = 0
      if sideInfo.blockType[0][channel] == 2:
        inc blockType
        if sideInfo.mixedBlockFlag[0][channel] != 0:
          inc blockType
      var scaleFactors: seq[int]
      let table = (slen shr 12) and 0x7
      for i in 0 ..< 4:
        let count = slen and 0x7
        slen = slen shr 3
        let size = scalefacSizesMpeg2[blockType][table][i]
        if count > 0:
          for _ in 0 ..< size:
            scaleFactors.add result.bits.bits(count)
          bitCount += size * count
        else:
          for _ in 0 ..< size:
            scaleFactors.add 0
      blockType = (blockType shl 1) + 1
      for _ in 0 ..< blockType:
        scaleFactors.add 0

      if scaleFactors.len == 22:
        for i in 0 ..< 22:
          result.data.scalefacL[0][channel][i] = scaleFactors[i]
      else:
        for band in 0 ..< 13:
          for window in 0 ..< 3:
            result.data.scalefacS[0][channel][band][window] =
              scaleFactors[band * 3 + window]
      readHuffman(result.bits, header, sideInfo, result.data, part2Start,
        0, channel)
  else:
    for granule in 0 ..< 2:
      for channel in 0 ..< channelCount:
        let part2Start = result.bits.bitPos()
        let compression = sideInfo.scalefacCompress[granule][channel]
        let slen1 = scalefacSizesMpeg1[compression][0]
        let slen2 = scalefacSizesMpeg1[compression][1]
        if sideInfo.winSwitchFlag[granule][channel] == 1 and
            sideInfo.blockType[granule][channel] == 2:
          if sideInfo.mixedBlockFlag[granule][channel] != 0:
            for band in 0 ..< 8:
              result.data.scalefacL[granule][channel][band] =
                result.bits.bits(slen1)
            for band in 3 ..< 12:
              let count = if band < 6: slen1 else: slen2
              for window in 0 ..< 3:
                result.data.scalefacS[granule][channel][band][window] =
                  result.bits.bits(count)
          else:
            for band in 0 ..< 12:
              let count = if band < 6: slen1 else: slen2
              for window in 0 ..< 3:
                result.data.scalefacS[granule][channel][band][window] =
                  result.bits.bits(count)
        else:
          for group in 0 ..< 4:
            let firstBand = [0, 6, 11, 16][group]
            let endBand = [6, 11, 16, 21][group]
            let count = if group < 2: slen1 else: slen2
            if sideInfo.scfsi[channel][group] == 0 or granule == 0:
              for band in firstBand ..< endBand:
                result.data.scalefacL[granule][channel][band] =
                  result.bits.bits(count)
            else:
              for band in firstBand ..< endBand:
                result.data.scalefacL[granule][channel][band] =
                  result.data.scalefacL[0][channel][band]
        readHuffman(result.bits, header, sideInfo, result.data, part2Start,
          granule, channel)
