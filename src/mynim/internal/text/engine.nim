## engine.go + stub.go: the engine interface the system's own text
## stack implements (DirectWrite, Core Text, Pango), the scratch room
## engines embed, shared helpers and the stub engine.

type shapeScratchRoom* = object
  ## Room engines take the glyphs, runs and lines shape returns from,
  ## which live until the System lays out the next text. Engines embed
  ## it.
  glyphs: seq[Glyph]
  runs: seq[shapedRun]
  lines: seq[shapedLine]

type Engine* = ref object of RootObj
  ## The system's own text stack. The System calls it with its lock
  ## held, so engines need no locking of their own.
  scratch*: shapeScratchRoom

const maxScratch = 4096

proc resetScratch*(s: var shapeScratchRoom) =
  s.glyphs.setLen(0)
  s.runs.setLen(0)
  s.lines.setLen(0)

proc glyphRoom*(s: var shapeScratchRoom, n: int): seq[Glyph] =
  ## Room for n glyphs until the next layout. (The Go version takes the
  ## room out of a shared buffer; a seq is the same semantically.)
  newSeq[Glyph](n)

proc addRun*(s: var shapeScratchRoom, mark: int, r: shapedRun): seq[shapedRun] =
  s.runs.add r
  s.runs[mark .. ^1]

proc addLine*(s: var shapeScratchRoom, mark: int, l: shapedLine): seq[shapedLine] =
  s.lines.add l
  s.lines[mark .. ^1]

method font*(e: Engine, style: Style): Font {.base.} =
  ## The font a style asks for, at its size: the first family of the
  ## style the system has, or its user interface font.
  raiseAssert "engine.font not implemented"

method shape*(e: Engine, text: openArray[Rune], style: Style,
              spans: openArray[Span], width: float32, rtl,
              wholeWords: bool): seq[shapedLine] {.base.} =
  ## Breaks text, a paragraph without newlines, into lines of at most
  ## width DIPs, or into one line when width is 0, and shapes them.
  raiseAssert "engine.shape not implemented"

method glyph*(e: Engine, f: Font, id: uint32, scale, dx: float32,
              shade: Shade, subpixel: bool): bitmap {.base.} =
  ## Rasterizes glyph id of f at scale pixels per DIP, its origin dx
  ## pixels right of the left edge of a pixel, for text of a shade when
  ## f is shaded or the shade is Thick, with subpixel antialiasing if
  ## subpixel.
  raiseAssert "engine.glyph not implemented"

method positions*(e: Engine, f: Font, scale: float32,
                  subpixel: bool): tuple[n: int, round: bool] {.base.} =
  ## How many horizontal positions within a pixel glyphs of f at scale
  ## pixels per DIP are drawn at, and whether a pen goes to the nearest
  ## (round) or to the one left of it.
  (1, true)

method baseline*(e: Engine, y: float32): float32 {.base.} =
  ## The whole pixel a baseline y device pixels from the top is drawn at.
  round(y)

method decorate*(e: Engine, r: decoRange): seq[Stroke] {.base.} =
  ## The strokes of a decoration (see System.decorate).
  @[]

method join*(e: Engine): bool {.base.} =
  ## Whether the engine's text stack adds the coverage of the glyphs of
  ## a run whose edges share pixels before blending it.
  false

method textParams*(e: Engine): tuple[p: scene.TextParams, subpixel: bool] {.base.} =
  ## How renderers correct the coverage of glyphs, and whether glyphs
  ## take subpixel antialiasing, as the system's settings say.
  (scene.TextParams(), false)

method register*(e: Engine, data: openArray[byte], family: string) {.base.} =
  ## Adds the fonts of a font file under family, or under their own
  ## family names when family is "".
  raise newException(ValueError, "mynim: this system has no text engine to add fonts to")

method families*(e: Engine, mono: bool): tuple[app, system: seq[string]] {.base.} =
  ## The families text can use: the app's, under the names it registered
  ## fonts with and their own, and the system's; the monospaced ones
  ## only when mono.
  (@[], @[])

method resetEngineScratch*(e: Engine) {.base.} =
  e.scratch.resetScratch()

## Optional engine capabilities (Go's fontForgetter/uiFamilySetter/
## fontRenderer interfaces).

method fontCount*(e: Engine): int {.base.} = -1
method forgetFonts*(e: Engine) {.base.} = discard
method setUIFamily*(e: Engine, family: string) {.base.} = discard
method hasUIFamily*(e: Engine): bool {.base.} = false
method setFontRendering*(e: Engine, antialias, hinting, subpixels: string) {.base.} =
  discard
