## color.go — the public color type and CSS color parsing.

## Color is an 8-bit sRGB color with straight (not premultiplied) alpha.
## Its zero value is transparent.
type Color* = object
  r*, g*, b*, a*: uint8

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

proc toPlatform(c: Color): platform.Color =
  platform.Color(r: c.r, g: c.g, b: c.b, a: c.a)

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

type Background = object
  ## A window background: one color, or a light and a dark one that
  ## follow the app's appearance.
  light, dark: platform.Color

proc parseBackground(s: string): Background =
  ## Parses a CSS color or light-dark(<light>, <dark>).
  let low = s.strip().toLowerAscii()
  if not low.startsWith("light-dark("):
    let c = parseColor(s).toPlatform()
    return Background(light: c, dark: c)
  var args = low
  args.removePrefix("light-dark(")
  if not args.endsWith(")"):
    raise newException(ValueError, "mynim: invalid color " & s.escape())
  args = args[0..^2]
  # Split at the comma outside of rgb(…).
  var depth = 0
  for i, r in args:
    case r
    of '(': inc depth
    of ')': dec depth
    of ',':
      if depth == 0:
        try:
          let light = parseColor(args[0..<i]).toPlatform()
          let dark = parseColor(args[i + 1..^1]).toPlatform()
          return Background(light: light, dark: dark)
        except ValueError:
          discard
    else: discard
  raise newException(ValueError, "mynim: invalid color " & s.escape())
