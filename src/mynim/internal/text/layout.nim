## layout.go (part): the System and the layout pipeline.

type System* = ref object
  ## Lays out text and rasterizes glyphs with the system's own text
  ## engine. All methods are safe from any thread.
  mu: Lock
  eng: Engine
  ## uiFamily is the family system-ui stands for where the engine does
  ## not know it; rendering the desktop's settings for rasterizing text.
  uiFamily: string
  rendering: array[3, string]
  hasRendering: bool
  lang: string ## the language of texts whose style names none
  fonts: Table[Style, Font]

  ## Layouts are kept by recency within a memory budget.
  layouts: Table[Params, cached]
  oldest, newest: cached
  layoutBytes: int
  frame: uint64
  made, gen: uint64

  glyphs: Table[glyphKey, atlasEntry]
  places: Table[placeKey, placement]
  runs: Table[runKey, atlasEntry]
  masks: Table[uint64, atlasEntry]
  ## transient holds the masks drawn for the frame being painted alone,
  ## recent the frame each was last drawn in.
  transient: Table[uint64, GlyphImage]
  recent: Table[uint64, uint64]
  maskAtlas*, colorAtlas*: scene.Atlas
  ## full tells which atlases (mask, color) left out something the frame
  ## draws, and want how many pixels that needed; failed counts failed
  ## allocations.
  full: array[2, bool]
  want: array[2, int]
  wantSize: array[2, image.Point]
  failed: int
  ## subpixel tells that the system's settings ask for subpixel
  ## antialiasing (TextParams).
  subpixel: bool
  rooms: int
  ## marks caches the width of the ellipsis of each style.
  marks: Table[markKey, float32]

const
  liveLayoutFrames = 8
  maxLiveLayoutBytes = 64 shl 20
  maxLayoutBytes = 8 shl 20
  maxLayouts = 4096
  maxFonts = 512

## --- helpers first (Nim orders declarations before use) ---

proc isRTLRune(r: Rune): bool =
  ## unicode.In(r, Hebrew, Arabic, Syriac, Thaana, Nko, Samaritan,
  ## Mandaic, Adlam).
  let c = int32(r)
  (c >= 0x0590 and c <= 0x05FF) or (c >= 0xFB1D and c <= 0xFB4F) or # Hebrew
    (c >= 0x0600 and c <= 0x06FF) or (c >= 0x0750 and c <= 0x077F) or # Arabic
    (c >= 0x0870 and c <= 0x089F) or (c >= 0x08A0 and c <= 0x08FF) or
    (c >= 0xFB50 and c <= 0xFDFF) or (c >= 0xFE70 and c <= 0xFEFF) or
    (c >= 0x10EC0 and c <= 0x10EFF) or (c >= 0x1EE00 and c <= 0x1EEFF) or
    (c >= 0x0700 and c <= 0x074F) or (c >= 0x0860 and c <= 0x086F) or # Syriac
    (c >= 0x0780 and c <= 0x07BF) or # Thaana
    (c >= 0x07C0 and c <= 0x07FF) or # Nko
    (c >= 0x0800 and c <= 0x083F) or # Samaritan
    (c >= 0x0840 and c <= 0x085F) or # Mandaic
    (c >= 0x1E900 and c <= 0x1E95F) # Adlam

proc isRTL(para: openArray[Rune], neutral: bool): bool =
  ## Whether a paragraph is right-to-left: whether its first strongly
  ## directional rune is, else neutral.
  for r in para:
    if isRTLRune(r):
      return true
    if isAlpha(r):
      return false
  neutral

proc objectAt(spans: openArray[Span], i: int): ptr Span =
  ## The span of rune i if it makes it an inline object, else nil.
  var lo = 0
  var hi = spans.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if spans[mid].`end` <= i:
      lo = mid + 1
    else:
      hi = mid
  if lo < spans.len and spans[lo].objectWidth > 0:
    return unsafeAddr spans[lo]
  nil

