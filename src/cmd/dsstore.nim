## Write the Finder layout records embedded in a macOS disk image.

import std/[algorithm, strutils, tables, unicode]

type
  DsRecord = object
    name, code, kind: string
    value: seq[byte]

  PlistKind = enum
    plistBool, plistInt, plistFloat, plistString

  PlistAtom = object
    kind: PlistKind
    boolValue: bool
    intValue: int64
    floatValue: float64
    stringValue: string

  PlistObject = object
    isDictionary: bool
    atom: PlistAtom
    keys, keyRefs, valueRefs: seq[int]

proc plistBool(value: bool): PlistAtom =
  PlistAtom(kind: plistBool, boolValue: value)

proc plistInt(value: int64): PlistAtom =
  PlistAtom(kind: plistInt, intValue: value)

proc plistFloat(value: float64): PlistAtom =
  PlistAtom(kind: plistFloat, floatValue: value)

proc plistString(value: string): PlistAtom =
  PlistAtom(kind: plistString, stringValue: value)

proc atomEqual(a, b: PlistAtom): bool =
  if a.kind != b.kind: return false
  case a.kind
  of plistBool: a.boolValue == b.boolValue
  of plistInt: a.intValue == b.intValue
  of plistFloat: a.floatValue == b.floatValue
  of plistString: a.stringValue == b.stringValue

proc utf16Units(value: string): seq[uint16] =
  for rune in value.runes:
    let scalar = ord(rune)
    if scalar < 0x10000:
      result.add uint16(scalar)
    else:
      let value = scalar - 0x10000
      result.add uint16(0xd800 + (value shr 10))
      result.add uint16(0xdc00 + (value and 0x3ff))

proc appendByte(data: var seq[byte]; value: int) {.inline.} =
  data.add byte(value and 0xff)

proc appendUint(data: var seq[byte]; value: uint64; width: int) =
  for shift in countdown((width - 1) * 8, 0, 8):
    data.appendByte(int((value shr shift) and 0xff))

proc putUint(data: var seq[byte]; offset: int; value: uint32) =
  data[offset] = byte((value shr 24) and 0xff)
  data[offset + 1] = byte((value shr 16) and 0xff)
  data[offset + 2] = byte((value shr 8) and 0xff)
  data[offset + 3] = byte(value and 0xff)

proc sizeOf(value: int): int =
  if value < 1 shl 8: 1
  elif value < 1 shl 16: 2
  elif value < 1'i64 shl 32: 4
  else: 8

proc appendInt(data: var seq[byte]; value: int64) =
  if value < 0:
    data.appendByte(0x13)
    data.appendUint(cast[uint64](value), 8)
  elif value < 1'i64 shl 8:
    data.appendByte(0x10)
    data.appendUint(uint64(value), 1)
  elif value < 1'i64 shl 16:
    data.appendByte(0x11)
    data.appendUint(uint64(value), 2)
  elif value < 1'i64 shl 32:
    data.appendByte(0x12)
    data.appendUint(uint64(value), 4)
  else:
    data.appendByte(0x13)
    data.appendUint(uint64(value), 8)

proc appendSize(data: var seq[byte]; marker, count: int) =
  if count < 15:
    data.appendByte(marker or count)
  else:
    data.appendByte(marker or 0x0f)
    data.appendInt(int64(count))

proc isAscii(value: string): bool =
  for ch in value:
    if ord(ch) >= 0x80: return false
  true

proc atomRef(objects: var seq[PlistObject]; atom: PlistAtom): int =
  for index in 1..<objects.len:
    if not objects[index].isDictionary and atomEqual(objects[index].atom, atom):
      return index
  result = objects.len
  objects.add PlistObject(atom: atom)

