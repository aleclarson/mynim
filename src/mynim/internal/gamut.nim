## Package gamut converts between sRGB, Display P3, Oklab and Oklch, and
## maps colors into a display's gamut as CSS Color 4 does.
##
## Colors travel as extended sRGB: gamma encoded with the sRGB curve,
## mirrored around zero, so that a color outside the sRGB gamut (but
## inside Display P3's) has components below 0 or above 1.

import std/math

type Space* = enum
  ## An RGB gamut colors are mapped into.
  spaceSRGB
  spaceDisplayP3

proc decode*(v: float64): float64 =
  ## The linear light of an sRGB-encoded component, which may be outside
  ## 0 to 1.
  let a = abs(v)
  if a <= 0.04045:
    return v / 12.92
  copySign(pow((a + 0.055) / 1.055, 2.4), v)

proc encode*(v: float64): float64 =
  ## The inverse of decode.
  let a = abs(v)
  if a <= 0.0031308:
    return v * 12.92
  copySign(1.055 * pow(a, 1 / 2.4) - 0.055, v)

proc oklab*(r, g, b: float64): tuple[l, a, bb: float64] =
  ## Converts linear sRGB to Oklab.
  let lc = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  let mc = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  let sc = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  (0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc,
   1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc,
   0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc)

proc linearSRGB*(l, a, b: float64): tuple[r, g, bb: float64] =
  ## Converts Oklab to linear sRGB, unclamped.
  var lc = l + 0.3963377774 * a + 0.2158037573 * b
  var mc = l - 0.1055613458 * a - 0.0638541728 * b
  var sc = l - 0.0894841775 * a - 1.2914855480 * b
  lc = lc * lc * lc; mc = mc * mc * mc; sc = sc * sc * sc
  (4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
   -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
   -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc)

proc linearSRGBToP3*(r, g, b: float64): tuple[r, g, bb: float64] =
  ## Converts linear sRGB to linear Display P3.
  (0.8224621 * r + 0.1775380 * g,
   0.0331941 * r + 0.9668058 * g,
   0.0170827 * r + 0.0723974 * g + 0.9105199 * b)

proc linearP3ToSRGB*(r, g, b: float64): tuple[r, g, bb: float64] =
  ## Converts linear Display P3 to linear sRGB.
  (1.2249401 * r - 0.2249404 * g,
   -0.0420569 * r + 1.0420571 * g,
   -0.0196376 * r - 0.0786361 * g + 1.0982735 * b)

proc oklch*(l, a, b: float64): tuple[l, c, h: float64] =
  ## Converts Oklab to Oklch, with the hue in degrees.
  var h = arctan2(b, a) * 180 / PI
  if h < 0: h += 360
  (l, hypot(a, b), h)

proc fromOklch*(l, c, h: float64): tuple[l, a, b: float64] =
  ## Converts Oklch, with the hue in degrees, to Oklab.
  let rad = h * PI / 180
  (l, c * cos(rad), c * sin(rad))

proc toSpace(sp: Space; l, a, b: float64): tuple[r, g, bb: float64] =
  let (r, g, bb) = linearSRGB(l, a, b)
  if sp == spaceDisplayP3:
    return linearSRGBToP3(r, g, bb)
  (r, g, bb)

proc fromSpace(sp: Space; r, g, b: float64): tuple[l, a, bb: float64] =
  var r = r; var g = g; var b = b
  if sp == spaceDisplayP3:
    (r, g, b) = linearP3ToSRGB(r, g, b)
  oklab(r, g, b)

const
  jnd = 0.02 ## the Oklab distance CSS Color 4 treats as imperceptible
  epsilon = 0.0001
    ## ends the search for the chroma, and absorbs the rounding of the
    ## matrices when testing for the gamut
  inGamut = 0.00001

proc within(r, g, b: float64): bool =
  template `in`(v: float64): bool = v >= -inGamut and v <= 1 + inGamut
  r.`in` and g.`in` and b.`in`

proc clip(v: float64): float64 = max(0, min(v, 1))

## beyond the chroma of any color a display shows: map starts its search
## there for a larger one, as an infinite one
const maxChroma = 1.0

proc map*(sp: Space; l, c, h: float64): tuple[r, g, b: float64] =
  ## Returns the Oklch color as linear RGB inside the gamut of sp. It
  ## reduces the chroma, keeping lightness and hue, until clipping what
  ## is left out changes the color imperceptibly (the algorithm of CSS
  ## Color 4, "gamut mapping to a destination color space"). A negative
  ## or NaN chroma is 0, as CSS clamps it, a NaN lightness 0 and a hue
  ## that is not finite 0.
  var l = l; var c = c; var h = h
  if l >= 1: return (1.0, 1.0, 1.0)
  if not (l > 0): return (0.0, 0.0, 0.0)
  if not (c > 0): c = 0
  c = min(c, maxChroma)
  if classify(h) notin {fcNormal, fcZero, fcSubnormal}: h = 0
  let (_, oa, ob) = fromOklch(l, c, h)
  let (r, g, b) = toSpace(sp, l, oa, ob)
  if within(r, g, b):
    return (clip(r), clip(g), clip(b))
  # clipped is the Oklab distance between the clipped color and lab.
  proc clipped(a, bb: float64): tuple[cr, cg, cb, e: float64] =
    let (r, g, b) = toSpace(sp, l, a, bb)
    result.cr = clip(r); result.cg = clip(g); result.cb = clip(b)
    let (cl, ca, cbb) = fromSpace(sp, result.cr, result.cg, result.cb)
    result.e = sqrt((cl - l) * (cl - l) + (ca - a) * (ca - a) +
                    (cbb - bb) * (cbb - bb))
  var (cr, cg, cb, e) = clipped(oa, ob)
  if e < jnd:
    return (cr, cg, cb)
  var lo = 0.0; var hi = c; var loIn = true
  while hi - lo > epsilon:
    let mid = (lo + hi) / 2
    let (_, a, bb) = fromOklch(l, mid, h)
    let (r, g, b) = toSpace(sp, l, a, bb)
    if loIn and within(r, g, b):
      lo = mid
      continue
    (cr, cg, cb, e) = clipped(a, bb)
    if e < jnd:
      if jnd - e < epsilon:
        return (cr, cg, cb)
      loIn = false
      lo = mid
    else:
      hi = mid
  (cr, cg, cb)
