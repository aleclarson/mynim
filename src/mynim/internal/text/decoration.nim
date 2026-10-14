## decoration.go: underlines and strikethroughs, as the system's text
## stack draws them.

proc runs*(r: decoRange, fn: proc(f: Font, i, j: int)) =
  ## Calls fn for each run of glyphs of one font among [i, j).
  let gs = r.line.glyphs
  var i = r.i
  while i < r.j:
    var j = i + 1
    while j < r.j and gs[j].font == gs[i].font:
      inc j
    if not gs[i].font.isNil:
      fn(gs[i].font, i, j)
    i = j

proc span*(r: decoRange, i, j: int): tuple[x0, x1: float32] =
  ## The left and right of the advances of glyphs [i, j), in DIPs from
  ## the layout's origin.
  var x0 = float32.high
  var x1 = float32.low
  for k in i ..< j:
    let g = r.line.glyphs[k]
    x0 = min(x0, g.x)
    x1 = max(x1, g.x + g.advance)
  (x0, x1)

proc rune*(r: decoRange, k: int): Rune =
  ## The rune glyph k starts, or 0.
  let c = r.line.glyphs[k].cluster
  if c >= 0 and c < r.l.runes.len:
    return r.l.runes[c]
  Rune(0)

proc baseline*(r: decoRange): float32 =
  ## The baseline of the line, in DIPs from the top, as laid out.
  r.y + r.line.baseline

proc decorate*(s: System, l: Layout, li, i, j: int, x, y, scale: float32,
               d: Decoration, thick: float32): seq[Stroke] =
  ## The strokes the system's text stack draws for decoration d of
  ## glyphs [i, j) of line li of l, runes of one style, with the
  ## layout's origin at (x, y) DIPs, at scale pixels per DIP: placed as
  ## AppKit, Direct2D or GTK place underlines and strikethroughs, with
  ## their thickness, or, if thick is positive, thick DIPs around their
  ## middle, rounded to whole pixels (at least one) and on whole pixels,
  ## so that they are as sharp as browsers draw
  ## text-decoration-thickness.
  s.mu.acquire()
  defer: s.mu.release()
  if l.isNil or li < 0 or li >= l.lines.len:
    return
  let line = unsafeAddr l.lines[li]
  let i = max(i, 0)
  let j = min(j, line.glyphs.len)
  if i >= j:
    return
  var style = l.params.style
  if l.params.spans != "":
    let r = line.glyphs[i].cluster
    for sp in decodeSpans(l.params.spans):
      if r < sp.`end`:
        style = sp.style(style)
        break
  let f = s.font(style)
  if f.isNil:
    return
  result = s.engine().decorate(decoRange(l: l, line: line, i: i, j: j,
                                         font: f, x: x, y: y,
                                         scale: scale, d: d))
  if thick > 0:
    let h = max(float32(round(thick * scale)), 1)
    for k in 0 ..< result.len:
      result[k].top = float32(round((result[k].top + result[k].bottom - h) / 2))
      result[k].bottom = result[k].top + h

proc cut*(x0, x1: float32, cuts: seq[array[2, float32]],
          minLen: float32): seq[array[2, float32]] =
  ## [x0, x1] less the intervals of cuts, leaving out pieces no longer
  ## than minLen.
  var cuts = cuts
  cuts.sort(proc(a, b: array[2, float32]): int =
    if a[0] < b[0]: -1 elif a[0] > b[0]: 1 else: 0)
  var at = x0
  for c in cuts:
    if c[0] > at:
      let `end` = min(c[0], x1)
      if `end` - at > minLen:
        result.add [at, `end`]
    at = max(at, c[1])
    if at >= x1:
      break
  if x1 - at > minLen:
    result.add [at, x1]

proc skipsInk*(r: Rune): bool =
  ## Whether a rune's glyph cuts the underlines skipping ink: Han, Kana
  ## and Hangul do not, as in AppKit.
  if isWhiteSpace(r):
    return false
  let c = int32(r)
  if isHan(r):
    return false
  # Hiragana, Katakana (+ halfwidth, ext), Hangul (syllables, jamo,
  # compatibility jamo, extended A/B).
  if (c >= 0x3040 and c <= 0x309F) or (c >= 0x30A0 and c <= 0x30FF) or
     (c >= 0x31F0 and c <= 0x31FF) or (c >= 0xFF66 and c <= 0xFF9D) or
     (c >= 0xAC00 and c <= 0xD7AF) or (c >= 0x1100 and c <= 0x11FF) or
     (c >= 0x3130 and c <= 0x318F) or (c >= 0xA960 and c <= 0xA97F) or
     (c >= 0xD7B0 and c <= 0xD7FF):
    return false
  true

proc bandX*(segments: seq[array[4, float64]], lo, hi: float64):
    tuple[a, b: float64, ok: bool] =
  ## The left and right of the parts of segments (x0, y0, x1, y1 each)
  ## within lo <= y <= hi.
  var a = Inf
  var b = -Inf
  for s in segments:
    let (px, py, qx, qy) = (s[0], s[1], s[2], s[3])
    var t0 = 0.0
    var t1 = 1.0
    let dy = qy - py
    if dy == 0:
      if py < lo or py > hi:
        continue
    else:
      var ta = (lo - py) / dy
      var tb = (hi - py) / dy
      if ta > tb:
        swap(ta, tb)
      t0 = max(t0, ta)
      t1 = min(t1, tb)
      if t0 > t1:
        continue
    let xa = px + (qx - px) * t0
    let xb = px + (qx - px) * t1
    a = min(min(a, xa), xb)
    b = max(max(b, xa), xb)
  (a, b, a <= b)