proc glyphCount(sl: shapedLine): int =
  for run in sl.runs:
    result += run.glyphs.len

proc advance(sl: shapedLine): float32 =
  ## The width a shaped line's glyphs take.
  for run in sl.runs:
    for g in run.glyphs:
      result += g.advance
  max(result, 0)

proc metricsOf(f: Font, style: Style): lineMetrics =
  ## The vertical metrics of a style's lines.
  let size = style.fontSize()
  result = lineMetrics(ascent: size * 0.8, descent: size * 0.2)
  var gap = 0'f32
  if not f.isNil and f.ascent > 0:
    result.ascent = f.ascent
    result.descent = f.descent
    gap = max(f.lineGap, 0)
  result.lineHeight = result.ascent + result.descent + gap
  if style.lineHeight > 0:
    result.lineHeight = style.lineHeight * size

proc line(p: Params, text: openArray[Rune], sl: shapedLine, offset: int,
          rtl: bool, m: lineMetrics, y: var float32,
          buf: var seq[int], spans: openArray[Span]): Line =
  ## Positions a line of the paragraph text, which starts at rune offset
  ## of the layout, with its top at y, and moves y past it.
  result = Line(start: offset + sl.start, `end`: offset + sl.`end`,
                rtl: rtl, ascent: m.ascent, descent: m.descent)
  ## Whitespace ending a line takes no room, unless kept.
  var trim = sl.`end`
  if not p.keepSpaces:
    while trim > sl.start and isWhiteSpace(text[trim - 1]):
      dec trim
  let size = p.style.fontSize()
  var x0 = float32.high
  var starts = buf
  for run in sl.runs:
    var runSize = size
    if not run.font.isNil:
      result.ascent = max(result.ascent, run.font.ascent)
      result.descent = max(result.descent, run.font.descent)
      if run.font.size > 0:
        runSize = run.font.size # a span of another size
    ## A cluster holds the runes up to the next one of its run.
    starts.setLen(0)
    for g in run.glyphs:
      if g.cluster >= 0:
        starts.add g.cluster
    starts.sort()
    # slices.Compact: drop consecutive duplicates.
    if starts.len > 0:
      var w = 0
      for i in 1 ..< starts.len:
        if starts[i] != starts[w]:
          inc w
          starts[w] = starts[i]
      starts.setLen(w + 1)
    for g0 in run.glyphs:
      var g = g0
      if g.cluster < 0: # the ellipsis
        g.cluster = result.`end`
      else:
        if g.cluster >= trim and g.cluster < sl.`end`:
          continue
        var next = run.`end`
        let k = lowerBound(starts, g.cluster)
        if k + 1 < starts.len:
          next = starts[k + 1]
        g.runes = max(next - g.cluster, 1)
        let o = objectAt(spans, g.cluster)
        if not o.isNil:
          ## An inline object stands on the baseline, as high as it is,
          ## whatever font its run took.
          g.`object` = true
          g.advance = o.objectWidth
          g.id = 0
          result.ascent = max(result.ascent, o.objectHeight)
        g.cluster += offset
      g.size = runSize
      x0 = min(x0, g.x)
      ## Logical width follows the pen, not the glyphs' drawing offsets.
      result.width += g.advance
      result.glyphs.add g
  if result.glyphs.len == 0:
    x0 = 0
  result.width = max(result.width, 0)
  result.height = max(m.lineHeight, result.ascent + result.descent)
  result.y = y
  result.baseline = y + (result.height - result.ascent - result.descent) / 2 +
    result.ascent
  for i in 0 ..< result.glyphs.len:
    result.glyphs[i].x -= x0
    result.glyphs[i].y += result.baseline
  y += result.height
  buf = starts

const ellipsisMark = @[Rune(0x2026)]

## --- the System ---

