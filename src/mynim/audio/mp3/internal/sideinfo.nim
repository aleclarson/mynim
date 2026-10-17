## Layer III side-information parsing from github.com/hajimehoshi/go-mp3.
## Copyright 2017 Hajime Hoshi. Licensed under Apache-2.0.

import ./[bits, consts, frameheader, source]

type SideInfo* = object
  mainDataBegin*: int
  privateBits*: int
  scfsi*: array[2, array[4, int]]
  part23Length*: array[2, array[2, int]]
  bigValues*: array[2, array[2, int]]
  globalGain*: array[2, array[2, int]]
  scalefacCompress*: array[2, array[2, int]]
  winSwitchFlag*: array[2, array[2, int]]
  blockType*: array[2, array[2, int]]
  mixedBlockFlag*: array[2, array[2, int]]
  tableSelect*: array[2, array[2, array[3, int]]]
  subblockGain*: array[2, array[2, array[3, int]]]
  region0Count*: array[2, array[2, int]]
  region1Count*: array[2, array[2, int]]
  preflag*: array[2, array[2, int]]
  scalefacScale*: array[2, array[2, int]]
  count1TableSelect*: array[2, array[2, int]]
  count1*: array[2, array[2, int]]
  mainDataSize*: int

const sideInfoBitsToRead = [
  [9, 5, 3, 4], # MPEG-1
  [8, 1, 2, 9]] # MPEG-2 and MPEG-2.5

proc readSideInfo*(source: Mp3Source; header: FrameHeader): SideInfo =
  let channelCount = header.numberOfChannels()
  let frameSize = header.frameSize()
  if frameSize > 2_000:
    raise newException(ValueError, "mp3: frame size exceeds 2000 bytes")
  let sideInfoSize = header.sideInfoSize()
  result.mainDataSize = frameSize - sideInfoSize - 4
  if header.protectionBit() == 0:
    result.mainDataSize -= 2

  var buffer = newSeq[byte](sideInfoSize)
  try:
    discard source.readFull(buffer)
  except Mp3EofError:
    raise newException(UnexpectedMp3EofError,
      "mp3: unexpected EOF at sideinfo.Read")
  var bits = initBits(move(buffer))

  let mpeg1Frame = header.lowSamplingFrequency() == 0
  let counts = sideInfoBitsToRead[header.lowSamplingFrequency()]
  result.mainDataBegin = bits.bits(counts[0])
  if header.mode() == modeSingleChannel:
    result.privateBits = bits.bits(counts[1])
  else:
    result.privateBits = bits.bits(counts[2])

  if mpeg1Frame:
    for channel in 0 ..< channelCount:
      for band in 0 ..< 4:
        result.scfsi[channel][band] = bits.bits(1)

  for granule in 0 ..< header.granules():
    for channel in 0 ..< channelCount:
      result.part23Length[granule][channel] = bits.bits(12)
      result.bigValues[granule][channel] = bits.bits(9)
      result.globalGain[granule][channel] = bits.bits(8)
      result.scalefacCompress[granule][channel] = bits.bits(counts[3])
      result.winSwitchFlag[granule][channel] = bits.bits(1)
      if result.winSwitchFlag[granule][channel] == 1:
        result.blockType[granule][channel] = bits.bits(2)
        result.mixedBlockFlag[granule][channel] = bits.bits(1)
        for region in 0 ..< 2:
          result.tableSelect[granule][channel][region] = bits.bits(5)
        for window in 0 ..< 3:
          result.subblockGain[granule][channel][window] = bits.bits(3)
        if result.blockType[granule][channel] == 2 and
            result.mixedBlockFlag[granule][channel] == 0:
          result.region0Count[granule][channel] = 8
        else:
          result.region0Count[granule][channel] = 7
        result.region1Count[granule][channel] =
          20 - result.region0Count[granule][channel]
      else:
        for region in 0 ..< 3:
          result.tableSelect[granule][channel][region] = bits.bits(5)
        result.region0Count[granule][channel] = bits.bits(4)
        result.region1Count[granule][channel] = bits.bits(3)
        result.blockType[granule][channel] = 0
        if not mpeg1Frame:
          result.mixedBlockFlag[0][channel] = 0
      if mpeg1Frame:
        result.preflag[granule][channel] = bits.bits(1)
      result.scalefacScale[granule][channel] = bits.bits(1)
      result.count1TableSelect[granule][channel] = bits.bits(1)
