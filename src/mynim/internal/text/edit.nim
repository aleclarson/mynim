## edit.go (part): caret positions, hit tests and selection rectangles.

proc lineCarets(line: var Line): seq[float32] =
  ## The x of every caret position of a line, from start to end: inside
  ## a cluster of several runes (a ligature) the positions split the
  ## cluster evenly. It caches them in the line, so a layout's caret
  ## methods must be used from one thread at a time.
  if line.carets.len != 0:
    return line.carets
  type cluster = object
    x0, x1: float32
    start, runes: int
    rtl: bool
  var clusters: seq[cluster]
  var g = 0
  while g < line.glyphs.len:
    let first = line.glyphs[g]
    var c = cluster(x0: first.x, x1: first.x + first.advance,
                    start: first.cluster, runes: first.runes,
                    rtl: first.rtl)
    inc g
    while g < line.glyphs.len and line.glyphs[g].cluster == first.cluster and
        line.glyphs[g].runes == first.runes:
      c.x0 = min(c.x0, line.glyphs[g].x)
      c.x1 = max(c.x1, line.glyphs[g].x + line.glyphs[g].advance)
      inc g
    if c.runes > 0:
      clusters.add c
  let pos = proc(c: cluster, k: int): float32 =
    let f = float32(k) / float32(c.runes)
    if c.rtl:
      c.x1 - (c.x1 - c.x0) * f
    else:
      c.x0 + (c.x1 - c.x0) * f
  let n = line.`end` - line.start + 1
  var carets = newSeq[float32](n)
  var `set` = newSeq[bool](n)
  ## A cluster's start takes precedence over the end of the cluster
  ## before it, which differ in bidirectional text.
  for c in clusters:
    for k in 0 ..< c.runes:
      let i = c.start + k - line.start
      if i >= 0 and i < n:
        carets[i] = pos(c, k)
        `set`[i] = true
  for c in clusters:
    let i = c.start + c.runes - line.start
    if i >= 0 and i < n and not `set`[i]:
      carets[i] = pos(c, c.runes)
      `set`[i] = true
  var `end` = line.x + line.width
  if line.rtl:
    `end` = line.x
  for i in countdown(n - 1, 0):
    if not `set`[i]:
      carets[i] = `end`
      if i + 1 < n and `set`[i + 1]:
        ## A trimmed space before the next cluster.
        carets[i] = carets[i + 1]
      `set`[i] = true
  line.carets = carets
  carets

proc lineAt*(l: Layout, index: int): int =
  ## The index of the line holding rune index, the start of the next
  ## line at a soft line break.
  for i in 0 ..< l.lines.len:
    if index < l.lines[i].`end` or
        (index == l.lines[i].`end` and
         (i == l.lines.len - 1 or l.lines[i + 1].start > index)):
      return i
  l.lines.len - 1