proc newSystem*(): System =
  result = System(
    fonts: initTable[Style, Font](),
    layouts: initTable[Params, cached](),
    marks: initTable[markKey, float32](),
    glyphs: initTable[glyphKey, atlasEntry](),
    places: initTable[placeKey, placement](),
    runs: initTable[runKey, atlasEntry](),
    masks: initTable[uint64, atlasEntry](),
    transient: initTable[uint64, GlyphImage](),
    recent: initTable[uint64, uint64](),
    maskAtlas: scene.newAtlas(1, 256, 256),
    # Most interfaces have no color or subpixel glyphs. Keep just a
    # transparent texel until one asks for room.
    colorAtlas: scene.newAtlas(4, 1, 1))
  initLock(result.mu)

var
  sharedMu: Lock
  sharedInst: System

proc shared*(): System =
  ## The process-wide text system.
  sharedMu.acquire()
  if sharedInst.isNil:
    sharedInst = newSystem()
  result = sharedInst
  sharedMu.release()

proc engine(s: System): Engine =
  ## Starts the system's text engine on first use.
  if s.eng.isNil:
    s.eng = newEngine()
    if s.eng.hasUIFamily():
      s.eng.setUIFamily(s.uiFamily)
    if s.eng.hasFontRendering() and s.hasRendering:
      s.eng.setFontRendering(s.rendering[0], s.rendering[1], s.rendering[2])
  s.eng

proc unlinkLayout(s: System, c: cached) =
  if not c.prev.isNil:
    c.prev.next = c.next
  else:
    s.oldest = c.next
  if not c.next.isNil:
    c.next.prev = c.prev
  else:
    s.newest = c.prev
  c.prev = nil
  c.next = nil

proc useLayout(s: System, c: cached) =
  c.used = s.frame
  if s.newest == c:
    return
  if not c.prev.isNil or not c.next.isNil or s.oldest == c:
    s.unlinkLayout(c)
  c.prev = s.newest
  if not s.newest.isNil:
    s.newest.next = c
  else:
    s.oldest = c
  s.newest = c

proc removeLayout(s: System, c: cached) =
  s.unlinkLayout(c)
  s.layouts.del(c.layout.params)
  s.layoutBytes -= c.bytes

proc clearLayouts(s: System) =
  while not s.oldest.isNil:
    s.unlinkLayout(s.oldest)
  s.layouts.clear()
  s.layoutBytes = 0

proc overLayoutBudget(s: System, n: int): bool =
  s.layoutBytes + n > maxLiveLayoutBytes or
    (s.layoutBytes + n > maxLayoutBytes and not s.oldest.isNil and
     s.frame - s.oldest.used >= liveLayoutFrames)

proc layoutBytes(c: cached): int =
  ## The memory estimate includes text, shaped glyphs and room for lazy
  ## caret geometry.
  let l = c.layout
  let p = l.params
  var n = sizeof(cached) + sizeof(Params) + p.text.len + p.spans.len +
    p.ellipsis.len + p.style.family.len + p.style.features.len + p.style.lang.len
  n += l.runes.len * 4
  if l.lines.len > 1:
    n += l.lines.len * sizeof(Line)
  n += (l.runes.len + 1) * sizeof(int)
  for line in l.lines:
    n += line.glyphs.len * sizeof(Glyph)
    n += (line.`end` - line.start + 1) * 2 *
      (sizeof(float32) + sizeof(caretStop))
  n

proc font(s: System, style: Style): Font =
  ## The font of a style.
  let key = Style(family: style.family, size: style.fontSize(),
                  weight: weight(style), italic: style.italic)
  if s.fonts.hasKey(key):
    return s.fonts[key]
  let f = s.engine().font(key)
  if s.fonts.len >= 1024:
    s.fonts.clear()
  s.fonts[key] = f
  f

