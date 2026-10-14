## oleformats.nim (system.go + clipboard.go): the clipboard formats
## and codecs the OLE data object, the clipboard and drops share.

proc equalsIgnoreCase*(a, b: string): bool =
  a.toLowerAscii == b.toLowerAscii

proc registerClipboardFormat*(name: string): uint32 =
  uint32(procRegisterClipboardFormatW(cast[uint](u16(name))))


const clipboardLengthPrefix* = "MyGo.Transfer.Length:"

proc privateClipboardFormat*(f: Format): bool =
  f == DragSessionFormat or f == "DataObject" or
    f == "Ole Private Data" or
    ($f).startsWith(clipboardLengthPrefix)

var
  cfHTML* = registerClipboardFormat("HTML Format")
  cfPNG* = registerClipboardFormat("PNG")


proc clipboardData(format: uint32): seq[byte] =
  let h = procGetClipboardData(uint(format))
  if h == 0:
    return @[]
  let p = procGlobalLock(h)
  if p == 0:
    return @[]
  defer: discard procGlobalUnlock(h)
  let size = procGlobalSize(h)
  var out0 = newSeq[byte](int(size))
  if size > 0:
    copyMem(addr out0[0], cast[pointer](p), int(size))
  out0

## setClipboardData puts data on the (open, emptied) clipboard.
proc setClipboardData(format: uint32, data: seq[byte]): bool =
  let h = procGlobalAlloc(gmemMoveable, uint(data.len))
  if h == 0:
    return false
  let p = procGlobalLock(h)
  if p == 0:
    discard procGlobalFree(h)
    return false
  if data.len > 0:
    copyMem(cast[pointer](p), unsafeAddr data[0], data.len)
  discard procGlobalUnlock(h)
  if procSetClipboardData(uint(format), h) == 0:
    discard procGlobalFree(h)
    return false
  true

## utf16Bytes encodes s as NUL-terminated little-endian UTF-16.
proc utf16Bytes*(s: string): seq[byte] =
  let u = utf16z(s)
  var b = newSeq[byte](2 * u.len)
  for i, c in u:
    b[2 * i] = byte(c)
    b[2 * i + 1] = byte(c shr 8)
  b


proc htmlOffset*(data, key: string): int =
  let i = data.find(key)
  if i < 0:
    return -1
  let rest = data[i + key.len .. ^1]
  let jr = rest.find("\r")
  let jn = rest.find("\n")
  let j = if jr < 0: jn elif jn < 0: jr else: min(jr, jn)
  if j < 0:
    return -1
  try:
    parseInt(rest[0 ..< j].strip)
  except ValueError:
    -1

## readHTML reads the fragment of a CF_HTML representation.

proc htmlData*(markup: string): seq[byte] =
  let prefix = "<html><body><!--StartFragment-->"
  let suffix = "<!--EndFragment--></body></html>"
  let hLen = 105 ## the fixed header's length: 4 "%010d" fields
  var doc = "Version:0.9\r\n" &
    "StartHTML:" & intToStr(hLen, 10) & "\r\n" &
    "EndHTML:" & intToStr(hLen + prefix.len + markup.len +
      suffix.len, 10) & "\r\n" &
    "StartFragment:" & intToStr(hLen + prefix.len, 10) & "\r\n" &
    "EndFragment:" & intToStr(hLen + prefix.len + markup.len, 10) &
    "\r\n" & prefix & markup & suffix
  doc.add "\x00"
  cast[seq[byte]](doc)


proc dibToImage*(dib: seq[byte]): NrgbaImage =
  if dib.len < 40:
    return nil
  template le16(o: int): uint16 =
    uint16(dib[o]) or uint16(dib[o + 1]) shl 8
  template le32(o: int): uint32 =
    uint32(dib[o]) or uint32(dib[o + 1]) shl 8 or
      uint32(dib[o + 2]) shl 16 or uint32(dib[o + 3]) shl 24
  let headerSize = le32(0)
  let width = int(int32(le32(4)))
  var height = int(int32(le32(8)))
  let bits = le16(14)
  let compression = le32(16)
  if width <= 0 or height == 0 or (bits != 24 and bits != 32) or
      (compression != 0 and compression != 3):
    return nil
  var offset = int(headerSize)
  if offset < 40 or offset > dib.len:
    return nil
  if compression == 3 and headerSize == 40:
    offset += 12 ## BI_BITFIELDS masks
  let bottomUp = height > 0
  if not bottomUp:
    height = -height
  ## Clipboard bitmap dimensions are untrusted. Bound output and
  ## check division before multiplication, including the INT_MIN
  ## height case.
  if width > (64 shl 20) div 4 or height > (64 shl 20) div (4 * width):
    return nil
  let stride = ((width * int(bits) + 31) div 32) * 4
  if offset > dib.len or height > (dib.len - offset) div stride:
    return nil
  var img = NrgbaImage(pix: newSeq[uint8](width * height * 4),
    stride: width * 4, rect: rect(0, 0, width, height))
  let px = int(bits) div 8
  for y in 0 ..< height:
    let row = if bottomUp: height - 1 - y else: y
    let line = offset + row * stride
    for x in 0 ..< width:
      let p = line + x * px
      let d = y * img.stride + x * 4
      var a = 255'u8
      if bits == 32 and headerSize > 40:
        a = dib[p + 3]
      img.pix[d] = dib[p + 2]
      img.pix[d + 1] = dib[p + 1]
      img.pix[d + 2] = dib[p]
      img.pix[d + 3] = a
  img

## imageToDIB encodes a top-down 32-bit BITMAPINFOHEADER bitmap.
proc imageToDIB*(img: image.Image): seq[byte] =
  let b = img.bounds()
  let w = b.max.x - b.min.x
  let h = b.max.y - b.min.y
  var out0 = newSeq[byte](40 + 4 * w * h)
  template put16(o: int, v: uint16) =
    out0[o] = byte(v)
    out0[o + 1] = byte(v shr 8)
  template put32(o: int, v: uint32) =
    out0[o] = byte(v)
    out0[o + 1] = byte(v shr 8)
    out0[o + 2] = byte(v shr 16)
    out0[o + 3] = byte(v shr 24)
  put32(0, 40)
  put32(4, uint32(w))
  put32(8, uint32(int32(-h)))
  put16(12, 1)
  put16(14, 32)
  put32(20, uint32(4 * w * h))
  var i = 40
  for y in b.min.y ..< b.max.y:
    for x in b.min.x ..< b.max.x:
      let c = unpremultiply(img.at(x, y))
      out0[i] = c.b; out0[i + 1] = c.g
      out0[i + 2] = c.r; out0[i + 3] = c.a
      i += 4
  out0

