## Ogg page and packet reader, ported from github.com/jfreymuth/oggvorbis.
## Copyright (c) 2016 Johann Freymuth. Licensed under the MIT License.

import std/streams

type
  OggEofError = object of CatchableError
  OggUnexpectedEofError = object of CatchableError

  OggPageHeader = object
    capturePattern: array[4, byte]
    streamVersion, headerType: uint8
    granulePosition: int64
    serialNumber, pageSequence, checksum: uint32
    segmentCount: uint8

  OggPage = object
    header: OggPageHeader
    headerChecksum: uint32
    packetCount, totalSize: int
    packetSizes: seq[int]
    packets: seq[seq[byte]]

  OggPageReader* = ref object
    stream: Stream
    basePosition: int
    position: int64
    buffer: seq[byte]
    currentPage: OggPage
    packetIndex: int
    ready, lastPacket: bool
    lastPagePosition: int64

const
  capturePattern = [byte('O'), byte('g'), byte('g'), byte('S')]
  headerFlagContinuedPacket = 1'u8
  headerFlagEndOfStream = 4'u8

proc initCrcTable(): array[256, uint32] =
  for i in 0 ..< result.len:
    var value = uint32(i) shl 24
    for _ in 0 ..< 8:
      if (value and 0x8000_0000'u32) != 0:
        value = (value shl 1) xor 0x04C1_1DB7'u32
      else:
        value = value shl 1
    result[i] = value

let crcTable = initCrcTable()

proc crcUpdate(crc: uint32; data: openArray[byte]): uint32 =
  result = crc
  for value in data:
    let index = int(byte((result shr 24) xor uint32(value)))
    result = (result shl 8) xor crcTable[index]

proc seek*(reader: OggPageReader; position: int64) =
  if position < 0 or position > int64(high(int) - reader.basePosition):
    raise newException(ValueError, "ogg: seek out of range")
  reader.stream.setPosition(reader.basePosition + int(position))
  reader.position = position
  reader.buffer.setLen(0)

proc readExact(reader: OggPageReader; output: var openArray[byte];
    allowEofAtStart = false) =
  var read = 0
  while read < output.len:
    let count = reader.stream.readData(addr output[read], output.len - read)
    if count <= 0:
      if read == 0 and allowEofAtStart:
        raise newException(OggEofError, "ogg: end of stream")
      raise newException(OggUnexpectedEofError, "ogg: truncated page")
    read += count
    reader.position += int64(count)

proc readExact(reader: OggPageReader; count: int): seq[byte] =
  result = newSeq[byte](count)
  reader.readExact(result)

proc readUint32(data: openArray[byte]; offset: int): uint32 =
  uint32(data[offset]) or (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or (uint32(data[offset + 3]) shl 24)

proc readUint64(data: openArray[byte]; offset: int): uint64 =
  uint64(readUint32(data, offset)) or (uint64(readUint32(data, offset + 4)) shl 32)

proc readPageHeader(page: var OggPage; reader: OggPageReader;
    allowEofAtStart = false) =
  var data = newSeq[byte](27)
  reader.readExact(data, allowEofAtStart)
  page.header.capturePattern = [data[0], data[1], data[2], data[3]]
  if page.header.capturePattern != capturePattern:
    raise newException(ValueError, "ogg: missing capture pattern")
  page.header.streamVersion = data[4]
  if page.header.streamVersion != 0:
    raise newException(ValueError, "ogg: unsupported version")
  page.header.headerType = data[5]
  page.header.granulePosition = cast[int64](readUint64(data, 6))
  page.header.serialNumber = readUint32(data, 14)
  page.header.pageSequence = readUint32(data, 18)
  page.header.checksum = readUint32(data, 22)
  page.header.segmentCount = data[26]
  let segmentTable = reader.readExact(int(page.header.segmentCount))
  for i in 22 ..< 26:
    data[i] = 0
  page.headerChecksum = crcUpdate(0, data)
  page.headerChecksum = crcUpdate(page.headerChecksum, segmentTable)

  var partialSize = 0
  page.totalSize = 0
  page.packetCount = 0
  page.packetSizes.setLen(0)
  for segment in segmentTable:
    partialSize += int(segment)
    page.totalSize += int(segment)
    if segment < 0xFF:
      inc page.packetCount
      page.packetSizes.add partialSize
      partialSize = 0

proc readPageContent(page: var OggPage; reader: OggPageReader) =
  let content = reader.readExact(page.totalSize)
  if crcUpdate(page.headerChecksum, content) != page.header.checksum:
    raise newException(ValueError, "ogg: wrong checksum")
  page.packets = newSeq[seq[byte]](page.packetCount + 1)
  var offset = 0
  for i, size in page.packetSizes:
    page.packets[i] = content[offset ..< offset + size]
    offset += size
  page.packets[page.packetCount] = content[offset .. ^1]

proc readPage(page: var OggPage; reader: OggPageReader;
    allowEofAtStart = false) =
  page.readPageHeader(reader, allowEofAtStart)
  page.readPageContent(reader)

proc newOggPageReader*(stream: Stream): OggPageReader =
  if stream.isNil:
    raise newException(ValueError, "ogg: nil stream")
  result = OggPageReader(stream: stream, basePosition: stream.getPosition())
  if result.basePosition < 0:
    raise newException(ValueError, "ogg: source must be seekable")

proc nextPacket*(reader: OggPageReader): seq[byte] =
  while true:
    if not reader.ready:
      reader.currentPage.readPage(reader, allowEofAtStart = true)
      reader.packetIndex = 0
      if (reader.currentPage.header.headerType and
          headerFlagContinuedPacket) != 0:
        reader.packetIndex = 1
      reader.ready = true

    if reader.packetIndex == reader.currentPage.packetCount:
      let rest = reader.currentPage.packets[reader.currentPage.packetCount]
      if reader.currentPage.header.granulePosition != -1:
        reader.lastPagePosition = reader.currentPage.header.granulePosition
      reader.currentPage.readPage(reader, allowEofAtStart = true)
      if rest.len > 0:
        var joined = newSeqOfCap[byte](rest.len +
          reader.currentPage.packets[0].len)
        joined.add rest
        joined.add reader.currentPage.packets[0]
        reader.currentPage.packets[0] = move(joined)
      reader.packetIndex = 0
    else:
      result = reader.currentPage.packets[reader.packetIndex]
      inc reader.packetIndex
      if reader.packetIndex == reader.currentPage.packetCount and
          (reader.currentPage.header.headerType and headerFlagEndOfStream) != 0:
        reader.lastPacket = true
      return

proc length*(reader: OggPageReader): int64 =
  let savedPosition = reader.position
  reader.seek(0)
  var lastPosition = -1'i64
  var isLast = false
  while not isLast:
    var page: OggPage
    try:
      page.readPage(reader, allowEofAtStart = true)
    except OggEofError:
      break
    if page.header.granulePosition >= 0:
      lastPosition = page.header.granulePosition
    isLast = (page.header.headerType and headerFlagEndOfStream) != 0
  reader.seek(savedPosition)
  if isLast: lastPosition else: -1

proc seekPageBefore*(reader: OggPageReader; position: int64): int64 =
  reader.seek(0)
  reader.lastPacket = false
  var previousOffset = 0'i64
  var previousPosition = 0'i64
  while true:
    let pageOffset = reader.position
    var page: OggPage
    page.readPageHeader(reader)
    if page.header.granulePosition > position:
      reader.seek(previousOffset)
      reader.currentPage.readPage(reader)
      if previousPosition > 0 and reader.currentPage.packetCount > 0:
        reader.packetIndex = reader.currentPage.packetCount - 1
        reader.ready = true
      else:
        reader.packetIndex = 0
        reader.ready = false
      return previousPosition
    page.readPageContent(reader)
    if (page.header.headerType and headerFlagEndOfStream) != 0:
      raise newException(IOError, "ogg: seek position is past the end")
    previousOffset = pageOffset
    previousPosition = page.header.granulePosition

proc isLastPacket*(reader: OggPageReader): bool = reader.lastPacket

proc markEnd*(reader: OggPageReader) = reader.lastPacket = true

proc atPageEnd*(reader: OggPageReader): bool =
  reader.packetIndex == reader.currentPage.packetCount

proc currentGranulePosition*(reader: OggPageReader): int64 =
  reader.currentPage.header.granulePosition
