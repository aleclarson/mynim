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

proc unpremultiply*(c: Rgba): Nrgba =
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

## --- PNG decoding (image/png's Decode) ---

## inflate decodes a zlib (RFC 1950) stream: the wrapper, the DEFLATE
## (RFC 1951) stream of stored, fixed-Huffman and dynamic-Huffman
## blocks.
proc inflate*(data: openArray[byte]): seq[byte] =
  if data.len < 6:
    raise newException(ValueError, "zlib: corrupt stream")
  var pos = 2 ## skip the zlib header
  var bit = 0
  var outb: seq[byte]
  proc bit1(): int =
    let v = (int(data[pos]) shr bit) and 1
    inc bit
    if bit == 8:
      bit = 0
      inc pos
    v
  proc bits(n: int): int =
    for i in 0 ..< n:
      result = result or bit1() shl i
  # Huffman decoder over a code-lengths table.
  proc huffBuild(lens: openArray[int]): tuple[maxLen: int,
      codes: seq[tuple[code, len, sym: int]]] =
    var counts = newSeq[int](16)
    for l in lens:
      if l > 0: inc counts[l]
    var next = newSeq[int](16)
    var code = 0
    for l in 1 ..< 16:
      code = (code + counts[l - 1]) shl 1
      next[l] = code
    var codes: seq[tuple[code, len, sym: int]]
    var mx = 0
    for s, l in lens:
      if l > 0:
        codes.add (next[l], l, s)
        inc next[l]
        mx = max(mx, l)
    (mx, codes)
  proc huffDecode(maxLen: int,
      codes: seq[tuple[code, len, sym: int]]): int =
    var code = 0
    for l in 1 .. maxLen:
      code = (code shl 1) or bit1()
      for c in codes:
        if c.len == l and c.code == code:
          return c.sym
    raise newException(ValueError, "zlib: bad code")
  # The order dynamic headers list code lengths in.
  const codeOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3,
    13, 2, 14, 1, 15]
  const lenBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27,
    31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  const lenExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3,
    3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
  const distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97,
    129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
    8193, 12289, 16385, 24577]
  const distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7,
    7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
  while true:
    let final = bit1()
    let typ = bits(2)
    if typ == 0: ## stored
      if bit != 0:
        bit = 0
        inc pos
      let n = int(data[pos]) or (int(data[pos + 1]) shl 8)
      for i in 0 ..< n:
        outb.add data[pos + i]
      pos += n + 2 ## LEN + NLEN
    else:
      var litMax: int
      var litCodes, distCodes: seq[tuple[code, len, sym: int]]
      if typ == 1: ## fixed Huffman
        var lens = newSeq[int](288)
        for i in 0 ..< 144: lens[i] = 8
        for i in 144 ..< 256: lens[i] = 9
        for i in 256 ..< 280: lens[i] = 7
        for i in 280 ..< 288: lens[i] = 8
        let l = huffBuild(lens)
        litMax = l.maxLen
        litCodes = l.codes
        var dl = newSeq[int](30)
        for i in 0 ..< 30: dl[i] = 5
        let d = huffBuild(dl)
        distCodes = d.codes
        var distMax = d.maxLen
        discard distMax
      elif typ == 2: ## dynamic Huffman
        let hlit = bits(5) + 257
        let hdist = bits(5) + 1
        let hclen = bits(4) + 4
        var clens = newSeq[int](19)
        for i in 0 ..< hclen:
          clens[codeOrder[i]] = bits(3)
        let cl = huffBuild(clens)
        var lens = newSeq[int](hlit + hdist)
        var i = 0
        while i < hlit + hdist:
          let s = huffDecode(cl.maxLen, cl.codes)
          if s < 16:
            lens[i] = s
            inc i
          elif s == 16:
            let rep = bits(2) + 3
            for j in 0 ..< rep:
              lens[i + j] = lens[i - 1]
            i += rep
          elif s == 17:
            i += bits(3) + 3
          else:
            i += bits(7) + 11
        let l = huffBuild(lens.toOpenArray(0, hlit - 1))
        litMax = l.maxLen
        litCodes = l.codes
        let d = huffBuild(lens.toOpenArray(hlit, lens.len - 1))
        distCodes = d.codes
      else:
        raise newException(ValueError, "zlib: bad block type")
      ## LZ77 pass.
      while true:
        let s = huffDecode(litMax, litCodes)
        if s < 256:
          outb.add byte(s)
        elif s == 256:
          break
        else:
          let li = s - 257
          if li >= lenBase.len:
            raise newException(ValueError, "zlib: bad length")
          let n = lenBase[li] + bits(lenExtra[li])
          let ds = huffDecode(15, distCodes)
          let dist = distBase[ds] + bits(distExtra[ds])
          for j in 0 ..< n:
            outb.add outb[outb.len - dist]
      let huffDone = true
      discard huffDone
    if final != 0:
      break
  outb

proc pngErr(msg: string): ref CatchableError =
  newException(CatchableError, "png: " & msg)

