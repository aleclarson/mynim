## access_text.go: the attributed string of the UTF-16 range of a text
## field's value, with the formats of its runs in the keys of
## NSAccessibility (AXFont, AXForegroundColor, AXUnderline, …).

## utf16Units is the UTF-16 offset of each rune of s.
proc utf16Units(s: string): seq[int] =
  result = newSeq[int](s.runeLen + 1)
  var i = 0
  for c in s.runes:
    inc i
    result[i] = result[i - 1] + (
      if ord(c) >= 0x10000: 2 else: 1)

## utf16Slice is s cut to the UTF-16 range [lo, hi).
proc utf16Slice(s: string, lo, hi: int): string =
  var res = newStringOfCap(s.len)
  var u = 0
  for c in s.runes:
    let w = (if ord(c) >= 0x10000: 2 else: 1)
    if u >= hi:
      break
    if u >= lo:
      res.add $c
    u += w
  res

## nsFontWeight returns the NSFontWeight of a CSS weight.
proc nsFontWeight(w: int): float64 =
  if w <= 0: return 0
  if w < 200: return -0.8
  if w < 300: return -0.6
  if w < 400: return -0.4
  if w < 500: return 0
  if w < 600: return 0.23
  if w < 700: return 0.3
  if w < 800: return 0.4
  if w < 900: return 0.56
  0.62

## nsColor returns the NSColor of a platform color.
proc nsColor*(c: platform.Color): id =
  msgColor(`class`("NSColor"), sel("colorWithSRGBRed:green:blue:alpha:"),
           float64(c.r) / 255, float64(c.g) / 255,
           float64(c.b) / 255, float64(c.a) / 255)

## accessColor returns the CGColor of an RGBA color, which the NSColor
## autoreleased with it keeps.
proc accessColor(c: array[4, uint8]): id =
  send(nsColor(platform.Color(r: c[0], g: c[1], b: c[2], a: c[3])),
       "CGColor")

## accessFont returns the AXFont of a run: the dictionary of its font's
## name, family and size, the font as AppKit finds it for the run's
## family, weight and italics.
proc accessFont(run: AccessTextRun): id =
  var size = float64(run.size)
  if size <= 0:
    size = 14
  var font: id
  if run.family == "monospace":
    font = msgFloat2ID(`class`("NSFont"),
      sel("monospacedSystemFontOfSize:weight:"), size,
      nsFontWeight(run.weight))
  elif run.family != "" and run.family != "system-ui":
    var traits = 0u
    if run.weight >= 600:
      traits = traits or 2 ## NSBoldFontMask
    if run.italic:
      traits = traits or 1 ## NSItalicFontMask
    font = msgFontFamily(
      send(`class`("NSFontManager"), "sharedFontManager"),
      sel("fontWithFamily:traits:weight:size:"),
      nsString(run.family), traits, 5, size)
  if font.isNil:
    font = msgFloat2ID(`class`("NSFont"),
      sel("systemFontOfSize:weight:"), size, nsFontWeight(run.weight))
    if run.italic and not font.isNil:
      font = send(send(`class`("NSFontManager"), "sharedFontManager"),
                  "convertFont:toHaveTrait:", argu(font), argu(1))
  let d = send(`class`("NSMutableDictionary"), "dictionary")
  if not font.isNil:
    let name = send(font, "fontName")
    discard send(d, "setObject:forKey:", argu(name),
                 argu(nsString("AXFontName")))
    discard send(d, "setObject:forKey:", argu(send(font, "familyName")),
                 argu(nsString("AXFontFamily")))
    discard send(d, "setObject:forKey:", argu(send(font, "displayName")),
                 argu(nsString("AXVisibleName")))
  discard send(d, "setObject:forKey:",
    argu(msgFloatID(`class`("NSNumber"), sel("numberWithDouble:"), size)),
    argu(nsString("AXFontSize")))
  d

## attributedAccessString returns the attributed string of the UTF-16
## range r of a text field's value, autoreleased.
proc attributedAccessString(n: AccessNode, r: nsRange): id =
  let runes = n.value
  let runeCount = runes.runeLen
  ## the UTF-16 length of the value
  let total = block:
    var t = 0
    for c in runes.runes:
      t += (if ord(c) >= 0x10000: 2 else: 1)
    t
  let lo0 = min(r.location.int, total)
  let hi = min(lo0 + r.length.int, total)
  let str = nsString(utf16Slice(runes, lo0, hi))
  let res = autorelease(send(
    send(`class`("NSMutableAttributedString"), "alloc"),
    "initWithString:", argu(str)))
  if hi == lo0:
    return res
  ## The UTF-16 offset of each rune.
  let units = utf16Units(runes)
  proc add(key: string; value: id; a0, z0: int) =
    let a = max(a0, lo0)
    let z = min(z0, hi)
    if value.isNil or a >= z:
      return
    discard send(res, "addAttribute:value:range:", argu(nsString(key)),
                 argu(value), argu(a - lo0), argu(z - a))
  add("AXFont", accessFont(AccessTextRun()), lo0, hi)
  for run in n.textRuns:
    let a = units[max(0, min(run.start, runeCount))]
    let z = units[max(0, min(run.`end`, runeCount))]
    if z <= lo0 or a >= hi:
      continue
    add("AXFont", accessFont(run), a, z)
    if run.color[3] > 0:
      add("AXForegroundColor", accessColor(run.color), a, z)
    if run.background[3] > 0:
      add("AXBackgroundColor", accessColor(run.background), a, z)
    if run.underline:
      add("AXUnderline", nsNumberInt(1), a, z)
    if run.strikethrough:
      add("AXStrikethrough", nsBool(true), a, z)
    if run.link != "":
      let url = send(`class`("NSURL"), "URLWithString:",
                     argu(nsString(run.link)))
      if not url.isNil:
        add("AXLink", url, a, z)
  res
