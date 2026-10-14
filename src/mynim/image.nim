## Port of the subset of Go's image, image/color and image/draw packages
## that MyGo uses. `Rgba` is premultiplied 8-bit (color.RGBA), `Nrgba`
## non-premultiplied (color.NRGBA), matching Go semantics.
##
## Image pixels live in a shared `pix` buffer like Go's []uint8: `off` is
## the offset of the rectangle's first pixel so SubImage shares memory.


type
  Point* = object
    x*, y*: int

  Rectangle* = object
    min*, max*: Point

  Rgba* = object ## premultiplied alpha (color.RGBA)
    r*, g*, b*, a*: uint8

  Nrgba* = object ## non-premultiplied alpha (color.NRGBA)
    r*, g*, b*, a*: uint8

  Alpha* = object
    a*: uint8

proc pt*(x, y: int): Point = Point(x: x, y: y)
proc rect*(x0, y0, x1, y1: int): Rectangle =
  if x0 > x1 or y0 > y1: return Rectangle()
  Rectangle(min: pt(x0, y0), max: pt(x1, y1))
proc rectMinMax*(min, max: Point): Rectangle = Rectangle(min: min, max: max)

proc dx*(r: Rectangle): int = r.max.x - r.min.x
proc dy*(r: Rectangle): int = r.max.y - r.min.y
proc empty*(r: Rectangle): bool = r.min.x >= r.max.x or r.min.y >= r.max.y
proc contains*(r: Rectangle, p: Point): bool =
  p.x >= r.min.x and p.x < r.max.x and p.y >= r.min.y and p.y < r.max.y
proc contains*(r: Rectangle, x, y: int): bool =
  x >= r.min.x and x < r.max.x and y >= r.min.y and y < r.max.y
proc add*(r: Rectangle, p: Point): Rectangle =
  rectMinMax(pt(r.min.x + p.x, r.min.y + p.y), pt(r.max.x + p.x, r.max.y + p.y))
proc sub*(r: Rectangle, p: Point): Rectangle = r.add(pt(-p.x, -p.y))
proc inset*(r: Rectangle, n: int): Rectangle =
  result = rectMinMax(pt(r.min.x + n, r.min.y + n), pt(r.max.x - n, r.max.y - n))
  if result.empty: result = Rectangle()
proc intersect*(a, b: Rectangle): Rectangle =
  result = rectMinMax(pt(max(a.min.x, b.min.x), max(a.min.y, b.min.y)),
                      pt(min(a.max.x, b.max.x), min(a.max.y, b.max.y)))
  if result.empty: result = Rectangle()
proc union*(a, b: Rectangle): Rectangle =
  if a.empty: return b
  if b.empty: return a
  rectMinMax(pt(min(a.min.x, b.min.x), min(a.min.y, b.min.y)),
             pt(max(a.max.x, b.max.x), max(a.max.y, b.max.y)))
proc overlaps*(a, b: Rectangle): bool =
  not a.intersect(b).empty
proc `in`*(r, s: Rectangle): bool =
  r == r.intersect(s)
proc canon*(r: Rectangle): Rectangle =
  ## Rectangle.Canon: min <= max per axis.
  result = r
  if result.max.x < result.min.x: swap(result.min.x, result.max.x)
  if result.max.y < result.min.y: swap(result.min.y, result.max.y)

proc `==`*(a, b: Point): bool = a.x == b.x and a.y == b.y
proc `==`*(a, b: Rectangle): bool = a.min == b.min and a.max == b.max
proc `+`*(a, b: Point): Point = pt(a.x + b.x, a.y + b.y)
proc `-`*(a, b: Point): Point = pt(a.x - b.x, a.y - b.y)
proc `-`*(a: Point): Point = pt(-a.x, -a.y)

## --- colors ---

func to32(c: uint8): uint32 = uint32(c) or (uint32(c) shl 8)

func rgba*(c: Rgba): tuple[r, g, b, a: uint32] =
  (to32(c.r), to32(c.g), to32(c.b), to32(c.a))

func rgba*(c: Nrgba): tuple[r, g, b, a: uint32] =
  var r = to32(c.r); var g = to32(c.g); var b = to32(c.b)
  let a = to32(c.a)
  (r * a div 0xffff, g * a div 0xffff, b * a div 0xffff, a)

func rgba*(c: Alpha): tuple[r, g, b, a: uint32] =
  let a = to32(c.a)
  (a, a, a, a)

func toRgba*(c: Nrgba): Rgba =
  let a = uint32(c.a)
  Rgba(r: uint8(uint32(c.r) * a div 0xff),
       g: uint8(uint32(c.g) * a div 0xff),
       b: uint8(uint32(c.b) * a div 0xff), a: c.a)

