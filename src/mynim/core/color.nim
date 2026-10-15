## Public core alias for UI colors and window background parsing.

type Color* = uiPackage.Color

type Background = object
  ## A window background: one color, or a light and a dark one that
  ## follow the app's appearance.
  light, dark: platform.Color

proc toPlatform(c: Color): platform.Color =
  platform.Color(r: c.r, g: c.g, b: c.b, a: c.a)

proc parseBackground(s: string): Background =
  ## Parses a CSS color or light-dark(<light>, <dark>).
  let low = s.strip().toLowerAscii()
  if not low.startsWith("light-dark("):
    let c = uiPackage.parseColor(s).toPlatform()
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
          let light = uiPackage.parseColor(args[0..<i]).toPlatform()
          let dark = uiPackage.parseColor(args[i + 1..^1]).toPlatform()
          return Background(light: light, dark: dark)
        except ValueError:
          discard
    else: discard
  raise newException(ValueError, "mynim: invalid color " & s.escape())