proc binaryPlist(dict: Table[string, PlistAtom]): seq[byte] =
  var names: seq[string]
  for name in dict.keys: names.add name
  names.sort()

  var objects = @[PlistObject(isDictionary: true)]
  var keyRefs, valueRefs: seq[int]
  for name in names:
    keyRefs.add atomRef(objects, plistString(name))
  for name in names:
    valueRefs.add atomRef(objects, dict[name])
  objects[0].keyRefs = keyRefs
  objects[0].valueRefs = valueRefs

  var data: seq[byte] = @[byte('b'), byte('p'), byte('l'), byte('i'),
                          byte('s'), byte('t'), byte('0'), byte('0')]
  var offsets: seq[int]
  let referenceWidth = sizeOf(objects.len)
  for item in objects:
    offsets.add data.len
    if item.isDictionary:
      data.appendSize(0xd0, item.keyRefs.len)
      for reference in item.keyRefs:
        data.appendUint(uint64(reference), referenceWidth)
      for reference in item.valueRefs:
        data.appendUint(uint64(reference), referenceWidth)
      continue
    case item.atom.kind
    of plistBool:
      data.appendByte(if item.atom.boolValue: 0x09 else: 0x08)
    of plistInt:
      data.appendInt(item.atom.intValue)
    of plistFloat:
      data.appendByte(0x23)
      data.appendUint(cast[uint64](item.atom.floatValue), 8)
    of plistString:
      if isAscii(item.atom.stringValue):
        data.appendSize(0x50, item.atom.stringValue.len)
        for ch in item.atom.stringValue: data.appendByte(ord(ch))
      else:
        let units = utf16Units(item.atom.stringValue)
        data.appendSize(0x60, units.len)
        for unit in units: data.appendUint(uint64(unit), 2)

  let offsetTable = data.len
  let offsetWidth = sizeOf(offsetTable)
  for offset in offsets:
    data.appendUint(uint64(offset), offsetWidth)
  for _ in 0..<6: data.appendByte(0)
  data.appendByte(offsetWidth)
  data.appendByte(referenceWidth)
  data.appendUint(uint64(objects.len), 8)
  data.appendUint(0, 8)
  data.appendUint(uint64(offsetTable), 8)
  data

proc dsLong(name, code: string; value: uint32): DsRecord =
  result = DsRecord(name: name, code: code, kind: "long")
  result.value.appendUint(uint64(value), 4)

proc dsBlob(name, code: string; value: seq[byte]): DsRecord =
  DsRecord(name: name, code: code, kind: "blob", value: value)

proc dsIconLocation(name: string; x, y: int): DsRecord =
  result = DsRecord(name: name, code: "Iloc", kind: "blob")
  result.value.appendUint(uint64(uint32(x)), 4)
  result.value.appendUint(uint64(uint32(y)), 4)
  result.value.add @[byte 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0]

proc encode(record: DsRecord; data: var seq[byte]) =
  let name = utf16Units(record.name)
  data.appendUint(uint64(name.len), 4)
  for unit in name: data.appendUint(uint64(unit), 2)
  for ch in record.code: data.appendByte(ord(ch))
  for ch in record.kind: data.appendByte(ord(ch))
  if record.kind == "blob": data.appendUint(uint64(record.value.len), 4)
  data.add record.value

