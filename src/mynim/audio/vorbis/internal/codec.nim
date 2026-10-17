## Vorbis decoding primitives and packet decoder, ported from
## github.com/jfreymuth/vorbis. Copyright (c) 2016 Johann Freymuth.
## Licensed under the MIT License.

import std/[algorithm, math]
import ./[bitreader, imdct, inverse_db_table]

type
  Bitrate* = object
    nominal*, minimum*, maximum*: int

  CommentHeader* = object
    vendor*: string
    comments*: seq[string]

  FloorKind = enum
    floor0Kind, floor1Kind

  Floor0 = object
    order: uint8
    rate, barkMapSize: uint16
    amplitudeBits, amplitudeOffset: uint8
    bookList: seq[uint8]

  Floor1Class = object
    dimension, subclass, masterbook: uint8
    subclassBooks: seq[uint8]

  Floor1 = object
    partitionClassList: seq[uint8]
    classes: seq[Floor1Class]
    multiplier, rangebits: uint8
    xList, sortList, finalY: seq[uint32]
    step2: seq[bool]

  Floor = object
    case kind: FloorKind
    of floor0Kind:
      f0: Floor0
    of floor1Kind:
      f1: Floor1

  FloorValue = object
    active: bool
    case kind: FloorKind
    of floor0Kind:
      amplitude: uint32
      coefficients: seq[float32]
    of floor1Kind:
      y: seq[uint32]

  FloorData = object
    floorIndex: int
    value: FloorValue
    noResidue: bool

  Residue = object
    residueType: uint16
    beginPosition, endPosition, partitionSize: uint32
    classifications, classbook: uint8
    cascade: seq[uint8]
    books: seq[array[8, int16]]

  MappingSubmap = object
    floor, residue: uint8

  Mapping = object
    couplingSteps: uint16
    angle, magnitude, mux: seq[uint8]
    submaps: seq[MappingSubmap]

  Mode = object
    blockflag, mapping: uint8

  HuffmanCode = seq[uint32]

  HuffmanBuilder = object
    code: HuffmanCode
    minLength: seq[uint8]

  Codebook = object
    dimensions: uint32
    entries: HuffmanCode
    values: seq[float32]

  VorbisDecoder* = ref object
    headerRead, setupRead: bool
    sampleRate, channels: int
    bitrate*: Bitrate
    blocksize: array[2, int]
    commentHeader*: CommentHeader
    codebooks: seq[Codebook]
    floors: seq[Floor]
    residues: seq[Residue]
    mappings: seq[Mapping]
    modes: seq[Mode]
    overlap: seq[float32]
    hasOverlap, overlapShort: bool
    windows: array[2, seq[float32]]
    lookup: array[2, ImdctLookup]
    residueBuffer, rawBuffer: seq[seq[float32]]
    floorBuffer: seq[FloorData]

const
  codebookPattern = 0x564342'u32
  headerTypeIdentification = 1
  headerTypeComment = 3
  headerTypeSetup = 5

proc newVorbisDecoder*(): VorbisDecoder = VorbisDecoder()

proc sampleRate*(decoder: VorbisDecoder): int = decoder.sampleRate

proc channels*(decoder: VorbisDecoder): int = decoder.channels

proc bufferSize*(decoder: VorbisDecoder): int =
  decoder.blocksize[1] div 2 * decoder.channels

proc headersRead(decoder: VorbisDecoder): bool =
  decoder.headerRead and decoder.setupRead

