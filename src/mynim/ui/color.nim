## color.go and widecolor.go — public colors and CSS color parsing.

## Color is an 8-bit sRGB color with straight (not premultiplied) alpha.
## A color made by `oklch` can also keep its extended sRGB components for
## wide-gamut renderers. Its zero value is transparent. Changing its RGB
## fields makes the extended components stale.
type Color* = object
  r*, g*, b*: uint8 ## Nearest sRGB red, green and blue channels.
  a*: uint8 ## Straight alpha.
  wide: array[3, int16]

const
  transparent* = Color() ## A transparent color.

  wideOne = 1 shl 13

proc rgb*(r, g, b: uint8): Color =
  ## Returns an opaque sRGB color.
  Color(r: r, g: g, b: b, a: 255)

proc alphaByte(a: float32): uint8 =
  if a <= 0:
    return 0
  if a >= 1:
    return 255
  uint8(a * 255 + 0.5)

proc rgba*(r, g, b: uint8; alpha: float32): Color =
  ## Returns an sRGB color with alpha from 0 to 1.
  Color(r: r, g: g, b: b, a: alphaByte(alpha))

proc wideOk(w: array[3, int16]): bool = w != [0'i16, 0, 0]

proc wideRgb(w: array[3, int16]): tuple[r, g, b: float32] =
  (w[0].float32 / wideOne.float32,
   w[1].float32 / wideOne.float32,
   w[2].float32 / wideOne.float32)

proc toWide(v: float32): int16 =
  let n = round(v.float64 * wideOne.float64)
  int16(max(low(int16).float64, min(n, high(int16).float64)))

proc fromWide(r, g, b: float32): Color =
  let invalid = {fcNan, fcInf, fcNegInf}
  if classify(r) in invalid or classify(g) in invalid or classify(b) in invalid:
    return Color(a: 255)

  let w = [toWide(r), toWide(g), toWide(b)]
  let (r, g, b) = wideRgb(w)
  const eps = 1'f32 / 512
  if r >= -eps and r <= 1 + eps and
      g >= -eps and g <= 1 + eps and
      b >= -eps and b <= 1 + eps:
    let byteOf = proc(v: float32): uint8 =
      uint8(max(0'f32, min(v, 1'f32)) * 255 + 0.5)
    return Color(r: byteOf(r), g: byteOf(g), b: byteOf(b), a: 255)

  let (labL, labA, labB) = gamut.oklab(gamut.decode(r.float64),
    gamut.decode(g.float64), gamut.decode(b.float64))
  let (chromaL, chroma, hue) = gamut.oklch(labL, labA, labB)
  let (sr, sg, sb) = gamut.map(gamut.spaceSRGB, chromaL, chroma, hue)
  let byteOf = proc(v: float64): uint8 = uint8(gamut.encode(v) * 255 + 0.5)
  Color(r: byteOf(sr), g: byteOf(sg), b: byteOf(sb), a: 255, wide: w)

proc extended(c: Color): tuple[r, g, b: float32] =
  if c.wide.wideOk:
    return wideRgb(c.wide)
  (c.r.float32 / 255, c.g.float32 / 255, c.b.float32 / 255)

proc mixWide(c, other: Color; t: float32): Color =
  let (cr, cg, cb) = c.extended
  let (otherR, otherG, otherB) = other.extended
  fromWide(cr * (1 - t) + otherR * t,
           cg * (1 - t) + otherG * t,
           cb * (1 - t) + otherB * t)

proc oklch*(l, c, h: float32): Color =
  ## Returns CSS `oklch(l c h)` mapped to Display P3. Wide-gamut renderers
  ## retain colors outside sRGB; other renderers use their nearest sRGB color.
  ## Negative chroma is zero. A negative or non-finite hue is treated as zero.
  let (r, g, b) = gamut.map(gamut.spaceDisplayP3, l.float64, c.float64, h.float64)
  let (sr, sg, sb) = gamut.linearP3ToSRGB(r, g, b)
  fromWide(gamut.encode(sr).float32, gamut.encode(sg).float32,
           gamut.encode(sb).float32)