proc setFontRendering*(s: System, antialias, hinting, subpixels: string) =
  ## How text is rasterized where the system's text stack does not know
  ## the desktop's settings, as Pango on Linux. Other engines ignore it.
  s.mu.acquire()
  defer: s.mu.release()
  let r = [antialias, hinting, subpixels]
  if s.hasRendering and s.rendering == r:
    return
  s.rendering = r
  s.hasRendering = true
  if not s.eng.isNil and s.eng.hasFontRendering():
    s.eng.setFontRendering(antialias, hinting, subpixels)
    inc s.gen
    s.fonts.clear()
    s.clearLayouts()
    s.marks.clear()
    s.glyphs.clear()
    s.places.clear()
    s.runs.clear()

proc setUIFamily*(s: System, family: string) =
  ## The family "system-ui" stands for where the system's text stack
  ## does not know the desktop's interface font. Other engines ignore it.
  s.mu.acquire()
  defer: s.mu.release()
  if family == s.uiFamily:
    return
  s.uiFamily = family
  if not s.eng.isNil and s.eng.hasUIFamily():
    s.eng.setUIFamily(family)
    inc s.gen
    s.fonts.clear()
    s.clearLayouts()
    s.marks.clear()

proc setLanguage*(s: System, tag: string) =
  ## The language of the texts whose Style names none, a BCP 47 tag, or
  ## "" for none. The layouts made before are made anew (generation).
  s.mu.acquire()
  defer: s.mu.release()
  if tag == s.lang:
    return
  s.lang = tag
  inc s.gen
  s.clearLayouts()
  s.marks.clear()

proc language*(s: System): string =
  s.mu.acquire()
  defer: s.mu.release()
  s.lang

proc registerFont*(s: System, data: openArray[byte], family: string) =
  ## Adds a TrueType or OpenType font (or collection) under family, or
  ## the font's own family name when family is empty.
  s.mu.acquire()
  defer: s.mu.release()
  s.engine().register(data, family)
  inc s.gen
  s.fonts.clear()
  s.clearLayouts()
  s.marks.clear()

proc fontFamilies*(s: System, mono: bool): seq[string] =
  ## The families text can use, the app's first then the system's, each
  ## once and sorted; the monospaced ones only when mono.
  s.mu.acquire()
  defer: s.mu.release()
  var (app, sys) = s.engine().families(mono)
  var seen = initHashSet[string]()
  proc unique(names: seq[string]): seq[string] =
    for f in names:
      let key = toLowerAscii(f)
      if key notin seen:
        seen.incl key
        result.add f
    result.sort()
  result = unique(app)
  result.add unique(sys)

proc preload*(s: System) =
  ## Starts the text engine and finds the system UI font, which the
  ## first layout otherwise waits for.
  s.mu.acquire()
  defer: s.mu.release()
  discard s.font(Style())

proc endFrame*(s: System) =
  ## Forgets layouts no frame used for a while. The ui package calls it
  ## after each frame.
  s.mu.acquire()
  defer: s.mu.release()
  var drop: seq[uint64]
  for k, f in s.recent:
    ## Windows take turns: a mask drawn again within a few frames is
    ## probably drawn by every frame of its window.
    if s.frame - f >= 8:
      drop.add k
  for k in drop:
    s.recent.del k
  inc s.frame
  if not s.eng.isNil and s.eng.fontCount() > maxFonts:
    inc s.gen
    s.clearLayouts()
    s.marks.clear()
    s.fonts.clear()
    s.glyphs.clear()
    s.places.clear()
    s.runs.clear()
    s.eng.forgetFonts()
    return
  while not s.oldest.isNil and s.overLayoutBudget(0):
    s.removeLayout(s.oldest)
  while not s.oldest.isNil and s.frame - s.oldest.used > 240:
    s.removeLayout(s.oldest)

proc layoutsMade*(s: System): uint64 =
  ## How many layouts the system has made, cached hits left out.
  s.mu.acquire()
  defer: s.mu.release()
  s.made

