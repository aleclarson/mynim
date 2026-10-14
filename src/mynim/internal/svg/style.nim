## style.go: computed styles, paint specifications, CSS color and
## length parsing, dash arrays, and preserveAspectRatio.

## rgba is a straight color, its components from 0 to 1.
type rgba = object
  r, g, b, a: float64

const black = rgba(r: 0, g: 0, b: 0, a: 1)

## Kinds of paint specifications.
const
  specNone* = 0'u8
  specColor* = 1'u8
  specCurrent* = 2'u8
  specURL* = 3'u8

## paintSpec is a fill or stroke as written: none, a color,
## currentColor, or a reference to a gradient with what to paint when
## it is not one.
type paintSpec = object
  kind: uint8
  color: rgba
  id: string
  fallback: uint8 ## specNone, specColor or specCurrent, with color

## style is the computed style of an element.
type style = object
  ## Inherited.
  fill, stroke: paintSpec
  fillOpacity: float64
  strokeOpacity: float64
  fillEvenOdd: bool
  clipEvenOdd: bool
  strokeWidth: float64
  miterLimit: float64
  cap, join: uint8
  dashes: seq[float64]
  dashOffset: float64
  ## color is the color property, which currentColor stands for;
  ## until a document sets it, currentColor is the color it is drawn
  ## with.
  color: rgba
  colorSet: bool
  visible: bool
  strokeFirst: bool

  ## Not inherited.
  opacity: float64
  display: bool
  clipPath: string
  mask: string
  maskAlpha: bool
  stopColor: paintSpec
  stopOpacity: float64

proc initialStyle(): style =
  style(fill: paintSpec(kind: specColor, color: black),
        fillOpacity: 1, strokeOpacity: 1, strokeWidth: 1,
        miterLimit: 4, visible: true, opacity: 1, display: true,
        stopColor: paintSpec(kind: specColor, color: black),
        stopOpacity: 1)

## properties are the properties that attributes, style sheets and
## style attributes set.
var properties = [
  "fill", "fill-opacity", "fill-rule",
  "stroke", "stroke-width", "stroke-opacity", "stroke-linecap",
  "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray",
  "stroke-dashoffset",
  "opacity", "color", "display", "visibility", "paint-order",
  "clip-path", "clip-rule", "mask", "mask-type",
  "stop-color", "stop-opacity",
].toHashSet()

proc parseNumber(v: string): tuple[n: float64, ok: bool] =
  var p = scanner(s: v.strip())
  let (n, ok) = p.number()
  (n, ok and p.`done`())

## parseOpacity parses a number or percentage, clamped to [0, 1], or
## returns old.
proc parseOpacity(v: string; old: float64): float64 =
  let pct = v.endsWith("%")
  let s = if pct: v[0 ..< v.len - 1] else: v
  var (n, ok) = parseNumber(s)
  if not ok:
    return old
  if pct:
    n /= 100
  max(0, min(1, n))