func toNrgba*(c: Rgba): Nrgba =
  if c.a == 0: return Nrgba()
  if c.a == 0xff: return Nrgba(r: c.r, g: c.g, b: c.b, a: 0xff)
  let a = uint32(c.a)
  Nrgba(r: uint8(min(0xff'i32, int(uint32(c.r) * 0xff div a)).uint8),
        g: uint8(min(0xff'i32, int(uint32(c.g) * 0xff div a)).uint8),
        b: uint8(min(0xff'i32, int(uint32(c.b) * 0xff div a)).uint8), a: c.a)

const
  black* = Rgba(r: 0, g: 0, b: 0, a: 0xff)
  white* = Rgba(r: 0xff, g: 0xff, b: 0xff, a: 0xff)
  transparent* = Rgba(r: 0, g: 0, b: 0, a: 0)
  opaqueColor* = Rgba(r: 0xff, g: 0xff, b: 0xff, a: 0xff)

## --- images ---

type
  Image* = ref object of RootObj
    ## Go image.Image equivalent. `at` returns premultiplied Rgba like
    ## color.RGBAModel conversion.

  RgbaImage* = ref object of Image
    ## Go image.RGBA: premultiplied rows of `stride` bytes; `off` is the
    ## index of the rect's first pixel so SubImage can share `pix`.
    pix*: seq[uint8]
    stride*: int
    rect*: Rectangle
    off*: int

  NrgbaImage* = ref object of Image
    pix*: seq[uint8]
    stride*: int
    rect*: Rectangle
    off*: int

  AlphaImage* = ref object of Image
    pix*: seq[uint8]
    stride*: int
    rect*: Rectangle
    off*: int

  Uniform* = ref object of Image
    c*: Rgba

method bounds*(m: Image): Rectangle {.base.} = Rectangle()
method at*(m: Image, x, y: int): Rgba {.base.} = transparent

method bounds*(m: RgbaImage): Rectangle = m.rect
method bounds*(m: NrgbaImage): Rectangle = m.rect
method bounds*(m: AlphaImage): Rectangle = m.rect
method bounds*(m: Uniform): Rectangle = rect(-1e9.int, -1e9.int, 1e9.int, 1e9.int)

proc pixOffset*(m: RgbaImage, x, y: int): int =
  m.off + (y - m.rect.min.y) * m.stride + (x - m.rect.min.x) * 4
proc pixOffset*(m: NrgbaImage, x, y: int): int =
  m.off + (y - m.rect.min.y) * m.stride + (x - m.rect.min.x) * 4
proc pixOffset*(m: AlphaImage, x, y: int): int =
  m.off + (y - m.rect.min.y) * m.stride + (x - m.rect.min.x)

method at*(m: RgbaImage, x, y: int): Rgba =
  if not m.rect.contains(x, y): return transparent
  let o = m.pixOffset(x, y)
  Rgba(r: m.pix[o], g: m.pix[o+1], b: m.pix[o+2], a: m.pix[o+3])

method at*(m: NrgbaImage, x, y: int): Rgba =
  if not m.rect.contains(x, y): return transparent
  let o = m.pixOffset(x, y)
  toRgba(Nrgba(r: m.pix[o], g: m.pix[o+1], b: m.pix[o+2], a: m.pix[o+3]))

method at*(m: AlphaImage, x, y: int): Rgba =
  if not m.rect.contains(x, y): return transparent
  let a = m.pix[m.pixOffset(x, y)]
  Rgba(r: a, g: a, b: a, a: a)

method at*(m: Uniform, x, y: int): Rgba = m.c

proc nrgbaAt*(m: NrgbaImage, x, y: int): Nrgba =
  if not m.rect.contains(x, y): return Nrgba()
  let o = m.pixOffset(x, y)
  Nrgba(r: m.pix[o], g: m.pix[o+1], b: m.pix[o+2], a: m.pix[o+3])

proc set*(m: RgbaImage, x, y: int, c: Rgba) =
  if not m.rect.contains(x, y): return
  let o = m.pixOffset(x, y)
  m.pix[o] = c.r; m.pix[o+1] = c.g; m.pix[o+2] = c.b; m.pix[o+3] = c.a

proc set*(m: NrgbaImage, x, y: int, c: Nrgba) =
  if not m.rect.contains(x, y): return
  let o = m.pixOffset(x, y)
  m.pix[o] = c.r; m.pix[o+1] = c.g; m.pix[o+2] = c.b; m.pix[o+3] = c.a

proc set*(m: AlphaImage, x, y: int, c: Alpha) =
  if not m.rect.contains(x, y): return
  m.pix[m.pixOffset(x, y)] = c.a

proc opaque*(m: RgbaImage): bool =
  if m.rect.empty: return false
  for y in m.rect.min.y ..< m.rect.max.y:
    var o = m.off + (y - m.rect.min.y) * m.stride + 3
    for x in 0 ..< m.rect.dx:
      if m.pix[o] != 0xff: return false
      o += 4
  true

proc opaque*(m: NrgbaImage): bool =
  if m.rect.empty: return false
  for y in m.rect.min.y ..< m.rect.max.y:
    var o = m.off + (y - m.rect.min.y) * m.stride + 3
    for x in 0 ..< m.rect.dx:
      if m.pix[o] != 0xff: return false
      o += 4
  true

proc opaque*(m: AlphaImage): bool =
  if m.rect.empty: return false
  for y in m.rect.min.y ..< m.rect.max.y:
    let o = m.off + (y - m.rect.min.y) * m.stride
    for x in 0 ..< m.rect.dx:
      if m.pix[o + x] != 0xff: return false
  true

proc subImage*(m: RgbaImage, r: Rectangle): RgbaImage =
  let rr = r.intersect(m.rect)
  if rr.empty: return RgbaImage(rect: Rectangle())
  RgbaImage(pix: m.pix, stride: m.stride, rect: rr,
            off: m.pixOffset(rr.min.x, rr.min.y))

proc subImage*(m: NrgbaImage, r: Rectangle): NrgbaImage =
  let rr = r.intersect(m.rect)
  if rr.empty: return NrgbaImage(rect: Rectangle())
  NrgbaImage(pix: m.pix, stride: m.stride, rect: rr,
             off: m.pixOffset(rr.min.x, rr.min.y))

proc subImage*(m: AlphaImage, r: Rectangle): AlphaImage =
  let rr = r.intersect(m.rect)
  if rr.empty: return AlphaImage(rect: Rectangle())
  AlphaImage(pix: m.pix, stride: m.stride, rect: rr,
             off: m.pixOffset(rr.min.x, rr.min.y))

proc newRgba*(r: Rectangle): RgbaImage =
  let rr = r.canon
  RgbaImage(pix: newSeq[uint8](rr.dx * rr.dy * 4), stride: 4 * rr.dx, rect: rr)

proc newNrgba*(r: Rectangle): NrgbaImage =
  let rr = r.canon
  NrgbaImage(pix: newSeq[uint8](rr.dx * rr.dy * 4), stride: 4 * rr.dx, rect: rr)

proc newAlpha*(r: Rectangle): AlphaImage =
  let rr = r.canon
  AlphaImage(pix: newSeq[uint8](rr.dx * rr.dy), stride: rr.dx, rect: rr)

proc newUniform*(c: Rgba): Uniform = Uniform(c: c)

## --- draw (Go image/draw subset) ---

type
  Op* = enum
    opOver ## Go draw.Over
    opSrc  ## Go draw.Src

proc drawSrc*(dst: RgbaImage, r: Rectangle, src: Image, sp: Point) =
  let rr = r.intersect(dst.rect)
  for y in rr.min.y ..< rr.max.y:
    for x in rr.min.x ..< rr.max.x:
      dst.set(x, y, src.at(sp.x + x - rr.min.x, sp.y + y - rr.min.y))

proc drawSrc*(dst: NrgbaImage, r: Rectangle, src: Image, sp: Point) =
  let rr = r.intersect(dst.rect)
  for y in rr.min.y ..< rr.max.y:
    for x in rr.min.x ..< rr.max.x:
      dst.set(x, y, toNrgba(src.at(sp.x + x - rr.min.x, sp.y + y - rr.min.y)))

proc drawOver*(dst: RgbaImage, r: Rectangle, src: Image, sp: Point) =
  let rr = r.intersect(dst.rect)
  for y in rr.min.y ..< rr.max.y:
    for x in rr.min.x ..< rr.max.x:
      let s = src.at(sp.x + x - rr.min.x, sp.y + y - rr.min.y)
      let d = dst.at(x, y)
      let a = uint32(0xff - s.a)
      dst.set(x, y, Rgba(
        r: uint8(uint32(s.r) + uint32(d.r) * a div 0xff),
        g: uint8(uint32(s.g) + uint32(d.g) * a div 0xff),
        b: uint8(uint32(s.b) + uint32(d.b) * a div 0xff),
        a: uint8(uint32(s.a) + uint32(d.a) * a div 0xff)))

proc draw*(dst: RgbaImage, r: Rectangle, src: Image, sp: Point, op: Op = opSrc) =
  if op == opSrc: drawSrc(dst, r, src, sp) else: drawOver(dst, r, src, sp)

proc draw*(dst: NrgbaImage, r: Rectangle, src: Image, sp: Point, op: Op = opSrc) =
  drawSrc(dst, r, src, sp)

const pngSignature = [0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

proc looksLikePng*(data: seq[byte]): bool =
  ## Whether data starts with the PNG signature (as `png.Decode`'s
  ## format check does).
  if data.len < 24: return false
  for i, b in pngSignature:
    if data[i] != b: return false
  # IHDR follows the signature.
  data[12] == ord('I') and data[13] == ord('H') and
    data[14] == ord('D') and data[15] == ord('R')

## --- PNG encoding (image/png: Encode) ---

const crcTable = block:
  var t: array[256, uint32]
  for n in 0 ..< 256:
    var c = n.uint32
    for k in 0 ..< 8:
      c = if (c and 1) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
    t[n] = c
  t

proc crc32(data: string): uint32 =
  result = 0xFFFFFFFF'u32
  for ch in data:
    result = crcTable[(result xor ch.uint32) and 0xff] xor (result shr 8)
  result = result xor 0xFFFFFFFF'u32

proc adler32(data: string): uint32 =
  var a = 1'u32
  var b = 0'u32
  for ch in data:
    a = (a + ch.uint8.uint32) mod 65521
    b = (b + a) mod 65521
  (b shl 16) or a

proc u32be(v: uint32): string =
  result = newString(4)
  result[0] = char((v shr 24) and 0xff)
  result[1] = char((v shr 16) and 0xff)
  result[2] = char((v shr 8) and 0xff)
  result[3] = char(v and 0xff)

proc crcChunk(kind: string; data: string): string =
  u32be(data.len.uint32) & kind & data & u32be(crc32(kind & data))

proc zlibStore(data: string): string =
  ## A zlib stream whose DEFLATE data is a sequence of stored blocks:
  ## valid for any decoder, without a compression dependency.
  result = "\x78\x01"
  var pos = 0
  while pos < data.len or (pos == 0 and data.len == 0):
    let n = min(data.len - pos, 65535)
    let last = pos + n >= data.len
    result.add char(if last: 0x01 else: 0x00)
    result.add char(n and 0xff)
    result.add char((n shr 8) and 0xff)
    result.add char((not n) and 0xff)
    result.add char(((not n) shr 8) and 0xff)
    if n > 0:
      result.add data[pos ..< pos + n]
    pos += n
    if data.len == 0: break
  result.add u32be(adler32(data))

proc unpremultiply(c: Rgba): Nrgba =
  if c.a == 0: return Nrgba()
  if c.a == 255: return Nrgba(r: c.r, g: c.g, b: c.b, a: 255)
  let a = c.a.uint32
  Nrgba(
    r: uint8(min((c.r.uint32 * 255 + a div 2) div a, 255)),
    g: uint8(min((c.g.uint32 * 255 + a div 2) div a, 255)),
    b: uint8(min((c.b.uint32 * 255 + a div 2) div a, 255)),
    a: c.a)

proc pngEncode*(img: Image): seq[byte] =
  ## PNG encoding (image/png's Encode): 8-bit RGBA, one unfiltered
  ## scanline per row. `at`'s premultiplied pixels are unpremultiplied
  ## as Go's encoder does for *image.RGBA. Compression uses stored
  ## DEFLATE blocks, so the output is larger but equally valid.
  let b = img.bounds()
  let w = b.max.x - b.min.x
  let h = b.max.y - b.min.y
  if w <= 0 or h <= 0:
    raise newException(ValueError, "png: invalid image dimensions")
  var raw = newString(h * (1 + w * 4))
  var pos = 0
  for y in b.min.y ..< b.max.y:
    raw[pos] = '\x00'
    inc pos
    for x in b.min.x ..< b.max.x:
      let c = unpremultiply(img.at(x, y))
      raw[pos] = char(c.r); raw[pos+1] = char(c.g)
      raw[pos+2] = char(c.b); raw[pos+3] = char(c.a)
      pos += 4
  var ihdr = newString(13)
  ihdr[0..3] = u32be(w.uint32)
  ihdr[4..7] = u32be(h.uint32)
  ihdr[8] = '\x08' ## bit depth
  ihdr[9] = '\x06' ## color type RGBA
  var outb = newStringOfCap(raw.len + 64)
  for b0 in pngSignature: outb.add char(b0)
  outb.add crcChunk("IHDR", ihdr)
  outb.add crcChunk("IDAT", zlibStore(raw))
  outb.add crcChunk("IEND", "")
  cast[seq[byte]](outb)