proc caret*(l: Layout, index: int): tuple[x, y, h: float32] =
  ## The position of the caret before rune index: its x, the top of its
  ## line and the line's height.
  if l.lines.len == 0:
    return (0'f32, 0'f32, 0'f32)
  let index = max(0, min(index, l.runes.len))
  let li = l.lineAt(index)
  let carets = l.lines[li].lineCarets()
  let i = max(0, min(index - l.lines[li].start, carets.len - 1))
  (carets[i], l.lines[li].y, l.lines[li].height)

proc indexAt*(l: Layout, x, y: float32): int =
  ## The rune index of the caret position closest to (x, y).
  if l.lines.len == 0:
    return 0
  var li = l.lines.len - 1
  for i in 0 ..< l.lines.len:
    if y < l.lines[i].y + l.lines[i].height:
      li = i
      break
  let carets = l.lines[li].lineCarets()
  var best = 0
  var bestDist = -1'f32
  for i, cx in carets:
    let d = abs(cx - x)
    if bestDist < 0 or d < bestDist:
      best = i
      bestDist = d
  l.lines[li].start + best

proc appendSelection*(l: Layout, dst: seq[Rect], start, `end`: int,
                      on: bool): seq[Rect] =
  ## Appends the rectangles of selectionVisual to dst, for callers that
  ## keep them frame after frame.
  var start = start
  var `end` = `end`
  if start > `end`:
    swap(start, `end`)
  if on:
    `end` = l.runes.len + 1
  result = dst
  for li in 0 ..< l.lines.len:
    ## A range can include the newline at end, so keep that boundary's
    ## line even when none of its glyphs are selected.
    if l.lines[li].`end` < start or l.lines[li].start >= `end`:
      continue
    var pieces: seq[Rect]
    var i = 0
    while i < l.lines[li].glyphs.len:
      let first = l.lines[li].glyphs[i]
      var x0 = first.x
      var x1 = first.x + first.advance
      inc i
      while i < l.lines[li].glyphs.len and
          l.lines[li].glyphs[i].cluster == first.cluster and
          l.lines[li].glyphs[i].runes == first.runes:
        x0 = min(x0, l.lines[li].glyphs[i].x)
        x1 = max(x1, l.lines[li].glyphs[i].x + l.lines[li].glyphs[i].advance)
        inc i
      let a = max(start, first.cluster)
      let z = min(`end`, first.cluster + first.runes)
      if a >= z or first.runes <= 0:
        continue
      let width = x1 - x0
      var left = float32(a - first.cluster) / float32(first.runes)
      var right = float32(z - first.cluster) / float32(first.runes)
      if first.rtl:
        swap(left, right)
        left = 1 - left
        right = 1 - right
      let r = Rect(x: x0 + left * width, y: l.lines[li].y,
                   w: (right - left) * width, h: l.lines[li].height)
      ## Clusters following each other join as they come, as most do.
      if pieces.len > 0 and
          pieces[^1].x + pieces[^1].w >= r.x - 0.01 and
          pieces[^1].x <= r.x + 0.01:
        pieces[^1].w = max(pieces[^1].x + pieces[^1].w, r.x + r.w) - pieces[^1].x
        continue
      pieces.add r
    if start <= l.lines[li].`end` and `end` > l.lines[li].`end` and
        ((li < l.lines.len - 1 and l.lines[li + 1].start > l.lines[li].`end`) or
         (li == l.lines.len - 1 and on)):
      var x = l.lines[li].x + l.lines[li].width
      let width = l.params.style.fontSize() / 3
      if l.lines[li].rtl:
        x = l.lines[li].x - width
      pieces.add Rect(x: x, y: l.lines[li].y, w: width, h: l.lines[li].height)
    ## By x, insertion sorted: pieces are mostly in order already.
    for i in 1 ..< pieces.len:
      var j = i
      while j > 0 and pieces[j - 1].x > pieces[j].x:
        swap(pieces[j - 1], pieces[j])
        dec j
    for r in pieces:
      if r.w <= 0:
        continue
      if result.len > dst.len and result[^1].y == r.y and
          result[^1].x + result[^1].w >= r.x - 0.01:
        result[^1].w = max(result[^1].x + result[^1].w, r.x + r.w) - result[^1].x
      else:
        result.add r

proc selectionVisual*(l: Layout, start, `end`: int, on: bool): seq[Rect] =
  ## Separate rectangles for selected visual runs. At bidi boundaries a
  ## logical range may cover disjoint areas on a line.
  l.appendSelection(@[], start, `end`, on)

proc selectionOn*(l: Layout, start, `end`: int, on: bool): seq[Rect] =
  ## selection for a layout of a paragraph of a longer text, whose
  ## selection goes on past the newline after the paragraph when on is
  ## set: the newline shows, as between the lines of a layout.
  l.selectionVisual(start, `end`, on)

proc selection*(l: Layout, start, `end`: int): seq[Rect] =
  ## The rectangles covering the runes from start to end.
  l.selectionOn(start, `end`, false)