## parseLength parses a length: a number with an optional unit, in
## pixels, or a percentage of base.
proc parseLength(v: string; base: float64): tuple[l: float64, ok: bool] =
  var p = scanner(s: v.strip())
  let (n, ok) = p.number()
  if not ok:
    return (0, false)
  case p.s[p.i ..< p.s.len].toLower()
  of "", "px": (n, true)
  of "%": (n * base / 100, true)
  of "pt": (n * 4 / 3, true)
  of "pc": (n * 16, true)
  of "in": (n * 96, true)
  of "cm": (n * 96 / 2.54, true)
  of "mm": (n * 96 / 25.4, true)
  of "q": (n * 96 / 101.6, true)
  of "em", "rem": (n * 16, true)
  of "ex": (n * 8, true)
  else: (0'f64, false)

## parseDashes parses a dash array: empty for a solid line, as none or
## an array in error asks, and of even length otherwise.
proc parseDashes(v: string; diag: float64): seq[float64] =
  if v == "none":
    return @[]
  var out0: seq[float64]
  var total = 0.0
  for f in v.split({' ', '\t', '\n', '\r', ','}):
    if f == "":
      continue
    let (l, ok) = parseLength(f, diag)
    if not ok or l < 0:
      return @[]
    out0.add(l)
    total += l
  if total <= 0:
    return @[]
  if out0.len mod 2 == 1:
    out0.add(out0)
  out0

proc urlID(v: string): string =
  ## Returns the id url(#id) refers to.
  let v = v.strip()
  if not v.startsWith("url("):
    return ""
  let `end` = v.find(')')
  if `end` < 0:
    return ""
  let `ref` = v[4 ..< `end`].strip().strip(chars = {'"', '\''})
  if not `ref`.startsWith("#"):
    return ""
  `ref`[1 ..< `ref`.len]

proc parsePaint(v: string): tuple[p: paintSpec, ok: bool]

proc parseHex(h: string): tuple[c: rgba, ok: bool] =
  var d: array[8, float64]
  for i in 0 ..< h.len:
    let c = h[i]
    if i >= d.len:
      return (rgba(), false)
    if c >= '0' and c <= '9':
      d[i] = float64(ord(c) - ord('0'))
    elif c >= 'a' and c <= 'f':
      d[i] = float64(ord(c) - ord('a') + 10)
    elif c >= 'A' and c <= 'F':
      d[i] = float64(ord(c) - ord('A') + 10)
    else:
      return (rgba(), false)
  case h.len
  of 3, 4:
    var c = rgba(r: d[0] * 17 / 255, g: d[1] * 17 / 255,
                 b: d[2] * 17 / 255, a: 1)
    if h.len == 4:
      c.a = d[3] * 17 / 255
    (c, true)
  of 6, 8:
    var c = rgba(r: (d[0] * 16 + d[1]) / 255,
                 g: (d[2] * 16 + d[3]) / 255,
                 b: (d[4] * 16 + d[5]) / 255, a: 1)
    if h.len == 8:
      c.a = (d[6] * 16 + d[7]) / 255
    (c, true)
  else:
    (rgba(), false)

## colorArgs splits the arguments of rgb() or hsl(), separated by
## commas or spaces, with the alpha after a slash in the latter syntax.
proc colorArgs(s: string): seq[string] =
  let s = s.replace("/", " / ")
  let f = s.split({' ', '\t', '\n', '\r', ','}).filterIt(it != "")
  if f.len == 5 and f[3] == "/":
    return @[f[0], f[1], f[2], f[4]]
  for a in f:
    if a == "/":
      return @[]
  f

proc parseRGB(s: string): tuple[c: rgba, ok: bool] =
  let args = colorArgs(s)
  if args.len != 3 and args.len != 4:
    return (rgba(), false)
  var c: array[4, float64]
  c[3] = 1
  for i, a in args:
    let pct = a.endsWith("%")
    let s = if pct: a[0 ..< a.len - 1] else: a
    let (n, ok) = parseNumber(s)
    if not ok:
      return (rgba(), false)
    if i == 3 and pct:
      c[i] = n / 100
    elif i == 3:
      c[i] = n
    elif pct:
      c[i] = n / 100
    else:
      c[i] = n / 255
    c[i] = max(0, min(1, c[i]))
  (rgba(r: c[0], g: c[1], b: c[2], a: c[3]), true)

proc parseHSL(s: string): tuple[c: rgba, ok: bool] =
  let args = colorArgs(s)
  if args.len != 3 and args.len != 4:
    return (rgba(), false)
  var h = args[0]
  var scale = 1.0
  if h.endsWith("deg"):
    h = h[0 ..< h.len - 3]
  elif h.endsWith("grad"):
    h = h[0 ..< h.len - 4]
    scale = 0.9
  elif h.endsWith("rad"):
    h = h[0 ..< h.len - 3]
    scale = 180 / PI
  elif h.endsWith("turn"):
    h = h[0 ..< h.len - 4]
    scale = 360
  let (hue0, ok) = parseNumber(h)
  if not ok:
    return (rgba(), false)
  var hue = hue0
  var v: array[3, float64]
  v[2] = 1
  for i, a in args[1 ..< args.len]:
    let pct = a.endsWith("%")
    let s = if pct: a[0 ..< a.len - 1] else: a
    var (n, ok) = parseNumber(s)
    if not ok or (i < 2 and not pct):
      return (rgba(), false)
    if pct:
      n /= 100
    v[i] = max(0, min(1, n))
  hue = hue * scale mod 360
  if hue < 0:
    hue += 360
  let
    sat = v[0]
    light = v[1]
  proc f(n: float64): float64 =
    let k = (n + hue / 30) mod 12
    let a = sat * min(light, 1 - light)
    light - a * max(-1, min(min(k - 3, 9 - k), 1))
  (rgba(r: f(0), g: f(8), b: f(4), a: v[2]), true)

## parseColor parses a CSS color: a name, #rgb, #rgba, #rrggbb,
## #rrggbbaa, rgb(), rgba(), hsl(), hsla() or transparent.
proc parseColor(v: string): tuple[c: rgba, ok: bool] =
  var v = v.strip()
  ## An ICC color follows the sRGB one, which is all that is drawn.
  let i = v.find("icc-color(")
  if i > 0:
    v = v[0 ..< i].strip()
  if v == "":
    return (rgba(), false)
  if v[0] == '#':
    return parseHex(v[1 ..< v.len])
  let lower = v.toLower()
  let open = lower.find('(')
  if open > 0 and lower.endsWith(")"):
    let
      name = lower[0 ..< open]
      args = lower[open + 1 ..< lower.len - 1]
    case name
    of "rgb", "rgba": return parseRGB(args)
    of "hsl", "hsla": return parseHSL(args)
    else: return (rgba(), false)
  if lower == "transparent":
    return (rgba(), true)
  if namedColors.contains(lower):
    let c = namedColors[lower]
    return (rgba(r: float64(c shr 16) / 255,
                 g: float64((c shr 8) and 0xff) / 255,
                 b: float64(c and 0xff) / 255, a: 1), true)
  (rgba(), false)

proc parsePaint(v: string): tuple[p: paintSpec, ok: bool] =
  if v == "none":
    return (paintSpec(kind: specNone), true)
  if v.toLower() == "currentcolor":
    return (paintSpec(kind: specCurrent), true)
  if v.startsWith("url("):
    let id = urlID(v)
    if id == "":
      return (paintSpec(), false)
    var p = paintSpec(kind: specURL, id: id)
    let rest = v[v.find(')') + 1 ..< v.len].strip()
    if rest != "":
      let (fb, ok) = parsePaint(rest)
      if not ok or fb.kind == specURL:
        return (paintSpec(), false)
      p.fallback = fb.kind
      p.color = fb.color
    return (p, true)
  let (c, ok) = parseColor(v)
  (paintSpec(kind: specColor, color: c), ok)

## strokeFirst reports whether a paint-order paints the stroke before
## the fill.
proc strokeFirst(v: string): bool =
  for f in v.splitWhiteSpace():
    case f
    of "stroke": return true
    of "fill": return false
    else: discard
  false

## inherit takes a property from the parent's style, undoing what an
## earlier declaration set.
proc inherit(s: var style; name: string; p: ptr style) =
  case name
  of "fill": s.fill = p.fill
  of "stroke": s.stroke = p.stroke
  of "fill-opacity": s.fillOpacity = p.fillOpacity
  of "stroke-opacity": s.strokeOpacity = p.strokeOpacity
  of "fill-rule": s.fillEvenOdd = p.fillEvenOdd
  of "clip-rule": s.clipEvenOdd = p.clipEvenOdd
  of "stroke-width": s.strokeWidth = p.strokeWidth
  of "stroke-miterlimit": s.miterLimit = p.miterLimit
  of "stroke-linecap": s.cap = p.cap
  of "stroke-linejoin": s.join = p.join
  of "stroke-dasharray": s.dashes = p.dashes
  of "stroke-dashoffset": s.dashOffset = p.dashOffset
  of "color": s.color = p.color; s.colorSet = p.colorSet
  of "visibility": s.visible = p.visible
  of "paint-order": s.strokeFirst = p.strokeFirst
  of "opacity": s.opacity = p.opacity
  of "display": s.display = p.display
  of "clip-path": s.clipPath = p.clipPath
  of "mask": s.mask = p.mask
  of "mask-type": s.maskAlpha = p.maskAlpha
  of "stop-color": s.stopColor = p.stopColor
  of "stop-opacity": s.stopOpacity = p.stopOpacity
  else: discard

## computeStyle computes the style of e, a child of an element of style
## parent, with lengths in percent of the viewport vw×vh.
proc computeStyle(e: elem; parent: ptr style; vw, vh: float64): style =
  var s = parent[]
  s.opacity = 1
  s.display = true
  s.clipPath = ""
  s.mask = ""
  s.maskAlpha = false
  s.stopColor = paintSpec(kind: specColor, color: black)
  s.stopOpacity = 1
  let diag = sqrt((vw * vw + vh * vh) / 2)
  for d in e.props:
    let v = d.value
    if v == "inherit":
      s.inherit(d.name, parent)
      continue
    case d.name
    of "fill":
      let (p, ok) = parsePaint(v)
      if ok: s.fill = p
    of "stroke":
      let (p, ok) = parsePaint(v)
      if ok: s.stroke = p
    of "fill-opacity":
      s.fillOpacity = parseOpacity(v, s.fillOpacity)
    of "stroke-opacity":
      s.strokeOpacity = parseOpacity(v, s.strokeOpacity)
    of "opacity":
      s.opacity = parseOpacity(v, s.opacity)
    of "stop-opacity":
      s.stopOpacity = parseOpacity(v, s.stopOpacity)
    of "fill-rule":
      if v == "evenodd" or v == "nonzero":
        s.fillEvenOdd = v == "evenodd"
    of "clip-rule":
      if v == "evenodd" or v == "nonzero":
        s.clipEvenOdd = v == "evenodd"
    of "stroke-width":
      let (w, ok) = parseLength(v, diag)
      if ok and w >= 0: s.strokeWidth = w
    of "stroke-miterlimit":
      let (l, ok) = parseNumber(v)
      if ok and l >= 1: s.miterLimit = l
    of "stroke-linecap":
      case v
      of "butt": s.cap = capButt
      of "round": s.cap = capRound
      of "square": s.cap = capSquare
      else: discard
    of "stroke-linejoin":
      case v
      of "miter", "miter-clip", "arcs": s.join = joinMiter
      of "round": s.join = joinRound
      of "bevel": s.join = joinBevel
      else: discard
    of "stroke-dasharray":
      s.dashes = parseDashes(v, diag)
    of "stroke-dashoffset":
      let (o, ok) = parseLength(v, diag)
      if ok: s.dashOffset = o
    of "color":
      if v.cmpIgnoreCase("currentColor") != 0:
        let (c, ok) = parseColor(v)
        if ok:
          s.color = c
          s.colorSet = true
    of "display":
      s.display = v != "none"
    of "visibility":
      if v == "visible" or v == "hidden" or v == "collapse":
        s.visible = v == "visible"
    of "paint-order":
      s.strokeFirst = strokeFirst(v)
    of "clip-path":
      s.clipPath = urlID(v)
    of "mask":
      s.mask = urlID(v)
    of "mask-type":
      s.maskAlpha = v == "alpha"
    of "stop-color":
      if v.cmpIgnoreCase("currentColor") == 0:
        s.stopColor = paintSpec(kind: specCurrent)
      else:
        let (c, ok) = parseColor(v)
        if ok:
          s.stopColor = paintSpec(kind: specColor, color: c)
    else: discard
  s

## aspect is a preserveAspectRatio: how a viewBox fits its viewport.
type aspect = object
  none: bool
  ax, ay: float64 ## where it aligns: 0 at the start, 0.5 in the middle, 1 at the end
  slice: bool

proc parseAspect(v: string): aspect =
  result = aspect(ax: 0.5, ay: 0.5)
  var f = v.splitWhiteSpace()
  if f.len > 0 and f[0] == "defer":
    f = f[1 ..< f.len]
  if f.len == 0:
    return
  if f[0] == "none":
    result.none = true
    return
  let pos = {"Min": 0.0, "Mid": 0.5, "Max": 1.0}.toTable()
  let al = f[0]
  if al.len != 8 or al[0] != 'x' or al[4] != 'Y':
    return
  let
    (x, okX) = try: (pos[al[1 .. 3]], true) except KeyError: (0.0, false)
    (y, okY) = try: (pos[al[5 .. 7]], true) except KeyError: (0.0, false)
  if not okX or not okY:
    return
  result.ax = x
  result.ay = y
  result.slice = f.len > 1 and f[1] == "slice"

## viewBoxTransform maps a viewBox to a viewport w×h as a says.
proc viewBoxTransform(vb: box; a: aspect; w, h: float64): matrix =
  if vb.w <= 0 or vb.h <= 0:
    return identity
  let
    sx = w / vb.w
    sy = h / vb.h
  if a.none:
    return [sx, 0'f64, 0, sy, -vb.x * sx, -vb.y * sy]
  var s = min(sx, sy)
  if a.slice:
    s = max(sx, sy)
  [s, 0'f64, 0, s, -vb.x * s + (w - vb.w * s) * a.ax,
   -vb.y * s + (h - vb.h * s) * a.ay]

proc parseViewBox(v: string): tuple[b: box, ok: bool] =
  ## Parses the four numbers of a viewBox.
  let n = numbers(v)
  if n.len != 4 or n[2] <= 0 or n[3] <= 0:
    return (box(), false)
  (box(x: n[0], y: n[1], w: n[2], h: n[3]), true)