method hasFontRendering*(e: Engine): bool {.base.} = false

proc weight*(s: Style): int =
  if s.weight <= 0: 400 else: min(s.weight, 999)

proc fontSize*(s: Style): float32 =
  if s.size <= 0: 14 else: s.size

proc style*(sp: Span, base: Style): Style =
  ## The style of the span's runes in a text of style base.
  result = base
  if sp.family != "": result.family = sp.family
  if sp.size > 0: result.size = sp.size
  if sp.weight > 0: result.weight = sp.weight
  if sp.italic: result.italic = true
  if sp.letterSpacing != 0: result.letterSpacing = sp.letterSpacing
  if sp.features != "": result.features = sp.features
  if sp.lang != "": result.lang = sp.lang

# -- EncodeSpans/DecodeSpans: uvarint + little-endian encoding --

proc appendUvarint(b: var seq[byte], v: uint64) =
  var v = v
  while v >= 0x80:
    b.add byte((v and 0x7F) or 0x80)
    v = v shr 7
  b.add byte(v)

proc readUvarint(s: string, pos: var int): tuple[v: uint64, ok: bool] =
  var v: uint64 = 0
  var shift = 0
  while pos < s.len and shift < 70:
    let x = byte(s[pos])
    inc pos
    v = v or (uint64(x and 0x7F) shl shift)
    if x < 0x80:
      return (v, true)
    shift += 7
  (0, false)

proc appendF32(b: var seq[byte], v: float32) =
  let u = cast[uint32](v)
  for i in 0 .. 3:
    b.add byte(u shr (i * 8))

proc readF32(s: string, pos: var int): tuple[v: float32, ok: bool] =
  if pos + 4 > s.len:
    return (0, false)
  var u = 0'u32
  for i in 0 .. 3:
    u = u or (uint32(s[pos + i]) shl (i * 8))
  pos += 4
  (cast[float32](u), true)

proc readStr(s: string, pos: var int): tuple[v: string, ok: bool] =
  let (n, ok) = readUvarint(s, pos)
  if not ok or int(n) > s.len - pos:
    return ("", false)
  let v = s[pos ..< pos + int(n)]
  pos += int(n)
  (v, true)

proc encodeSpans*(spans: openArray[Span]): string =
  var b: seq[byte]
  let str = proc(b: var seq[byte], s: string) =
    b.appendUvarint(uint64(s.len))
    for c in s: b.add byte(c)
  for sp in spans:
    b.appendUvarint(uint64(max(sp.`end`, 0)))
    b.str(sp.family)
    b.appendF32(sp.size)
    b.appendUvarint(uint64(max(sp.weight, 0)))
    b.add byte(sp.italic.ord)
    b.appendF32(sp.letterSpacing)
    b.str(sp.features)
    b.appendF32(sp.objectWidth)
    b.appendF32(sp.objectHeight)
    b.str(sp.lang)
  cast[string](b)

proc decodeSpans*(s: string): seq[Span] =
  ## Reads what encodeSpans wrote.
  var pos = 0
  while pos < s.len:
    var sp: Span
    var bad = false
    let (e, ok0) = readUvarint(s, pos)
    if not ok0: bad = true
    sp.`end` = int(e)
    let (fam, ok1) = readStr(s, pos)
    if not ok1: bad = true
    sp.family = fam
    let (sz, ok2) = readF32(s, pos)
    if not ok2: bad = true
    sp.size = sz
    let (w, ok3) = readUvarint(s, pos)
    if not ok3: bad = true
    sp.weight = int(w)
    if pos < s.len:
      sp.italic = s[pos] != '\0'
      inc pos
    else:
      bad = true
    let (ls, ok4) = readF32(s, pos)
    if not ok4: bad = true
    sp.letterSpacing = ls
    let (feat, ok5) = readStr(s, pos)
    if not ok5: bad = true
    sp.features = feat
    let (ow, ok6) = readF32(s, pos)
    if not ok6: bad = true
    sp.objectWidth = ow
    let (oh, ok7) = readF32(s, pos)
    if not ok7: bad = true
    sp.objectHeight = oh
    let (lg, ok8) = readStr(s, pos)
    if not ok8: bad = true
    sp.lang = lg
    if bad:
      break
    result.add sp

