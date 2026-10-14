## caret.go: visual caret positions preserving affinity at bidi
## boundaries and soft line breaks.

proc visualStops(l: Layout, li: int): seq[caretStop] =
  if l.lines[li].stops.len != 0:
    return l.lines[li].stops
  if l.boundaries.len == 0:
    var b: Boundaries
    b.reset(l.runes)
    l.boundaries = b.graphemeOffsets()
  var stops: seq[caretStop]
  l.lines[li].upstream = l.lines[li].lineCarets()
  var i = 0
  while i < l.lines[li].glyphs.len:
    let g = l.lines[li].glyphs[i]
    var x0 = g.x
    var x1 = g.x + g.advance
    inc i
    while i < l.lines[li].glyphs.len and
        l.lines[li].glyphs[i].cluster == g.cluster and
        l.lines[li].glyphs[i].runes == g.runes:
      x0 = min(x0, l.lines[li].glyphs[i].x)
      x1 = max(x1, l.lines[li].glyphs[i].x + l.lines[li].glyphs[i].advance)
      inc i
    if g.runes <= 0:
      continue
    for k in 0 .. g.runes:
      let at = g.cluster + k
      if lowerBound(l.boundaries, at) >= l.boundaries.len or
          l.boundaries[lowerBound(l.boundaries, at)] != at:
        continue
      var x = x0 + (x1 - x0) * float32(k) / float32(g.runes)
      if g.rtl:
        x = x1 - (x1 - x0) * float32(k) / float32(g.runes)
      var affinity = Downstream
      var arrival = 0
      if k == 0:
        arrival = -1
      if k == g.runes:
        affinity = Upstream
        arrival = 1
      if g.rtl:
        arrival = -arrival
      if affinity == Upstream and at >= l.lines[li].start and
          at <= l.lines[li].`end`:
        l.lines[li].upstream[at - l.lines[li].start] = x
      stops.add caretStop(position: CaretPosition(index: at, affinity: affinity),
                          x: x, arrival: arrival)
  ## Keep trimmed spaces and empty lines navigable too.
  let carets = l.lines[li].lineCarets()
  let first = lowerBound(l.boundaries, l.lines[li].start)
  var k = first
  while k < l.boundaries.len and l.boundaries[k] <= l.lines[li].`end`:
    let at = l.boundaries[k]
    var found = false
    for st in stops:
      if st.position.index == at:
        found = true
        break
    if not found:
      stops.add caretStop(position: CaretPosition(index: at, affinity: Downstream),
                          x: carets[at - l.lines[li].start], arrival: 0)
    inc k
  if stops.len == 0:
    stops.add caretStop(position: CaretPosition(index: l.lines[li].start,
                                               affinity: Downstream),
                        x: l.lines[li].x, arrival: 0)
  stops.sort(proc(a, b: caretStop): int =
    if a.x < b.x: -1 elif a.x > b.x: 1 else: 0, order = SortOrder.Ascending)
  l.lines[li].stops = stops
  stops

proc caretLine(l: Layout, p: CaretPosition): int =
  result = l.lineAt(p.index)
  if p.affinity == Upstream and result > 0 and
      l.lines[result].start == p.index and l.lines[result - 1].`end` == p.index:
    dec result

