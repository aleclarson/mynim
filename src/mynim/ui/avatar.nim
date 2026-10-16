## Circular image or initials avatar.

proc avatarInitials(name: string): string =
  var first, last = Rune(0)
  var inWord = false
  for rune in name.runes:
    let category = lookupGeneralCategory(int32(rune))
    let word = category in {Ll, Lm, Lo, Lt, Lu, Nd}
    if word and not inWord:
      if first == Rune(0):
        first = rune.toUpper
      else:
        last = rune.toUpper
    inWord = word
  if first != Rune(0):
    result.add(first)
    if last != Rune(0):
      result.add(last)

proc avatarColor(name: string): Color =
  var hash = 2166136261'u32
  for value in name:
    hash = uint32(((hash xor uint32(ord(value))).uint64 * 16777619'u64) and
      0xFFFF_FFFF'u64)

  let hue = float64(hash mod 360'u32)
  let saturation = 0.45
  let lightness = 0.55
  let chroma = (1 - abs(2 * lightness - 1)) * saturation
  let sector = hue / 60
  let sectorModulo = sector - floor(sector / 2) * 2
  let x = chroma * (1 - abs(sectorModulo - 1))
  let offset = lightness - chroma / 2
  var red, green, blue: float64
  if hue < 60:
    red = chroma
    green = x
  elif hue < 120:
    red = x
    green = chroma
  elif hue < 180:
    green = chroma
    blue = x
  elif hue < 240:
    green = x
    blue = chroma
  elif hue < 300:
    red = x
    blue = chroma
  else:
    red = chroma
    blue = x
  rgb(uint8(int((red + offset) * 255)),
    uint8(int((green + offset) * 255)),
    uint8(int((blue + offset) * 255)))

proc avatar*(c: Context; name: string; image: Bitmap = nil): Element =
  ## Creates a circular avatar with an image, or initials on a stable color.
  ## Assistive technology sees an image named `name`.
  let theme = c.theme
  let size = theme.fontSize * 2.25'f32
  result = c.box().size(size, size).radius(size / 2).clip().shrink(0).center()
  let node = result.node
  if node == nil:
    return
  node[].label = name
  node[].accessRole = platform.roleImage
  node[].accessRoleSet = true

  if image != nil:
    discard result.children(proc() =
      discard c.image(image).size(size, size).fit(Fit.Cover)
    )
    return

  discard result.background(avatarColor(name))
  let initials = avatarInitials(name)
  if initials.len > 0:
    let text = c.text(initials).textSize(size * 0.4'f32)
      .textWeight(600).textColor(rgb(255, 255, 255))
    let textNode = text.node
    if textNode != nil:
      textNode[].textNoWrap = true