proc dmgRecords(app: string): seq[DsRecord] =
  var window = initTable[string, PlistAtom]()
  window["ShowStatusBar"] = plistBool(false)
  window["WindowBounds"] = plistString("{{200, 400}, {660, 400}}")
  window["ContainerShowSidebar"] = plistBool(false)
  window["PreviewPaneVisibility"] = plistBool(false)
  window["SidebarWidth"] = plistInt(180)
  window["ShowTabView"] = plistBool(false)
  window["ShowToolbar"] = plistBool(false)
  window["ShowPathbar"] = plistBool(false)
  window["ShowSidebar"] = plistBool(false)

  var iconView = initTable[string, PlistAtom]()
  iconView["viewOptionsVersion"] = plistInt(1)
  iconView["backgroundType"] = plistInt(0)
  iconView["backgroundColorRed"] = plistFloat(1.0)
  iconView["backgroundColorGreen"] = plistFloat(1.0)
  iconView["backgroundColorBlue"] = plistFloat(1.0)
  iconView["gridOffsetX"] = plistFloat(0.0)
  iconView["gridOffsetY"] = plistFloat(0.0)
  iconView["gridSpacing"] = plistFloat(100.0)
  iconView["arrangeBy"] = plistString("none")
  iconView["showIconPreview"] = plistBool(false)
  iconView["showItemInfo"] = plistBool(false)
  iconView["labelOnBottom"] = plistBool(true)
  iconView["textSize"] = plistFloat(16.0)
  iconView["iconSize"] = plistFloat(128.0)
  iconView["scrollPositionX"] = plistFloat(0.0)
  iconView["scrollPositionY"] = plistFloat(0.0)

  result.add dsLong(".", "vSrn", 1)
  result.add dsBlob(".", "bwsp", binaryPlist(window))
  result.add dsBlob(".", "icvp", binaryPlist(iconView))
  result.add DsRecord(name: ".", code: "icvl", kind: "type",
                      value: @[byte('i'), byte('c'), byte('n'), byte('v')])
  result.add dsIconLocation(app, 180, 190)
  result.add dsIconLocation("Applications", 480, 185)

proc dsStore*(app: string): seq[byte] =
  ## Encodes a single-page Finder B-tree with the app install layout.
  var records = dmgRecords(app)
  records.sort(proc(a, b: DsRecord): int =
    result = cmp(a.name.toLower, b.name.toLower)
    if result == 0: result = cmp(a.code, b.code))

  var node: seq[byte]
  node.appendUint(0, 4)
  node.appendUint(uint64(records.len), 4)
  for record in records: record.encode(node)
  const pageSize = 0x1000
  if node.len > pageSize:
    raise newException(ValueError,
      ".DS_Store records need " & $node.len & " bytes, more than one page")

  const dsdbAddr = 0x20
  const rootAddr = 0x800
  const nodeAddr = 0x2000
  result = newSeq[byte](4 + 0x4000)
  result[3] = 1
  let base = 4
  for i, ch in "Bud1": result[base + i] = byte(ord(ch))
  result.putUint(base + 4, rootAddr.uint32)
  result.putUint(base + 8, 0x800)
  result.putUint(base + 12, rootAddr.uint32)
  let allocator = [0, 0, 0x10, 0x0c, 0, 0, 0, 0x87,
                   0, 0, 0x20, 0x0b, 0, 0, 0, 0]
  for i, value in allocator: result[base + 16 + i] = byte(value)

  result.putUint(base + dsdbAddr, 2)
  result.putUint(base + dsdbAddr + 4, 0)
  result.putUint(base + dsdbAddr + 8, records.len.uint32)
  result.putUint(base + dsdbAddr + 12, 1)
  result.putUint(base + dsdbAddr + 16, pageSize.uint32)

  let root = base + rootAddr
  result.putUint(root, 3)
  let blockAddresses = [rootAddr or 11, dsdbAddr or 5, nodeAddr or 13]
  for index, address in blockAddresses:
    result.putUint(root + 8 + index * 4, address.uint32)
  var position = 8 + 256 * 4
  result.putUint(root + position, 1)
  result[root + position + 4] = 4
  for i, ch in "DSDB": result[root + position + 5 + i] = byte(ord(ch))
  result.putUint(root + position + 9, 1)
  position += 13
  for width in 0..<32:
    if width < 6 or width in [11, 13, 31]:
      position += 4
    else:
      result.putUint(root + position, 1)
      result.putUint(root + position + 4, uint32(1'u64 shl width))
      position += 8

  for index, value in node: result[base + nodeAddr + index] = value

proc writeDsStore*(path, app: string) =
  ## Writes a Finder window layout for an app and an Applications link.
  let bytes = dsStore(app)
  var data = newString(bytes.len)
  for index, value in bytes: data[index] = char(value)
  writeFile(path, data)