proc caretAt*(l: Layout, p: CaretPosition): tuple[x, y, h: float32] =
  ## Preserves affinity at bidi boundaries and soft line breaks.
  if l.lines.len == 0:
    return (0'f32, 0'f32, 0'f32)
  var p = p
  p.index = max(0, min(p.index, l.runes.len))
  let li = l.caretLine(p)
  discard l.visualStops(li)
  let i = max(0, min(p.index - l.lines[li].start, l.lines[li].carets.len - 1))
  var x = l.lines[li].carets[i]
  if p.affinity == Upstream:
    x = l.lines[li].upstream[i]
  (x, l.lines[li].y, l.lines[li].height)

proc positionAt*(l: Layout, x, y: float32): CaretPosition =
  ## Hit-tests whole graphemes, retaining the visual edge chosen.
  if l.lines.len == 0:
    return CaretPosition()
  var li = l.lines.len - 1
  for i in 0 ..< l.lines.len:
    if y < l.lines[i].y + l.lines[i].height:
      li = i
      break
  let stops = l.visualStops(li)
  var best = stops[0]
  var distance = -1'f32
  for s in stops:
    let d = abs(s.x - x)
    ## Affinity breaks ties at one offset, not across offsets sharing
    ## an edge.
    if distance < 0 or d < distance or
        (d == distance and s.position.index == best.position.index and
         s.position.affinity == Downstream):
      best = s
      distance = d
  best.position

proc arriving(stops: seq[caretStop], x: float32, direction: int): CaretPosition =
  for s in stops:
    ## Native runs can disagree by a few float32 rounding bits at their
    ## shared edge.
    if abs(s.x - x) > 0.01:
      continue
    result = s.position
    if s.arrival == direction:
      return

proc moveCaret*(l: Layout, p: CaretPosition, direction: int): CaretPosition =
  ## Advances one visual grapheme, preserving the edge arrived at.
  if l.lines.len == 0 or direction == 0:
    return p
  var direction = direction
  if direction < 0: direction = -1 else: direction = 1
  let li = l.caretLine(p)
  let (x, _, _) = l.caretAt(p)
  let stops = l.visualStops(li)
  if direction > 0:
    for s in stops:
      if s.x > x + 0.001:
        return arriving(stops, s.x, direction)
  else:
    for i in countdown(stops.len - 1, 0):
      if stops[i].x < x - 0.001:
        return arriving(stops, stops[i].x, direction)
  var next = li + direction
  if l.lines[li].rtl:
    next = li - direction
  if next < 0 or next >= l.lines.len:
    return p
  let stops2 = l.visualStops(next)
  var x2 = stops2[0].x
  if direction < 0:
    x2 = stops2[^1].x
  arriving(stops2, x2, direction)

proc selectionRanges*(l: Layout, a, b: CaretPosition): seq[Range] =
  ## Logical ranges covered by a visual gesture. A gesture through
  ## mixed-direction text can cover discontiguous ranges.
  if l.lines.len == 0:
    return
  var ai = l.caretLine(a)
  var bi = l.caretLine(b)
  var (ax, _, _) = l.caretAt(a)
  var (bx, _, _) = l.caretAt(b)
  if ai > bi:
    swap(ai, bi)
    swap(ax, bx)
  var ranges: seq[Range]
  for li in ai .. bi:
    var lo = l.lines[li].x
    var hi = l.lines[li].x + l.lines[li].width
    if ai == bi:
      lo = min(ax, bx)
      hi = max(ax, bx)
    else:
      if li == ai:
        if l.lines[li].rtl: hi = ax else: lo = ax
      if li == bi:
        if l.lines[li].rtl: lo = bx else: hi = bx
    discard l.visualStops(li)
    let first = lowerBound(l.boundaries, l.lines[li].start)
    var k = first
    while k + 1 < l.boundaries.len and l.boundaries[k] < l.lines[li].`end`:
      let start = l.boundaries[k]
      let `end` = l.boundaries[k + 1]
      inc k
      if start < l.lines[li].start or `end` > l.lines[li].`end`:
        continue
      let (x0, _, _) = l.caretAt(CaretPosition(index: start, affinity: Downstream))
      let (x1, _, _) = l.caretAt(CaretPosition(index: `end`, affinity: Upstream))
      let left = min(x0, x1)
      let right = max(x0, x1)
      if right > left and left >= lo - 0.01 and right <= hi + 0.01:
        ranges.add Range(start: start, `end`: `end`)
    if li < bi and li + 1 < l.lines.len and
        l.lines[li + 1].start > l.lines[li].`end`:
      ranges.add Range(start: l.lines[li].`end`, `end`: l.lines[li + 1].start)
  ranges.sort(proc(a, b: Range): int = a.start - b.start)
  for r in ranges:
    if result.len > 0 and result[^1].`end` >= r.start:
      result[^1].`end` = max(result[^1].`end`, r.`end`)
    else:
      result.add r