proc generation*(s: System): uint64 =
  ## A number that changes whenever the system forgets its layouts.
  s.mu.acquire()
  defer: s.mu.release()
  s.gen

proc metrics*(s: System, style: Style): tuple[ascent, descent, lineHeight: float32] =
  ## The ascent, descent and default line height of a style.
  s.mu.acquire()
  defer: s.mu.release()
  let m = metricsOf(s.font(style), style)
  (m.ascent, m.descent, m.lineHeight)

proc ellipsize(s: System, text: openArray[Rune], spans: openArray[Span],
               start: int, p: Params, rtl: bool): shapedLine =
  ## Lays out the paragraph text from rune start on one line ending with
  ## an ellipsis: as many of its graphemes as fit the width with it.
  let e = s.engine()
  let rest = text[start .. ^1]
  let restSpans = spansIn(spans, start, text.len)
  var mark = ellipsisMark
  if p.ellipsis != "":
    mark = toRunes(p.ellipsis)
  var cut = rest.len
  if p.width > 0:
    let key = markKey(style: p.style, mark: p.ellipsis, rtl: rtl)
    var ellipsis = 0'f32
    if s.marks.hasKey(key):
      ellipsis = s.marks[key]
    else:
      for l in e.shape(mark, p.style, @[], 0, rtl, false):
        ellipsis = max(ellipsis, advance(l))
      if s.marks.len >= 256:
        s.marks.clear()
      s.marks[key] = ellipsis
    ## The advance of each cluster, at its first rune.
    var advances = newSeq[float32](rest.len)
    for l in e.shape(rest, p.style, restSpans, 0, rtl, false):
      for run in l.runs:
        for g in run.glyphs:
          if g.cluster >= 0 and g.cluster < rest.len:
            advances[g.cluster] += g.advance
    var b: Boundaries
    b.reset(rest)
    var w = 0'f32
    cut = 0
    while cut < rest.len:
      let next = b.nextGrapheme(cut)
      var gw = 0'f32
      for a in advances[cut ..< next]:
        gw += a
      if w + gw + ellipsis > p.width:
        break
      w += gw
      cut = next
  while cut > 0 and isWhiteSpace(rest[cut - 1]):
    dec cut
  var t: seq[Rune]
  for r in rest[0 ..< cut]:
    t.add r
  for r in mark:
    t.add r
  result = shapedLine(start: start, `end`: start + cut)
  ## The ellipsis takes the style of the text it ends.
  var tSpans = spansIn(restSpans, 0, cut)
  if tSpans.len > 0 and tSpans[^1].`end` == cut:
    tSpans[^1].`end` += mark.len
  for l in e.shape(t, p.style, tSpans, 0, rtl, false):
    for run0 in l.runs:
      var run = run0
      run.start = start + min(run.start, cut)
      run.`end` = start + min(run.`end`, cut)
      for i in 0 ..< run.glyphs.len:
        if run.glyphs[i].cluster >= cut:
          run.glyphs[i].cluster = -1
        else:
          run.glyphs[i].cluster += start
      result.runs.add run