## pngDecode decodes a PNG image (image/png's Decode): 8-bit color
## types, not interlaced, which is what every exporter writes of
## clipboard and drag images.
proc pngDecode*(data: seq[byte]): tuple[img: NrgbaImage,
    err: ref CatchableError] =
  let sig = [0x89'u8, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
  if data.len < 8:
    return (nil, pngErr("not a PNG"))
  for i in 0 ..< 8:
    if data[i] != sig[i]:
      return (nil, pngErr("not a PNG"))
  var pos = 8
  var w, h, depth, colorType, interlace: int
  var idat: seq[byte]
  var palette: seq[byte]
  var trns: seq[byte]
  while pos + 8 <= data.len:
    let n = (int(data[pos]) shl 24) or (int(data[pos + 1]) shl 16) or
      (int(data[pos + 2]) shl 8) or int(data[pos + 3])
    var kind = newString(4)
    for i in 0 ..< 4:
      kind[i] = char(data[pos + 4 + i])
    template body(i: int): byte = data[pos + 8 + i]
    if kind == "IHDR":
      w = (int(body(0)) shl 24) or (int(body(1)) shl 16) or
        (int(body(2)) shl 8) or int(body(3))
      h = (int(body(4)) shl 24) or (int(body(5)) shl 16) or
        (int(body(6)) shl 8) or int(body(7))
      depth = int(body(8))
      colorType = int(body(9))
      interlace = int(body(12))
    elif kind == "PLTE":
      palette = data[pos + 8 ..< pos + 8 + n]
    elif kind == "tRNS":
      trns = data[pos + 8 ..< pos + 8 + n]
    elif kind == "IDAT":
      for i in 0 ..< n:
        idat.add body(i)
    elif kind == "IEND":
      break
    pos += 12 + n
  if w <= 0 or h <= 0 or depth != 8 or interlace != 0 or
      colorType notin {0, 2, 3, 4, 6}:
    return (nil, pngErr("unsupported PNG format"))
  let channels = case colorType
    of 0, 3: 1
    of 4: 2
    of 2: 3
    else: 4
  var raw: seq[byte]
  try:
    raw = inflate(idat)
  except CatchableError as e:
    return (nil, e)
  let stride = w * channels
  if raw.len < h * (stride + 1):
    return (nil, pngErr("truncated image"))
  var img = NrgbaImage(pix: newSeq[uint8](w * h * 4),
    stride: w * 4, rect: rect(0, 0, w, h))
  var prev = newSeq[byte](stride)
  var cur = newSeq[byte](stride)
  for y in 0 ..< h:
    let fp = y * (stride + 1)
    let filter = raw[fp]
    for i in 0 ..< stride:
      cur[i] = raw[fp + 1 + i]
    case filter
    of 1: ## sub
      for i in channels ..< stride:
        cur[i] = byte((int(cur[i]) + int(cur[i - channels])) and 0xff)
    of 2: ## up
      for i in 0 ..< stride:
        cur[i] = byte((int(cur[i]) + int(prev[i])) and 0xff)
    of 3: ## average
      for i in 0 ..< stride:
        let a = if i >= channels: int(cur[i - channels]) else: 0
        cur[i] = byte((int(cur[i]) + ((a + int(prev[i])) div 2)) and 0xff)
    of 4: ## paeth
      for i in 0 ..< stride:
        let a = if i >= channels: int(cur[i - channels]) else: 0
        let b = int(prev[i])
        let c = if i >= channels: int(prev[i - channels]) else: 0
        let p = a + b - c
        let pa = abs(p - a)
        let pb = abs(p - b)
        let pc = abs(p - c)
        let pr = if pa <= pb and pa <= pc: a
          elif pb <= pc: b else: c
        cur[i] = byte((int(cur[i]) + pr) and 0xff)
    elif filter != 0:
      return (nil, pngErr("unknown filter"))
    for x in 0 ..< w:
      let d = y * img.stride + x * 4
      let so = x * channels
      case colorType
      of 0:
        img.pix[d] = cur[so]; img.pix[d + 1] = cur[so]
        img.pix[d + 2] = cur[so]
        var a = 255'u8
        if trns.len >= 2:
          let tg = int(trns[0]) shl 8 or int(trns[1])
          if int(cur[so]) * 257 == tg:
            a = 0
        img.pix[d + 3] = a
      of 2:
        img.pix[d] = cur[so]; img.pix[d + 1] = cur[so + 1]
        img.pix[d + 2] = cur[so + 2]
        var a = 255'u8
        if trns.len >= 6:
          let r = int(cur[so]) * 257
          let g = int(cur[so + 1]) * 257
          let bb = int(cur[so + 2]) * 257
          let tr = int(trns[0]) shl 8 or int(trns[1])
          let tg = int(trns[2]) shl 8 or int(trns[3])
          let tb = int(trns[4]) shl 8 or int(trns[5])
          if r == tr and g == tg and bb == tb:
            a = 0
        img.pix[d + 3] = a
      of 3:
        let idx = int(cur[so])
        if idx * 3 + 2 >= palette.len:
          return (nil, pngErr("bad palette index"))
        img.pix[d] = palette[idx * 3]
        img.pix[d + 1] = palette[idx * 3 + 1]
        img.pix[d + 2] = palette[idx * 3 + 2]
        img.pix[d + 3] = if idx < trns.len: trns[idx] else: 255
      of 4:
        img.pix[d] = cur[so]; img.pix[d + 1] = cur[so]
        img.pix[d + 2] = cur[so]
        img.pix[d + 3] = cur[so + 1]
      else:
        img.pix[d] = cur[so]; img.pix[d + 1] = cur[so + 1]
        img.pix[d + 2] = cur[so + 2]; img.pix[d + 3] = cur[so + 3]
    swap(prev, cur)
  (img, nil)