proc srgb*(c: Color): Color =
  ## Returns the nearest sRGB color without its extended-gamut components.
  result = c
  result.wide = [0'i16, 0, 0]

proc alpha*(c: Color; factor: float32): Color =
  ## Returns c with its alpha multiplied by factor.
  result = c
  result.a = alphaByte(c.a.float32 / 255 * factor)

proc mix*(c, other: Color; t: float32): Color =
  ## Returns the color t of the way from c to other, with t clamped to 0..1.
  let t = max(0'f32, min(t, 1'f32))
  let mixByte = proc(a, b: uint8): uint8 =
    uint8(a.float32 * (1 - t) + b.float32 * t + 0.5)
  if c.wide.wideOk or other.wide.wideOk:
    result = mixWide(c, other, t)
  else:
    result = Color(r: mixByte(c.r, other.r), g: mixByte(c.g, other.g),
                   b: mixByte(c.b, other.b))
  result.a = mixByte(c.a, other.a)

proc mixPremultiplied(c, other: Color; t: float32): Color =
  ## Interpolates color and alpha together so transparent colors do not tint
  ## the visible color while fading.
  let t = max(0'f32, min(t, 1'f32))
  let alphaC = c.a.float32 / 255
  let alphaOther = other.a.float32 / 255
  let alpha = alphaC * (1 - t) + alphaOther * t
  if alpha <= 0:
    return transparent
  if c.wide.wideOk or other.wide.wideOk:
    result = mixWide(c, other, t * alphaOther / alpha)
    result.a = alphaByte(alpha)
    return
  let mixChannel = proc(a, b: uint8): uint8 =
    let value = (a.float32 * alphaC * (1 - t) +
      b.float32 * alphaOther * t) / alpha
    uint8(max(0'f32, min(value + 0.5'f32, 255'f32)))
  Color(r: mixChannel(c.r, other.r), g: mixChannel(c.g, other.g),
    b: mixChannel(c.b, other.b), a: alphaByte(alpha))

proc over*(c, base: Color): Color =
  ## Returns c composited over base.
  result = c.mix(base, 1 - c.a.float32 / 255)
  result.a = base.a

proc `$`*(c: Color): string =
  ## The color as "#rrggbb", or "#rrggbbaa" when it is not opaque: the
  ## forms a CSS color and WindowOptions.backgroundColor take.
  if c.a == 255:
    "#" & toHex(c.r.int, 2).toLowerAscii() &
      toHex(c.g.int, 2).toLowerAscii() & toHex(c.b.int, 2).toLowerAscii()
  else:
    "#" & toHex(c.r.int, 2).toLowerAscii() &
      toHex(c.g.int, 2).toLowerAscii() & toHex(c.b.int, 2).toLowerAscii() &
      toHex(c.a.int, 2).toLowerAscii()

proc colorComponent(s: string; alpha: bool): uint8 =
  let pct = s.endsWith("%")
  var v = parseFloat(if pct: s[0..^2] else: s)
  if pct:
    v = v / 100 * 255
  elif alpha:
    v *= 255
  uint8(round(min(max(v, 0), 255)))

proc parseColor*(s: string): Color =
  ## Parses a CSS color: #rgb, #rgba, #rrggbb, #rrggbbaa, rgb(r g b),
  ## rgba(r, g, b, a) or "transparent".
  let s = s.strip().toLowerAscii()
  template bad: untyped =
    raise newException(ValueError, "mynim: invalid color " & s.escape())
  if s == "transparent":
    return Color()
  if s.startsWith("#"):
    var hex = s[1..^1]
    if hex.len == 3 or hex.len == 4:
      var b = ""
      for c in hex:
        b.add c; b.add c
      hex = b
    if hex.len == 6:
      hex.add "ff"
    if hex.len != 8:
      bad()
    var v: uint64
    if parseHex(hex, v) != hex.len:
      bad()
    return Color(r: uint8(v shr 24), g: uint8(v shr 16),
                 b: uint8(v shr 8), a: uint8(v))
  if s.startsWith("rgb"):
    let open = s.find('(')
    let `end` = s.rfind(')')
    if open < 0 or `end` < open:
      bad()
    let parts = s[open + 1..<`end`].split({' ', ',', '/'})
      .filterIt(it.len > 0)
    if parts.len != 3 and parts.len != 4:
      bad()
    var c = Color(a: 255)
    for i, p in parts:
      try:
        let v = colorComponent(p, i == 3)
        case i
        of 0: c.r = v
        of 1: c.g = v
        of 2: c.b = v
        else: c.a = v
      except ValueError:
        bad()
    return c
  bad()

proc hexColor*(s: string): Color =
  ## Parses a CSS hexadecimal color: #rgb, #rgba, #rrggbb or #rrggbbaa.
  let value = s.strip()
  parseColor(if value.startsWith("#"): value else: "#" & value)