proc paragraph(s: System, `out`: var seq[Line], p: Params,
               spans: openArray[Span], runes: openArray[Rune],
               start, `end`, maxLines: int, continues: bool,
               m: lineMetrics, y: var float32): bool =
  ## Lays out runes[start:end], a paragraph without newlines, in at most
  ## maxLines lines (0 is unlimited) from y down, appends them to out,
  ## and moves y past it. Reports whether it cut the text, which
  ## continues after the paragraph when continues is set.
  var text = runes[start ..< `end`]
  ## A carriage return before the newline is part of it.
  if text.len > 0 and text[^1] == Rune(0x0D):
    text.setLen(text.len - 1)
  let rtl = isRTL(text, p.rtl)
  let pspans = spansIn(spans, start, start + text.len)
  var shaped: seq[shapedLine]
  if text.len > 0:
    var width = max(p.width, 0)
    if p.noWrap:
      width = 0
    shaped = s.engine().shape(text, p.style, pspans, width, rtl,
                              p.noBreakWords)
  if shaped.len == 0:
    shaped = @[shapedLine(`end`: text.len)]
  if maxLines > 0 and
     (shaped.len > maxLines or (shaped.len == maxLines and continues)):
    let last = s.ellipsize(text, pspans, shaped[maxLines - 1].start, p, rtl)
    shaped = shaped[0 ..< maxLines - 1]
    shaped.add last
    result = true
  let first = `out`.len
  var starts: seq[int]
  for sl in shaped:
    `out`.add line(p, text, sl, start, rtl, m, y, starts, pspans)
  ## Runes between lines, if an engine left any out, belong to the line
  ## before.
  for i in 0 ..< `out`.len - first - 1:
    `out`[first + i].`end` = max(`out`[first + i].`end`,
                                 `out`[first + i + 1].start)
  if not result and `out`.len > first:
    `out`[^1].`end` = `end`

proc lay(s: System, p: Params): cached =
  inc s.made
  s.engine().resetEngineScratch()
  let m = metricsOf(s.font(p.style), p.style)
  let runes = toRunes(p.text)
  let spans = decodeSpans(p.spans)
  let c = cached(layout: Layout(params: p, runes: runes))
  let l = c.layout
  ## The layout keeps its parameters as they came; the engine shapes in
  ## the system's language where they name none.
  var q = p
  if q.style.lang == "":
    q.style.lang = s.lang
  l.lines = newSeqOfCap[Line](1)
  var y = 0'f32
  var start = 0
  while start <= runes.len:
    var `end` = start
    while `end` < runes.len and runes[`end`] != Rune(0x0A):
      inc `end`
    var maxLines = 0
    if p.maxLines > 0:
      maxLines = p.maxLines - l.lines.len
    if s.paragraph(l.lines, q, spans, runes, start, `end`, maxLines,
                   `end` < runes.len, m, y):
      l.truncated = true
      break
    start = `end` + 1
  for line in l.lines:
    l.width = max(l.width, line.width)
  l.height = y
  ## Align each line within the wrap width, or the longest line.
  var box = l.width
  if p.width > 0:
    box = p.width
  for i in 0 ..< l.lines.len:
    var dx = 0'f32
    var align = p.align
    if l.lines[i].rtl:
      if align == Start: align = End
      elif align == End: align = Start
    case align
    of Center:
      dx = (box - l.lines[i].width) / 2
    of End, Right:
      dx = box - l.lines[i].width
    else:
      discard
    if dx != 0:
      l.lines[i].x += dx
      for j in 0 ..< l.lines[i].glyphs.len:
        l.lines[i].glyphs[j].x += dx
  c

proc layout*(s: System, p: Params): Layout =
  ## Shapes and wraps p.text. The result is shared and must not be
  ## modified.
  s.mu.acquire()
  defer: s.mu.release()
  if s.layouts.hasKey(p):
    let c = s.layouts[p]
    s.useLayout(c)
    return c.layout
  let c = s.lay(p)
  c.bytes = layoutBytes(c)
  ## A large paragraph still lays out correctly; keeping it would evict
  ## all the ordinary labels and lines of other windows.
  if c.bytes <= maxLayoutBytes:
    while not s.oldest.isNil and
        (s.overLayoutBudget(c.bytes) or s.layouts.len >= maxLayouts):
      s.removeLayout(s.oldest)
    s.layouts[p] = c
    s.layoutBytes += c.bytes
    s.useLayout(c)
  c.layout

proc shape*(s: System, p: Params): Layout =
  ## Lays out p.text as layout does, but caches nothing. The result
  ## belongs to the caller.
  s.mu.acquire()
  defer: s.mu.release()
  s.lay(p).layout