proc spansIn(spans: openArray[Span], start, `end`: int): seq[Span] =
  ## The spans of runes start to end of a text, their ends relative to
  ## start.
  var `from` = 0
  for sp0 in spans:
    var sp = sp0
    let s0 = `from`
    `from` = max(sp.`end`, `from`)
    if `from` <= start: continue
    if s0 >= `end`: break
    sp.`end` = min(`from`, `end`) - start
    result.add sp

# -- engine helpers --

proc generic(family: string): string =
  ## The families "system-ui", "sans-serif", "serif" and "monospace"
  ## stand for, and their aliases; "" when family is none.
  case toLowerAscii(family)
  of "", "system-ui", "ui-sans-serif", "-apple-system", "blinkmacsystemfont": "system-ui"
  of "sans-serif": "sans-serif"
  of "serif", "ui-serif": "serif"
  of "monospace", "ui-monospace": "monospace"
  else: ""

proc features*(list: string): seq[feature] =
  ## Parses Style.features, leaving out what is not a tag of four
  ## printable characters with an optional =value.
  if list == "": return
  for item in list.split(','):
    var it = strip(item)
    let eq = find(it, '=')
    var tag = it
    var f = feature(value: 1)
    if eq >= 0:
      let value = it[eq + 1 .. ^1]
      tag = it[0 ..< eq]
      try:
        f.value = uint32(parseUInt(strip(value)))
      except ValueError:
        continue
    tag = strip(tag)
    if tag.len != 4: continue
    var bad = false
    for c in tag:
      if ord(c) < 0x20 or ord(c) > 0x7E: bad = true
    if bad: continue
    for i in 0 .. 3: f.tag[i] = byte(tag[i])
    result.add f

proc familyList*(family: string): seq[string] =
  ## A comma-separated list of families, without quotes.
  for f0 in family.split(','):
    let f = strip(strip(f0), chars = {'"', '\''})
    if f != "":
      result.add f

proc appendUTF16(text: var seq[uint16], index: var seq[int], runes: openArray[Rune]) =
  for i, r in runes:
    let c = int32(r)
    if c >= 0x10000 and c <= 0x10FFFF:
      let v = c - 0x10000
      text.add uint16(0xD800 + (v shr 10))
      text.add uint16(0xDC00 + (v and 0x3FF))
      index.add i
      index.add i
      continue
    var v = c
    if v > 0xFFFF or (v >= 0xD800 and v < 0xE000):
      v = 0xFFFD
    text.add uint16(v)
    index.add i
  index.add runes.len

proc utf16Text*(runes: openArray[Rune]): tuple[text: seq[uint16], index: seq[int]] =
  ## Runes as UTF-16, with the rune index of every code unit and of the
  ## end.
  result.text = newSeqOfCap[uint16](runes.len + 1)
  result.index = newSeqOfCap[int](runes.len + 1)
  appendUTF16(result.text, result.index, runes)

proc utf8Text*(runes: openArray[Rune]): tuple[text: seq[byte], index: seq[int]] =
  ## Runes as UTF-8, with the rune index of every byte and of the end.
  result.text = newSeqOfCap[byte](runes.len + 1)
  result.index = newSeqOfCap[int](runes.len + 1)
  for i, r in runes:
    let n = result.text.len
    let u = $r
    for k in 0 ..< u.len:
      result.text.add byte(u[k])
    for _ in 0 ..< result.text.len - n:
      result.index.add i
  result.index.add runes.len

## --- stub.go ---

type StubEngine* = ref object of Engine
  ## Lays out text without fonts where the system has no text engine:
  ## every rune takes half an em and draws nothing.
  fonts: Table[float32, Font]

method font*(e: StubEngine, style: Style): Font =
  let size = style.fontSize()
  if e.fonts.hasKey(size):
    return e.fonts[size]
  let f = Font(size: size, ascent: size * 0.8, descent: size * 0.2)
  e.fonts[size] = f
  f

method shape*(e: StubEngine, text: openArray[Rune], style: Style,
              spans: openArray[Span], width: float32, rtl,
              wholeWords: bool): seq[shapedLine] =
  let f = e.font(style)
  var run = shapedRun(font: f, `end`: text.len)
  for i in 0 ..< text.len:
    run.glyphs.add Glyph(font: f, x: float32(i) * f.size / 2,
                         advance: f.size / 2, cluster: i, rtl: rtl)
  @[shapedLine(`end`: text.len, runs: @[run])]

method glyph*(e: StubEngine, f: Font, id: uint32, scale, dx: float32,
              shade: Shade, subpixel: bool): bitmap =
  bitmap()