proc isHeader*(packet: openArray[byte]): bool =
  packet.len > 6 and (packet[0] and 1'u8) == 1'u8 and
    packet[1] == byte('v') and packet[2] == byte('o') and
    packet[3] == byte('r') and packet[4] == byte('b') and
    packet[5] == byte('i') and packet[6] == byte('s')

proc lookup(huffman: HuffmanCode; reader: var BitReader): uint32 =
  var index = 0'u32
  for _ in 0 ..< 33:
    let branch = reader.read1()
    if int(index + branch) >= huffman.len:
      raise newException(ValueError, "vorbis: invalid Huffman code")
    index = huffman[index + branch]
    if (index and 1) != 0:
      return index shr 1
  raise newException(ValueError, "vorbis: invalid Huffman code")

proc findEmpty(builder: var HuffmanBuilder; index: uint32): uint32 =
  result = index
  while result < uint32(builder.code.len) and builder.code[int(result)] != 0:
    result += 2
  if result >= uint32(builder.code.len):
    raise newException(ValueError, "vorbis: Huffman tree is too large")

proc put(builder: var HuffmanBuilder; index, entry: uint32;
    length: uint8): bool =
  let level = int(index div 2)
  if index + 1 >= uint32(builder.code.len) or level >= builder.minLength.len:
    raise newException(ValueError, "vorbis: invalid Huffman tree")
  if length < builder.minLength[level]:
    return false
  if length == 0:
    if builder.code[int(index)] == 0:
      builder.code[int(index)] = entry * 2 + 1
      return true
    if builder.code[int(index + 1)] == 0:
      builder.code[int(index + 1)] = entry * 2 + 1
      builder.minLength[level] = 1
      return true
    builder.minLength[level] = 1
    return false
  if (builder.code[int(index)] and 1) == 0:
    if builder.code[int(index)] == 0:
      builder.code[int(index)] = builder.findEmpty(index + 2)
    if builder.put(builder.code[int(index)], entry, length - 1):
      return true
  if (builder.code[int(index + 1)] and 1) == 0:
    if builder.code[int(index + 1)] == 0:
      builder.code[int(index + 1)] = builder.findEmpty(index + 2)
    if builder.put(builder.code[int(index + 1)], entry, length - 1):
      return true
  builder.minLength[level] = length + 1
  false

proc put(builder: var HuffmanBuilder; entry: uint32; length: uint8) =
  if length == 0:
    raise newException(ValueError, "vorbis: zero-length Huffman code")
  discard builder.put(0, entry, length - 1)

proc lookup1Values(entries: int; dimensions: uint32): int =
  int(floor(pow(float64(entries), 1.0 / float64(dimensions))))

proc float32Unpack(value: uint32): float32 =
  var mantissa = float64(value and 0x1F_FFFF'u32)
  if (value and 0x8000_0000'u32) != 0:
    mantissa = -mantissa
  let exponent = int((value and 0x7FE0_0000'u32) shr 21)
  float32(mantissa * pow(2.0, float64(exponent - 788)))

proc readFrom(book: var Codebook; reader: var BitReader) =
  if reader.read32(24) != codebookPattern:
    raise newException(ValueError, "vorbis: invalid codebook")
  book.dimensions = reader.read32(16)
  let numEntries = reader.read32(24)
  if numEntries == 0 or book.dimensions == 0 or
      numEntries > uint32(high(int) div 2):
    raise newException(ValueError, "vorbis: invalid codebook dimensions")
  var builder = HuffmanBuilder(
    code: newSeq[uint32](int(numEntries * 2 - 2)),
    minLength: newSeq[uint8](int(numEntries - 1)))
  if not reader.readBool():
    let sparse = reader.readBool()
    for i in 0'u32 ..< numEntries:
      if not sparse or reader.readBool():
        builder.put(i, reader.read8(5) + 1)
  else:
    var currentEntry = 0'u32
    var currentLength = reader.read8(5) + 1
    while currentEntry < numEntries:
      let count = reader.read32(ilog(int(numEntries - currentEntry)))
      if count == 0 or count > numEntries - currentEntry:
        raise newException(ValueError, "vorbis: invalid ordered codebook")
      for i in currentEntry ..< currentEntry + count:
        builder.put(i, currentLength)
      currentEntry += count
      inc currentLength
  book.entries = move(builder.code)

  let lookupType = reader.read8(4)
  if lookupType == 0:
    return
  if lookupType > 2:
    raise newException(ValueError, "vorbis: invalid codebook lookup type")
  let minimumValue = float32Unpack(reader.read32(32))
  let deltaValue = float32Unpack(reader.read32(32))
  let valueBits = int(reader.read8(4)) + 1
  let sequence = reader.readBool()
  var multiplicands: seq[uint32]
  if lookupType == 1:
    multiplicands = newSeq[uint32](lookup1Values(int(numEntries), book.dimensions))
  else:
    multiplicands = newSeq[uint32](int(numEntries * book.dimensions))
  for i in 0 ..< multiplicands.len:
    multiplicands[i] = reader.read32(valueBits)
  book.values = newSeq[float32](int(numEntries * book.dimensions))
  for entry in 0 ..< int(numEntries):
    let base = entry * int(book.dimensions)
    if lookupType == 1:
      var last = 0'f32
      var divisor = 1
      for i in 0 ..< int(book.dimensions):
        let offset = (entry div divisor) mod multiplicands.len
        book.values[base + i] = float32(multiplicands[offset]) * deltaValue +
          minimumValue + last
        if sequence:
          last = book.values[base + i]
        divisor *= multiplicands.len
    else:
      var last = 0'f32
      for i in 0 ..< int(book.dimensions):
        book.values[base + i] = float32(multiplicands[base + i]) *
          deltaValue + minimumValue + last
        if sequence:
          last = book.values[base + i]

proc decodeScalar(book: Codebook; reader: var BitReader): uint32 =
  book.entries.lookup(reader)

proc decodeVector(book: Codebook; reader: var BitReader): seq[float32] =
  let base = int(book.entries.lookup(reader) * book.dimensions)
  let finish = base + int(book.dimensions)
  if finish > book.values.len:
    raise newException(ValueError, "vorbis: codebook has no vector lookup")
  book.values[base ..< finish]

proc bytesToInt(data: openArray[byte]): int =
  if data.len > sizeof(int):
    raise newException(ValueError, "vorbis: integer field too large")
  for i in 0 ..< data.len:
    result = result or (int(data[i]) shl (i * 8))

proc readString(data: openArray[byte]; position: var int): string =
  if position > data.len - 4:
    raise newException(ValueError, "vorbis: truncated comment header")
  let size = bytesToInt(data[position ..< position + 4])
  position += 4
  if size < 0 or size > data.len - position:
    raise newException(ValueError, "vorbis: truncated comment header")
  result = newString(size)
  for i in 0 ..< size:
    result[i] = char(data[position + i])
  position += size

proc readIdentificationHeader(decoder: VorbisDecoder;
    header: openArray[byte]) =
  if header.len <= 22 or bytesToInt(header[0 ..< 4]) != 0:
    raise newException(ValueError, "vorbis: invalid identification header")
  decoder.channels = int(header[4])
  decoder.sampleRate = bytesToInt(header[5 ..< 9])
  decoder.bitrate.maximum = bytesToInt(header[9 ..< 13])
  decoder.bitrate.nominal = bytesToInt(header[13 ..< 17])
  decoder.bitrate.minimum = bytesToInt(header[17 ..< 21])
  decoder.blocksize[0] = 1 shl (int(header[21]) and 0x0F)
  decoder.blocksize[1] = 1 shl (int(header[21]) shr 4)
  if (header[22] and 1'u8) == 0 or decoder.channels == 0 or
      decoder.sampleRate <= 0 or decoder.blocksize[0] > decoder.blocksize[1]:
    raise newException(ValueError, "vorbis: invalid identification header")

proc readCommentHeader(decoder: VorbisDecoder; header: openArray[byte]) =
  var position = 0
  decoder.commentHeader.vendor = readString(header, position)
  if position > header.len - 4:
    raise newException(ValueError, "vorbis: truncated comment header")
  let count = bytesToInt(header[position ..< position + 4])
  position += 4
  if count < 0 or count > (header.len - position) div 4:
    raise newException(ValueError, "vorbis: invalid comment count")
  decoder.commentHeader.comments = newSeq[string](count)
  for i in 0 ..< count:
    decoder.commentHeader.comments[i] = readString(header, position)

proc readSetupHeader(decoder: VorbisDecoder; header: openArray[byte])

proc readHeader*(decoder: VorbisDecoder; packet: openArray[byte]) =
  if not packet.isHeader() or packet.len <= 7:
    raise newException(ValueError, "vorbis: invalid header")
  let headerType = packet[0]
  let header = packet[7 .. ^1]
  case headerType
  of headerTypeIdentification:
    decoder.readIdentificationHeader(header)
    decoder.headerRead = true
  of headerTypeComment:
    decoder.readCommentHeader(header)
  of headerTypeSetup:
    decoder.readSetupHeader(header)
    decoder.overlap = newSeq[float32](decoder.blocksize[1] * decoder.channels)
    decoder.setupRead = true
  else:
    raise newException(ValueError, "vorbis: unknown header type")

proc clear*(decoder: VorbisDecoder) = decoder.hasOverlap = false

proc bitrate*(decoder: VorbisDecoder): Bitrate = decoder.bitrate

proc commentHeader*(decoder: VorbisDecoder): CommentHeader = decoder.commentHeader

proc readFloor0(floor: var Floor0; reader: var BitReader) =
  floor.order = reader.read8(8)
  floor.rate = reader.read16(16)
  floor.barkMapSize = reader.read16(16)
  floor.amplitudeBits = reader.read8(6)
  floor.amplitudeOffset = reader.read8(8)
  floor.bookList = newSeq[uint8](int(reader.read8(4)) + 1)
  for i in 0 ..< floor.bookList.len:
    floor.bookList[i] = reader.read8(8)

proc readFloor1(floor: var Floor1; reader: var BitReader) =
  floor.partitionClassList = newSeq[uint8](int(reader.read8(5)))
  var maximumClass = 0'u8
  for i in 0 ..< floor.partitionClassList.len:
    let class = reader.read8(4)
    floor.partitionClassList[i] = class
    maximumClass = max(maximumClass, class)

  floor.classes = newSeq[Floor1Class](int(maximumClass) + 1)
  for i in 0 ..< floor.classes.len:
    var class = addr floor.classes[i]
    class.dimension = reader.read8(3) + 1
    class.subclass = reader.read8(2)
    if class.subclass != 0:
      class.masterbook = reader.read8(8)
    class.subclassBooks = newSeq[uint8](1 shl class.subclass)
    for j in 0 ..< class.subclassBooks.len:
      class.subclassBooks[j] = uint8((int(reader.read8(8)) - 1) and 0xFF)

  floor.multiplier = reader.read8(2) + 1
  floor.rangebits = reader.read8(4)
  floor.xList = @[0'u32, 1'u32 shl floor.rangebits]
  for classIndex in floor.partitionClassList:
    let dimension = floor.classes[int(classIndex)].dimension
    for _ in 0 ..< int(dimension):
      floor.xList.add reader.read32(int(floor.rangebits))

  floor.sortList = newSeq[uint32](floor.xList.len)
  for i in 0 ..< floor.sortList.len:
    floor.sortList[i] = uint32(i)
  let points = floor.xList
  sort(floor.sortList, proc(a, b: uint32): int =
    cmp(points[int(a)], points[int(b)]))
  floor.step2 = newSeq[bool](floor.xList.len)
  floor.finalY = newSeq[uint32](floor.xList.len)

proc decodeFloor(floor: Floor; reader: var BitReader;
    books: seq[Codebook]; n: uint32): FloorValue =
  case floor.kind
  of floor0Kind:
    let amplitude = reader.read32(int(floor.f0.amplitudeBits))
    result = FloorValue(kind: floor0Kind, active: amplitude != 0)
    if amplitude == 0:
      return
    let bookNumber = int(reader.read8(ilog(floor.f0.bookList.len)))
    if bookNumber >= floor.f0.bookList.len:
      raise newException(ValueError, "vorbis: invalid floor 0 codebook")
    let bookIndex = int(floor.f0.bookList[bookNumber])
    if bookIndex >= books.len:
      raise newException(ValueError, "vorbis: invalid floor 0 codebook")
    result.amplitude = amplitude
    result.coefficients = newSeq[float32](int(floor.f0.order))
    var i = 0
    var last = 0'f32
    while i < result.coefficients.len:
      let vector = books[bookIndex].decodeVector(reader)
      for coefficient in vector:
        result.coefficients[i] = coefficient + last
        inc i
        if i >= result.coefficients.len:
          return
      last = vector[^1]
  of floor1Kind:
    result = FloorValue(kind: floor1Kind, active: reader.readBool())
    if not result.active:
      return
    const floorRanges = [256'u32, 128'u32, 86'u32, 64'u32]
    let floorRange = floorRanges[int(floor.f1.multiplier) - 1]
    var y = newSeqOfCap[uint32](floor.f1.xList.len)
    let yBits = ilog(int(floorRange) - 1)
    y.add reader.read32(yBits)
    y.add reader.read32(yBits)
    for classIndex in floor.f1.partitionClassList:
      let class = floor.f1.classes[int(classIndex)]
      let classBits = int(class.subclass)
      let classMask = (1'u32 shl classBits) - 1
      var classValue = 0'u32
      if classBits > 0:
        let bookIndex = int(class.masterbook)
        if bookIndex >= books.len:
          raise newException(ValueError, "vorbis: invalid floor 1 masterbook")
        classValue = books[bookIndex].decodeScalar(reader)
      for _ in 0 ..< int(class.dimension):
        let bookIndex = int(class.subclassBooks[int(classValue and classMask)])
        classValue = classValue shr classBits
        if bookIndex != 0xFF:
          if bookIndex >= books.len:
            raise newException(ValueError, "vorbis: invalid floor 1 subclass book")
          y.add books[bookIndex].decodeScalar(reader)
        else:
          y.add 0
    result.y = move(y)
  discard n

proc lowNeighbor(points: seq[uint32]; index: int): int =
  let value = points[index]
  var maximum = 0'u32
  for i in 1 ..< index:
    if points[i] < value and points[i] > maximum:
      result = i
      maximum = points[i]

proc highNeighbor(points: seq[uint32]; index: int): int =
  let value = points[index]
  var minimum = high(uint32)
  for i in 1 ..< index:
    if points[i] > value and points[i] < minimum:
      result = i
      minimum = points[i]

proc renderPoint(x0, y0, x1, y1, x: uint32): uint32 =
  let difference = int(y1) - int(y0)
  let adx = x1 - x0
  let ady = uint32(abs(difference))
  let offset = ady * (x - x0) div adx
  if difference < 0: y0 - offset else: y0 + offset

proc renderLine(x0, y0, x1, y1: uint32; output: var seq[float32]) =
  let difference = int(y1) - int(y0)
  let adx = x1 - x0
  let ady = uint32(abs(difference))
  let base = difference div int(adx)
  var y = y0
  var error = 0'u32
  let stepY = if difference < 0: base - 1 else: base + 1
  var remainder = ady - uint32(abs(base)) * adx
  output[int(x0)] *= inverseDbTable[int(y)]
  for x in x0 + 1 ..< x1:
    error += remainder
    if error >= adx:
      error -= adx
      y = uint32(int(y) + stepY)
    else:
      y = uint32(int(y) + base)
    output[int(x)] *= inverseDbTable[int(y)]

proc bark(value: float64): float64 =
  13.1 * arctan(0.00074 * value) +
    2.24 * arctan(0.0000000185 * value * value) + 0.0001 * value

proc floor0MapResult(config: Floor0; i, n: uint32): int =
  if i >= n:
    return -1
  let value = bark(float64(config.rate) * float64(i) / 2 * float64(n)) *
    float64(config.barkMapSize) / bark(0.5 * float64(config.rate))
  result = int(math.floor(value))
  if result > int(config.barkMapSize) - 1:
    result = int(config.barkMapSize) - 1

proc applyFloor0(floor: Floor0; output: var seq[float32]; value: FloorValue) =
  let n = uint32(output.len)
  var i = 0'u32
  while i < n:
    let map = floor0MapResult(floor, i, n)
    let w = PI * float64(map) / float64(floor.barkMapSize)
    let cosW = cos(w)
    var p, q: float64
    if floor.order mod 2 == 1:
      p = 1 - cosW * cosW
      for j in 0 .. (int(floor.order) - 3) div 2:
        let temp = cos(float64(value.coefficients[2 * j + 1])) - cosW
        p *= 4 * temp * temp
      q = 0.25
      for j in 0 .. (int(floor.order) - 1) div 2:
        let temp = cos(float64(value.coefficients[2 * j])) - cosW
        q *= 4 * temp * temp
    else:
      p = (1 - cosW * cosW) / 2
      for j in 0 .. (int(floor.order) - 2) div 2:
        let temp = cos(float64(value.coefficients[2 * j + 1])) - cosW
        p *= 4 * temp * temp
      q = (1 + cosW * cosW) / 2
      for j in 0 .. (int(floor.order) - 2) div 2:
        let temp = cos(float64(value.coefficients[2 * j])) - cosW
        q *= 4 * temp * temp
    let denominator = float64((1'u64 shl floor.amplitudeBits) - 1)
    let linear = exp(0.11512925 *
      (float64(value.amplitude) * float64(floor.amplitudeOffset) /
      (denominator * sqrt(p + q)) - float64(floor.amplitudeOffset)))
    while i < n and floor0MapResult(floor, i, n) == map:
      output[int(i)] *= float32(linear)
      inc i

proc applyFloor1(floor: var Floor1; output: var seq[float32]; y: seq[uint32]) =
  const floorRanges = [256'u32, 128'u32, 86'u32, 64'u32]
  let floorRange = floorRanges[int(floor.multiplier) - 1]
  let n = uint32(output.len)
  floor.step2[0] = true
  floor.step2[1] = true
  floor.finalY[0] = y[0]
  floor.finalY[1] = y[1]
  for i in 2 ..< floor.xList.len:
    let low = lowNeighbor(floor.xList, i)
    let high = highNeighbor(floor.xList, i)
    let predicted = renderPoint(floor.xList[low], floor.finalY[low],
      floor.xList[high], floor.finalY[high], floor.xList[i])
    let value = y[i]
    let highRoom = floorRange - predicted
    let lowRoom = predicted
    let room = if highRoom < lowRoom: highRoom * 2 else: lowRoom * 2
    if value == 0:
      floor.step2[i] = false
      floor.finalY[i] = predicted
    else:
      floor.step2[low] = true
      floor.step2[high] = true
      floor.step2[i] = true
      if value >= room:
        if highRoom > lowRoom:
          floor.finalY[i] = value - lowRoom + predicted
        else:
          floor.finalY[i] = predicted - value + highRoom - 1
      elif (value and 1) != 0:
        floor.finalY[i] = predicted - (value + 1) div 2
      else:
        floor.finalY[i] = predicted + value div 2

  var hx, lx = 0'u32
  var ly = floor.finalY[0] * uint32(floor.multiplier)
  var hy = 0'u32
  for j in 1 ..< floor.finalY.len:
    let i = int(floor.sortList[j])
    if floor.step2[i]:
      hy = floor.finalY[i] * uint32(floor.multiplier)
      hx = floor.xList[i]
      renderLine(lx, ly, hx, hy, output)
      lx = hx
      ly = hy
  if hx < n:
    for i in hx ..< n:
      output[int(i)] *= inverseDbTable[int(hy)]

proc applyFloor(floor: var Floor; output: var seq[float32]; value: FloorValue) =
  if not value.active:
    for i in 0 ..< output.len:
      output[i] = 0
    return
  case floor.kind
  of floor0Kind:
    floor.f0.applyFloor0(output, value)
  of floor1Kind:
    floor.f1.applyFloor1(output, value.y)

proc readResidue(residue: var Residue; reader: var BitReader) =
  residue.residueType = reader.read16(16)
  if residue.residueType > 2:
    raise newException(ValueError, "vorbis: invalid residue type")
  residue.beginPosition = reader.read32(24)
  residue.endPosition = reader.read32(24)
  residue.partitionSize = reader.read32(24) + 1
  residue.classifications = reader.read8(6) + 1
  residue.classbook = reader.read8(8)
  residue.cascade = newSeq[uint8](int(residue.classifications))
  for i in 0 ..< residue.cascade.len:
    var highBits = 0'u8
    let lowBits = reader.read8(3)
    if reader.readBool():
      highBits = reader.read8(5)
    residue.cascade[i] = highBits * 8 + lowBits
  residue.books = newSeq[array[8, int16]](int(residue.classifications))
  for i in 0 ..< residue.books.len:
    for j in 0 ..< 8:
      if (residue.cascade[i] and (1'u8 shl j)) != 0:
        residue.books[i][j] = int16(reader.read8(8))
      else:
        residue.books[i][j] = -1

proc decode(residue: Residue; reader: var BitReader; doNotDecode: seq[bool];
    n: uint32; books: seq[Codebook]; output: var seq[seq[float32]]) =
  var channels = uint32(doNotDecode.len)
  var residueSize = n
  if residue.residueType == 2:
    var anyChannel = false
    for skip in doNotDecode:
      if not skip:
        anyChannel = true
        break
    if not anyChannel:
      return
    residueSize *= channels
    channels = 1
  let beginPosition = min(residue.beginPosition, residueSize)
  let endPosition = min(residue.endPosition, residueSize)
  let amount = endPosition - beginPosition
  let partitionsToRead = amount div residue.partitionSize
  if amount == 0 or residue.partitionSize == 0:
    return
  let classbookIndex = int(residue.classbook)
  if classbookIndex >= books.len:
    raise newException(ValueError, "vorbis: invalid residue classbook")
  let classbook = books[classbookIndex]
  let classWords = classbook.dimensions
  let classStride = int(partitionsToRead + classWords)
  var classifications = newSeq[uint32](int(channels) * classStride)
  for pass in 0 ..< 8:
    var partitionCount = 0'u32
    while partitionCount < partitionsToRead:
      if pass == 0:
        for channel in 0 ..< int(channels):
          if not doNotDecode[channel]:
            var value = classbook.decodeScalar(reader)
            for i in countdown(int(classWords) - 1, 0):
              classifications[channel * classStride + i +
                int(partitionCount)] = value mod uint32(residue.classifications)
              value = value div uint32(residue.classifications)
      for _ in 0 ..< int(classWords):
        if partitionCount >= partitionsToRead:
          break
        for channel in 0 ..< int(channels):
          if not doNotDecode[channel]:
            let vqClass = classifications[channel * classStride +
              int(partitionCount)]
            let bookNumber = residue.books[int(vqClass)][pass]
            if bookNumber != -1:
              let bookIndex = int(bookNumber)
              if bookIndex >= books.len:
                raise newException(ValueError, "vorbis: invalid residue book")
              let book = books[bookIndex]
              let offset = beginPosition + partitionCount * residue.partitionSize
              case residue.residueType
              of 0:
                let step = residue.partitionSize div book.dimensions
                for i in 0 ..< step:
                  let vector = book.decodeVector(reader)
                  for k in 0 ..< vector.len:
                    output[channel][int(offset + i + uint32(k) * step)] +=
                      vector[k]
              of 1:
                var i = 0'u32
                while i < residue.partitionSize:
                  let vector = book.decodeVector(reader)
                  for value in vector:
                    if i < residue.partitionSize:
                      output[channel][int(offset + i)] += value
                      inc i
              of 2:
                var i = 0'u32
                let outputChannels = uint32(output.len)
                while i < residue.partitionSize:
                  let vector = book.decodeVector(reader)
                  for value in vector:
                    if i < residue.partitionSize:
                      output[int((offset + i) mod outputChannels)][
                        int((offset + i) div outputChannels)] += value
                      inc i
              else:
                discard
        inc partitionCount

proc initLookup(decoder: VorbisDecoder) =
  decoder.windows[0] = makeWindow(decoder.blocksize[0])
  decoder.windows[1] = makeWindow(decoder.blocksize[1])
  decoder.lookup[0] = generateImdctLookup(decoder.blocksize[0])
  decoder.lookup[1] = generateImdctLookup(decoder.blocksize[1])
  decoder.residueBuffer = newSeq[seq[float32]](decoder.channels)
  decoder.rawBuffer = newSeq[seq[float32]](decoder.channels)
  for channel in 0 ..< decoder.channels:
    decoder.residueBuffer[channel] = newSeq[float32](decoder.blocksize[1] div 2)
    decoder.rawBuffer[channel] = newSeq[float32](decoder.blocksize[1])

proc readSetupHeader(decoder: VorbisDecoder; header: openArray[byte]) =
  var reader = initBitReader(header)

  decoder.codebooks = newSeq[Codebook](int(reader.read16(8)) + 1)
  for i in 0 ..< decoder.codebooks.len:
    decoder.codebooks[i].readFrom(reader)

  let transformCount = int(reader.read8(6)) + 1
  for _ in 0 ..< transformCount:
    if reader.read16(16) != 0:
      raise newException(ValueError, "vorbis: invalid time transform")

  decoder.floors = newSeq[Floor](int(reader.read8(6)) + 1)
  for i in 0 ..< decoder.floors.len:
    case reader.read16(16)
    of 0:
      decoder.floors[i] = Floor(kind: floor0Kind, f0: Floor0())
      decoder.floors[i].f0.readFloor0(reader)
    of 1:
      decoder.floors[i] = Floor(kind: floor1Kind, f1: Floor1())
      decoder.floors[i].f1.readFloor1(reader)
    else:
      raise newException(ValueError, "vorbis: invalid floor type")

  decoder.residues = newSeq[Residue](int(reader.read8(6)) + 1)
  for i in 0 ..< decoder.residues.len:
    decoder.residues[i].readResidue(reader)

  decoder.mappings = newSeq[Mapping](int(reader.read8(6)) + 1)
  for i in 0 ..< decoder.mappings.len:
    var mapping = addr decoder.mappings[i]
    if reader.read16(16) != 0:
      raise newException(ValueError, "vorbis: invalid mapping type")
    if reader.readBool():
      mapping.submaps = newSeq[MappingSubmap](int(reader.read8(4)) + 1)
    else:
      mapping.submaps = newSeq[MappingSubmap](1)
    if reader.readBool():
      mapping.couplingSteps = reader.read16(8) + 1
      mapping.magnitude = newSeq[uint8](int(mapping.couplingSteps))
      mapping.angle = newSeq[uint8](int(mapping.couplingSteps))
      let channelBits = ilog(decoder.channels - 1)
      for j in 0 ..< mapping.magnitude.len:
        mapping.magnitude[j] = reader.read8(channelBits)
        mapping.angle[j] = reader.read8(channelBits)
    if reader.read8(2) != 0:
      raise newException(ValueError, "vorbis: invalid mapping reserved bits")
    mapping.mux = newSeq[uint8](decoder.channels)
    if mapping.submaps.len > 1:
      for channel in 0 ..< mapping.mux.len:
        mapping.mux[channel] = reader.read8(4)
    for j in 0 ..< mapping.submaps.len:
      discard reader.read8(8)
      mapping.submaps[j].floor = reader.read8(8)
      mapping.submaps[j].residue = reader.read8(8)

  decoder.modes = newSeq[Mode](int(reader.read8(6)) + 1)
  for i in 0 ..< decoder.modes.len:
    var mode = addr decoder.modes[i]
    mode.blockflag = reader.read8(1)
    if reader.read16(16) != 0 or reader.read16(16) != 0:
      raise newException(ValueError, "vorbis: invalid mode transform")
    mode.mapping = reader.read8(8)
  if not reader.readBool():
    raise newException(ValueError, "vorbis: missing setup framing bit")
  decoder.initLookup()

proc decodeFloors(decoder: VorbisDecoder; reader: var BitReader;
    floors: var seq[FloorData]; mapping: Mapping; spectrumSize: uint32) =
  for channel in 0 ..< floors.len:
    let submapIndex = int(mapping.mux[channel])
    if submapIndex >= mapping.submaps.len:
      raise newException(ValueError, "vorbis: invalid mapping submap")
    let floorIndex = int(mapping.submaps[submapIndex].floor)
    if floorIndex >= decoder.floors.len:
      raise newException(ValueError, "vorbis: invalid floor index")
    let value = decoder.floors[floorIndex].decodeFloor(reader,
      decoder.codebooks, spectrumSize)
    floors[channel] = FloorData(floorIndex: floorIndex, value: value,
      noResidue: not value.active)

  for i in 0 ..< int(mapping.couplingSteps):
    let magnitude = int(mapping.magnitude[i])
    let angle = int(mapping.angle[i])
    if not floors[magnitude].noResidue or not floors[angle].noResidue:
      floors[magnitude].noResidue = false
      floors[angle].noResidue = false

proc decodeResidue(decoder: VorbisDecoder; reader: var BitReader;
    output: var seq[seq[float32]]; mapping: Mapping;
    floors: seq[FloorData]; spectrumSize: uint32) =
  for submapIndex in 0 ..< mapping.submaps.len:
    var doNotDecode: seq[bool]
    var submapOutput: seq[seq[float32]]
    var channelIndices: seq[int]
    for channel in 0 ..< decoder.channels:
      if mapping.mux[channel] == uint8(submapIndex):
        doNotDecode.add floors[channel].noResidue
        submapOutput.add output[channel]
        channelIndices.add channel
    let residueIndex = int(mapping.submaps[submapIndex].residue)
    if residueIndex >= decoder.residues.len:
      raise newException(ValueError, "vorbis: invalid residue index")
    decoder.residues[residueIndex].decode(reader, doNotDecode, spectrumSize,
      decoder.codebooks, submapOutput)
    for i, channel in channelIndices:
      output[channel] = move(submapOutput[i])

proc inverseCoupling(mapping: Mapping; vectors: var seq[seq[float32]]) =
  for step in countdown(int(mapping.couplingSteps) - 1, 0):
    let magnitudeVector = int(mapping.magnitude[step])
    let angleVector = int(mapping.angle[step])
    for j in 0 ..< vectors[magnitudeVector].len:
      var magnitude = vectors[magnitudeVector][j]
      var angle = vectors[angleVector][j]
      if magnitude > 0:
        if angle > 0:
          angle = magnitude - angle
        else:
          let previousMagnitude = magnitude
          magnitude = magnitude + angle
          angle = previousMagnitude
      else:
        if angle > 0:
          let previousMagnitude = magnitude
          magnitude = magnitude + angle
          angle = previousMagnitude
        else:
          angle = magnitude - angle
      vectors[magnitudeVector][j] = magnitude
      vectors[angleVector][j] = angle

proc applyFloors(decoder: VorbisDecoder; vectors: var seq[seq[float32]];
    floors: seq[FloorData]) =
  for channel in 0 ..< vectors.len:
    if floors[channel].value.active:
      var floor = decoder.floors[floors[channel].floorIndex]
      floor.applyFloor(vectors[channel], floors[channel].value)
    else:
      for i in 0 ..< vectors[channel].len:
        vectors[channel][i] = 0

proc decodePacket(decoder: VorbisDecoder; packet: openArray[byte];
    output: var seq[float32]): int =
  if not decoder.headersRead():
    raise newException(ValueError, "vorbis: missing headers")
  var reader = initBitReader(packet)
  if reader.readBool():
    raise newException(ValueError, "vorbis: decoding error")
  let modeNumber = int(reader.read8(ilog(decoder.modes.len - 1)))
  if modeNumber >= decoder.modes.len:
    raise newException(ValueError, "vorbis: invalid mode number")
  let mode = decoder.modes[modeNumber]
  let blockType = int(mode.blockflag)
  let longWindow = blockType == 1
  let blocksize = decoder.blocksize[blockType]
  let spectrumSize = uint32(blocksize div 2)
  var windowPrev = false
  var windowNext = false
  var window = WindowType(size: blocksize, prev: blocksize, next: blocksize)
  if longWindow:
    windowPrev = reader.readBool()
    windowNext = reader.readBool()
    if not windowPrev:
      window.prev = decoder.blocksize[0]
    if not windowNext:
      window.next = decoder.blocksize[0]

  let mappingIndex = int(mode.mapping)
  if mappingIndex >= decoder.mappings.len:
    raise newException(ValueError, "vorbis: invalid mapping index")
  let mapping = decoder.mappings[mappingIndex]
  if decoder.floorBuffer.len == 0:
    decoder.floorBuffer = newSeq[FloorData](decoder.channels)
  for channel in 0 ..< decoder.channels:
    decoder.residueBuffer[channel].setLen(int(spectrumSize))
    for i in 0 ..< int(spectrumSize):
      decoder.residueBuffer[channel][i] = 0

  decoder.decodeFloors(reader, decoder.floorBuffer, mapping, spectrumSize)
  decoder.decodeResidue(reader, decoder.residueBuffer, mapping,
    decoder.floorBuffer, spectrumSize)
  inverseCoupling(mapping, decoder.residueBuffer)
  decoder.applyFloors(decoder.residueBuffer, decoder.floorBuffer)

  for channel in 0 ..< decoder.channels:
    decoder.rawBuffer[channel].setLen(blocksize)
    decoder.lookup[blockType].imdct(decoder.residueBuffer[channel],
      decoder.rawBuffer[channel])
  applyWindow(decoder.windows, decoder.blocksize[1], window,
    decoder.rawBuffer)

  let center = blocksize div 2
  let offset = decoder.blocksize[1] div 4 - decoder.blocksize[0] div 4
  var sampleCount = 0
  if decoder.hasOverlap:
    sampleCount = center
    if longWindow and not windowPrev:
      sampleCount -= offset
    if not longWindow and not decoder.overlapShort:
      sampleCount += offset
    if output.len < sampleCount * decoder.channels:
      raise newException(ValueError, "vorbis: output buffer too short")
  if longWindow:
    let start = if windowPrev: 0 else: offset
    if decoder.hasOverlap:
      for channel in 0 ..< decoder.channels:
        for i in 0 ..< center - start:
          output[i * decoder.channels + channel] =
            decoder.rawBuffer[channel][start + i] +
            decoder.overlap[(start + i) * decoder.channels + channel]
    decoder.overlapShort = false
  else:
    if decoder.hasOverlap:
      if decoder.overlapShort:
        for channel in 0 ..< decoder.channels:
          for i in 0 ..< center:
            output[i * decoder.channels + channel] =
              decoder.rawBuffer[channel][i] +
              decoder.overlap[(offset + i) * decoder.channels + channel]
      else:
        for i in 0 ..< offset * decoder.channels:
          output[i] = decoder.overlap[i]
        for channel in 0 ..< decoder.channels:
          for i in offset ..< offset + center:
            output[i * decoder.channels + channel] =
              decoder.rawBuffer[channel][i - offset] +
              decoder.overlap[i * decoder.channels + channel]
    decoder.overlapShort = true

  if not decoder.hasOverlap:
    sampleCount = 0
  let overlapCenter = decoder.blocksize[1] div 4
  let overlapStart = overlapCenter - center div 2
  let overlapEnd = overlapCenter + center div 2
  for i in 0 ..< overlapStart * decoder.channels:
    decoder.overlap[i] = 0
  for channel in 0 ..< decoder.channels:
    for i in overlapStart ..< overlapEnd:
      decoder.overlap[i * decoder.channels + channel] =
        decoder.rawBuffer[channel][center + i - overlapStart]
  for i in overlapEnd * decoder.channels ..< decoder.overlap.len:
    decoder.overlap[i] = 0
  decoder.hasOverlap = true
  result = sampleCount * decoder.channels

proc decodeInto*(decoder: VorbisDecoder; packet: openArray[byte];
    output: var seq[float32]): int =
  result = decoder.decodePacket(packet, output)
  for i in 0 ..< result:
    if output[i] > 1:
      output[i] = 1
    elif output[i] < -1:
      output[i] = -1
