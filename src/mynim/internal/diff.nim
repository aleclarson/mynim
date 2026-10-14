import std/[tables, unicode]
## Port of internal/diff: sequence comparison — the histogram algorithm
## of git (xhistogram.c) falling back to Myers's O(ND) past its cost
## limit, then the compaction that slides changed groups to read as
## blocks (xdl_change_compact + indent heuristic).

const maxChain = 64
const maxDepth = 256
const maxCostMin = 256
const lineMax = int.high div 4

type
  Hunk* = object
    ## A change: elements a0 to a1 of the old sequence replaced by b0
    ## to b1 of the new one. a0 == a1 is an insertion before a0,
    ## b0 == b1 a deletion.
    a0*, a1*, b0*, b1*: int

  Range* = object
    ## A range of bytes, first to last.
    first*, last*: int

  differ = object
    a, b: seq[int32]
    da, db: seq[bool]
    next, cnt: seq[int]
    recs: Table[int32, record]
    recsCap: int
    myersV: seq[int]
    myersExtra: int

  record = object
    first, count: int

  group = object
    start, stop: int

  split = object
    endOfFile: bool
    indent: int
    preBlank, preIndent: int
    postBlank, postIndent: int

  score = object
    effectiveIndent, penalty: int

proc mark(d: var differ; a0, a1, b0, b1: int) =
  if a0 == a1 and b0 == b1: return
  if d.da.len == 0:
    d.da = newSeq[bool](d.a.len)
    d.db = newSeq[bool](d.b.len)
  for i in a0 ..< a1: d.da[i] = true
  for i in b0 ..< b1: d.db[i] = true

proc hunks(d: var differ): seq[Hunk] =
  if d.da.len == 0: return
  var i, j = 0
  while i < d.a.len or j < d.b.len:
    if i < d.a.len and j < d.b.len and not d.da[i] and not d.db[j]:
      inc i; inc j
      continue
    var h = Hunk(a0: i, b0: j)
    while i < d.a.len and d.da[i]: inc i
    while j < d.b.len and d.db[j]: inc j
    h.a1 = i; h.b1 = j
    if h.a0 == h.a1 and h.b0 == h.b1:
      if i < d.a.len: inc i
      if j < d.b.len: inc j
      continue
    result.add h

proc recsCmp(d: var differ; off1, lim1, off2, lim2: int; needMin: bool)

proc splitRegion(d: var differ; off1, lim1, off2, lim2: int;
    needMin: bool): tuple[i1, i2: int, minLo, minHi: bool] =
  let ha1 = d.a
  let ha2 = d.b
  let nd = d.a.len + d.b.len + 3
  let base = d.b.len + 1
  let dmin = off1 - lim2
  let dmax = lim1 - off2
  let fmid = off1 - off2
  let bmid = lim1 - lim2
  let odd = ((fmid - bmid) and 1) != 0
  var fmin = fmid
  var fmax = fmid
  var bmin = bmid
  var bmax = bmid
  d.myersV[base + fmid] = off1
  d.myersV[base + nd + bmid] = lim1
  var ec = 1
  while true:
    if fmin > dmin:
      dec fmin
      d.myersV[base + fmin - 1] = -1
    else:
      inc fmin
    if fmax < dmax:
      inc fmax
      d.myersV[base + fmax + 1] = -1
    else:
      dec fmax
    var k = fmax
    while k >= fmin:
      var i1 = if d.myersV[base + k - 1] >= d.myersV[base + k + 1]:
        d.myersV[base + k - 1] + 1
      else:
        d.myersV[base + k + 1]
      var i2 = i1 - k
      while i1 < lim1 and i2 < lim2 and ha1[i1] == ha2[i2]:
        inc i1; inc i2
      d.myersV[base + k] = i1
      if odd and bmin <= k and k <= bmax and d.myersV[base + nd + k] <= i1:
        return (i1, i2, true, true)
      k -= 2
    if bmin > dmin:
      dec bmin
      d.myersV[base + nd + bmin - 1] = lineMax
    else:
      inc bmin
    if bmax < dmax:
      inc bmax
      d.myersV[base + nd + bmax + 1] = lineMax
    else:
      dec bmax
    k = bmax
    while k >= bmin:
      var i1 = if d.myersV[base + nd + k - 1] < d.myersV[base + nd + k + 1]:
        d.myersV[base + nd + k - 1]
      else:
        d.myersV[base + nd + k + 1] - 1
      var i2 = i1 - k
      while i1 > off1 and i2 > off2 and ha1[i1 - 1] == ha2[i2 - 1]:
        dec i1; dec i2
      d.myersV[base + nd + k] = i1
      if not odd and fmin <= k and k <= fmax and
          i1 <= d.myersV[base + k]:
        return (i1, i2, true, true)
      k -= 2
    if needMin or ec < d.myersExtra:
      inc ec
      continue
    var fbest = -1
    var fbest1 = -1
    k = fmax
    while k >= fmin:
      var i1 = min(d.myersV[base + k], lim1)
      var i2 = i1 - k
      if lim2 < i2:
        i1 = lim2 + k
        i2 = lim2
      if fbest < i1 + i2:
        fbest = i1 + i2
        fbest1 = i1
      k -= 2
    var bbest = lineMax
    var bbest1 = lineMax
    k = bmax
    while k >= bmin:
      var i1 = max(off1, d.myersV[base + nd + k])
      var i2 = i1 - k
      if i2 < off2:
        i1 = off2 + k
        i2 = off2
      if i1 + i2 < bbest:
        bbest = i1 + i2
        bbest1 = i1
      k -= 2
    if (lim1 + lim2) - bbest < fbest - (off1 + off2):
      return (fbest1, fbest - fbest1, true, false)
    return (bbest1, bbest - bbest1, false, true)

proc recsCmp(d: var differ; off1, lim1, off2, lim2: int; needMin: bool) =
  var off1 = off1
  var lim1 = lim1
  var off2 = off2
  var lim2 = lim2
  while off1 < lim1 and off2 < lim2 and d.a[off1] == d.b[off2]:
    inc off1; inc off2
  while off1 < lim1 and off2 < lim2 and d.a[lim1 - 1] == d.b[lim2 - 1]:
    dec lim1; dec lim2
  if off1 == lim1 or off2 == lim2:
    d.mark(off1, lim1, off2, lim2)
    return
  let (i1, i2, minLo, minHi) = d.splitRegion(off1, lim1, off2, lim2, needMin)
  d.recsCmp(off1, i1, off2, i2, minLo)
  d.recsCmp(i1, lim1, i2, lim2, minHi)

proc myers(d: var differ; a0, a1, b0, b1: int) =
  let n = d.a.len + d.b.len + 3
  if d.myersV.len < 2 * n:
    d.myersV = newSeq[int](2 * n)
  var cost = 1
  while cost * cost < n:
    cost = cost shl 1
  d.myersExtra = max(cost, maxCostMin)
  d.recsCmp(a0, a1, b0, b1, false)

proc lcs(d: var differ; a0, a1, b0, b1: int):
    tuple[la0, la1, lb0, lb1: int, ok: bool] =
  let n = a1 - a0
  if d.next.len < n:
    d.next = newSeq[int](n)
    d.cnt = newSeq[int](n)

  if d.recs.len == 0 or d.recsCap > 8 * n + 64:
    d.recs = initTable[int32, record](n)
    d.recsCap = n
  else:
    d.recs.clear()
  for i in countdown(a1 - 1, a0):
    var r = d.recs.getOrDefault(d.a[i])
    if r.count != 0 or d.recs.hasKey(d.a[i]):
      d.next[i - a0] = r.first
      inc r.count
    else:
      d.next[i - a0] = -1
      r.count = 1
    r.first = i
    d.recs[d.a[i]] = r
  for i in a0 ..< a1:
    d.cnt[i - a0] = d.recs[d.a[i]].count
  var best = maxChain + 1
  var common = false
  var la0 = a0
  var la1 = a0
  var lb0 = 0
  var lb1 = 0
  var bi = b0
  while bi < b1:
    var bnext = bi + 1
    if not d.recs.hasKey(d.b[bi]):
      bi = bnext
      continue
    let r = d.recs[d.b[bi]]
    common = true
    if r.count > best:
      bi = bnext
      continue
    var `as` = r.first
    while `as` >= 0:
      var s = `as`
      var bs = bi
      var e = `as` + 1
      var be = bi + 1
      var rc = d.cnt[`as` - a0]
      while s > a0 and bs > b0 and d.a[s - 1] == d.b[bs - 1]:
        dec s; dec bs
        if rc > 1: rc = min(rc, d.cnt[s - a0])
      while e < a1 and be < b1 and d.a[e] == d.b[be]:
        if rc > 1: rc = min(rc, d.cnt[e - a0])
        inc e; inc be
      if bnext < be: bnext = be
      if la1 - la0 < e - s or rc < best:
        la0 = s; la1 = e; lb0 = bs; lb1 = be; best = rc
      var np = d.next[`as` - a0]
      while np >= 0 and np < e:
        np = d.next[np - a0]
      `as` = np
    bi = bnext
  if common and best > maxChain:
    return (0, 0, 0, 0, false)
  (la0, la1, lb0, lb1, true)

proc histogram(d: var differ; a0, a1, b0, b1: int; depth: int) =
  var a0 = a0
  var a1 = a1
  var b0 = b0
  var b1 = b1
  var depth = depth
  while true:
    while a0 < a1 and b0 < b1 and d.a[a0] == d.b[b0]:
      inc a0; inc b0
    while a0 < a1 and b0 < b1 and d.a[a1 - 1] == d.b[b1 - 1]:
      dec a1; dec b1
    if a0 == a1 or b0 == b1:
      d.mark(a0, a1, b0, b1)
      return
    if depth > maxDepth:
      d.myers(a0, a1, b0, b1)
      return
    let (la0, la1, lb0, lb1, ok) = d.lcs(a0, a1, b0, b1)
    if not ok:
      d.myers(a0, a1, b0, b1)
      return
    if la0 == la1:
      d.mark(a0, a1, b0, b1)
      return
    inc depth
    if la0 - a0 + lb0 - b0 < a1 - la1 + b1 - lb1:
      d.histogram(a0, la0, b0, lb0, depth)
      a0 = la1; b0 = lb1
    else:
      d.histogram(la1, a1, lb1, b1, depth)
      a1 = la0; b1 = lb0

## --- compact.go ---

const
  maxIndent = 200
  maxBlanks = 20
  startOfFilePenalty = 1
  endOfFilePenalty = 21
  totalBlankWeight = -30
  postBlankWeight = 6
  relativeIndentPenalty = -4
  relativeIndentWithBlankPenalty = 10
  relativeOutdentPenalty = 24
  relativeOutdentWithBlank = 17
  relativeDedentPenalty = 23
  relativeDedentWithBlank = 17
  indentWeight = 60
  maxSliding = 100

proc indent(s: string): int =
  ## How far a line is indented, tabs to multiples of 8, or -1 for a
  ## blank line.
  for i in 0 ..< s.len:
    case s[i]
    of ' ': inc result
    of '\t': result += 8 - result mod 8
    of '\r', '\n', '\f', '\v': discard
    else: return
    if result >= maxIndent:
      return maxIndent
  -1

proc measure(lines: seq[string]; at: int): split =
  if at >= lines.len:
    result.endOfFile = true
    result.indent = -1
  else:
    result.indent = indent(lines[at])
  result.preIndent = -1
  var i = at - 1
  while i >= 0:
    result.preIndent = indent(lines[i])
    if result.preIndent != -1: break
    inc result.preBlank
    if result.preBlank == maxBlanks:
      result.preIndent = 0
      break
    dec i
  result.postIndent = -1
  i = at + 1
  while i < lines.len:
    result.postIndent = indent(lines[i])
    if result.postIndent != -1: break
    inc result.postBlank
    if result.postBlank == maxBlanks:
      result.postIndent = 0
      break
    inc i

proc pick(c: bool; a, b: int): int =
  if c: a else: b

proc add(s: var score; m: split) =
  if m.preIndent == -1 and m.preBlank == 0:
    s.penalty += startOfFilePenalty
  if m.endOfFile:
    s.penalty += endOfFilePenalty
  var postBlank = 0
  if m.indent == -1:
    postBlank = 1 + m.postBlank
  let totalBlank = m.preBlank + postBlank
  s.penalty += totalBlankWeight * totalBlank + postBlankWeight * postBlank
  var `in` = m.indent
  if `in` == -1:
    `in` = m.postIndent
  let blanks = totalBlank != 0
  s.effectiveIndent += `in`
  if `in` == -1 or m.preIndent == -1 or `in` == m.preIndent:
    discard
  elif `in` > m.preIndent:
    s.penalty += pick(blanks, relativeIndentWithBlankPenalty,
      relativeIndentPenalty)
  elif m.postIndent != -1 and m.postIndent > `in`:
    s.penalty += pick(blanks, relativeOutdentWithBlank,
      relativeOutdentPenalty)
  else:
    s.penalty += pick(blanks, relativeDedentWithBlank,
      relativeDedentPenalty)

proc cmp(s, o: score): int =
  var c = 0
  if s.effectiveIndent > o.effectiveIndent: c = 1
  elif s.effectiveIndent < o.effectiveIndent: c = -1
  indentWeight * c + s.penalty - o.penalty

proc groupInit(r: seq[bool]): group =
  while result.stop < r.len and r[result.stop]:
    inc result.stop

proc nextGroup(g: var group; r: seq[bool]): bool =
  if g.stop >= r.len: return false
  g.start = g.stop + 1
  g.stop = g.start
  while g.stop < r.len and r[g.stop]: inc g.stop
  true

proc prevGroup(g: var group; r: seq[bool]): bool =
  if g.start <= 0: return false
  g.stop = g.start - 1
  g.start = g.stop
  while g.start > 0 and r[g.start - 1]: dec g.start
  true

proc slideDown(g: var group; r: var seq[bool]; ids: seq[int32]): bool =
  if g.start < g.stop and g.stop < r.len and ids[g.start] == ids[g.stop]:
    r[g.start] = false
    inc g.start
    r[g.stop] = true
    inc g.stop
    while g.stop < r.len and r[g.stop]: inc g.stop
    return true
  false

proc slideUp(g: var group; r: var seq[bool]; ids: seq[int32]): bool =
  if g.start < g.stop and g.start > 0 and ids[g.start - 1] == ids[g.stop - 1]:
    dec g.start
    r[g.start] = true
    dec g.stop
    r[g.stop] = false
    while g.start > 0 and r[g.start - 1]: dec g.start
    return true
  false

proc compact(r: var seq[bool]; ro: seq[bool]; ids: seq[int32];
    lines: seq[string]) =
  ## Slides the groups of changed lines of one side up and down where
  ## the same lines frame them (git's xdl_change_compact).
  var g = groupInit(r)
  var gOther = groupInit(ro)
  while true:
    if g.stop != g.start:
      var size = 0
      var earliestEnd = 0
      var endMatchingOther = -1
      while true:
        size = g.stop - g.start
        endMatchingOther = -1
        while g.slideUp(r, ids):
          discard gOther.prevGroup(ro)
        earliestEnd = g.stop
        if gOther.stop > gOther.start:
          endMatchingOther = g.stop
        while g.slideDown(r, ids):
          discard gOther.nextGroup(ro)
          if gOther.stop > gOther.start:
            endMatchingOther = g.stop
        if size == g.stop - g.start:
          break
      if g.stop == earliestEnd:
        discard
      elif endMatchingOther != -1:
        while gOther.stop == gOther.start:
          if not g.slideUp(r, ids) or not gOther.prevGroup(ro):
            break
      else:
        let shift0 = max(max(earliestEnd, g.stop - size - 1), g.stop - maxSliding)
        var best = -1
        var bestScore: score
        var shift = shift0
        while shift <= g.stop:
          var s: score
          s.add(measure(lines, shift))
          s.add(measure(lines, shift - size))
          if best == -1 or s.cmp(bestScore) <= 0:
            bestScore = s
            best = shift
          inc shift
        while g.stop > best:
          if not g.slideUp(r, ids) or not gOther.prevGroup(ro):
            break
    if not g.nextGroup(r) or not gOther.nextGroup(ro):
      return

## --- words.go ---

proc isDigitRune(r: Rune): bool =
  ## unicode.IsDigit: decimal digits (category Nd). The common blocks.
  let c = r.int32
  (c >= ord('0') and c <= ord('9')) or
    (c >= 0x660 and c <= 0x669) or (c >= 0x6f0 and c <= 0x6f9) or
    (c >= 0x7c0 and c <= 0x7c9) or (c >= 0x966 and c <= 0x96f) or
    (c >= 0x9e6 and c <= 0x9ef) or (c >= 0xa66 and c <= 0xa6f) or
    (c >= 0xae6 and c <= 0xaef) or (c >= 0xb66 and c <= 0xb6f) or
    (c >= 0xbe6 and c <= 0xbef) or (c >= 0xc66 and c <= 0xc6f) or
    (c >= 0xce6 and c <= 0xcef) or (c >= 0xd66 and c <= 0xd6f) or
    (c >= 0xe50 and c <= 0xe59) or (c >= 0xed0 and c <= 0xed9) or
    (c >= 0xf20 and c <= 0xf29) or (c >= 0x1040 and c <= 0x1049) or
    (c >= 0x17e0 and c <= 0x17e9) or (c >= 0x1810 and c <= 0x1819) or
    (c >= 0x1946 and c <= 0x194f) or (c >= 0x19d0 and c <= 0x19d9) or
    (c >= 0x1a80 and c <= 0x1a89) or (c >= 0x1a90 and c <= 0x1a99) or
    (c >= 0x1b50 and c <= 0x1b59) or (c >= 0x1bb0 and c <= 0x1bb9) or
    (c >= 0x1c40 and c <= 0x1c49) or (c >= 0x1c50 and c <= 0x1c59) or
    (c >= 0xa620 and c <= 0xa629) or (c >= 0xa8d0 and c <= 0xa8d9) or
    (c >= 0xa900 and c <= 0xa909) or (c >= 0xa9d0 and c <= 0xa9d9) or
    (c >= 0xa9f0 and c <= 0xa9f9) or (c >= 0xaa50 and c <= 0xaa59) or
    (c >= 0xabf0 and c <= 0xabf9) or (c >= 0xff10 and c <= 0xff19) or
    (c >= 0x104a0 and c <= 0x104a9) or (c >= 0x10d30 and c <= 0x10d39) or
    (c >= 0x11066 and c <= 0x1106f) or (c >= 0x110f0 and c <= 0x110f9) or
    (c >= 0x11136 and c <= 0x1113f) or (c >= 0x111d0 and c <= 0x111d9) or
    (c >= 0x112f0 and c <= 0x112f9) or (c >= 0x11450 and c <= 0x11459) or
    (c >= 0x114d0 and c <= 0x114d9) or (c >= 0x11650 and c <= 0x11659) or
    (c >= 0x116c0 and c <= 0x116c9) or (c >= 0x11730 and c <= 0x11739) or
    (c >= 0x118e0 and c <= 0x118e9) or (c >= 0x11950 and c <= 0x11959) or
    (c >= 0x11c50 and c <= 0x11c59) or (c >= 0x11d50 and c <= 0x11d59) or
    (c >= 0x11da0 and c <= 0x11da9) or (c >= 0x11f50 and c <= 0x11f59) or
    (c >= 0x16a60 and c <= 0x16a69) or (c >= 0x16ac0 and c <= 0x16ac9) or
    (c >= 0x16b50 and c <= 0x16b59) or (c >= 0x1d7ce and c <= 0x1d7ff) or
    (c >= 0x1e140 and c <= 0x1e149) or (c >= 0x1e2f0 and c <= 0x1e2f9) or
    (c >= 0x1e4f0 and c <= 0x1e4f9) or (c >= 0x1e950 and c <= 0x1e959)

proc isWord(r: Rune): bool =
  r.int32 == ord('_') or r.isAlpha or r.isDigitRune

proc wordTokens(s: string; o: var seq[Range]) =
  var i = 0
  while i < s.len:
    var r = s.runeAt(i)
    var j = i + s.runeLenAt(i)
    if isWord(r):
      while j < s.len:
        r = s.runeAt(j)
        if not isWord(r): break
        j += s.runeLenAt(j)
    elif r.int32 != ord('\n') and r.isWhiteSpace:
      while j < s.len:
        r = s.runeAt(j)
        if r.int32 == ord('\n') or not r.isWhiteSpace: break
        j += s.runeLenAt(j)
    o.add Range(first: i, last: j)
    i = j

proc charTokens(s: string; o: var seq[Range]) =
  var i = 0
  while i < s.len:
    ## Combining marks stay with their base.
    var j = i + s.runeLenAt(i)
    while j < s.len:
      let r = s.runeAt(j)
      let c = r.int32
      if not (c == 0x200d or (c >= 0xfe00 and c <= 0xfe0f) or
          r.isCombining):
        break
      j += s.runeLenAt(j)
    o.add Range(first: i, last: j)
    i = j

proc joinRanges(rs: var seq[Range]; r: Range; s: string) =
  ## Appends r to rs, merged with the last range when only whitespace
  ## is between them.
  if rs.len > 0:
    let gap = s[rs[^1].last ..< r.first]
    var blank = true
    for c in gap.runes:
      if c.int32 == ord('\n') or not c.isWhiteSpace:
        blank = false
        break
    if blank:
      rs[^1].last = r.last
      return
  rs.add r

proc tokens(a, b: string;
    splitTok: proc(s: string; o: var seq[Range])):
    tuple[ra, rb: seq[Range], same: float64] =
  var ta, tb: seq[Range]
  splitTok(a, ta)
  splitTok(b, tb)
  var ids = initTable[string, int32](ta.len + tb.len)
  var ia = newSeq[int32](ta.len)
  var ib = newSeq[int32](tb.len)
  for i, r in ta:
    let v = a[r.first ..< r.last]
    if not ids.hasKey(v): ids[v] = ids.len.int32
    ia[i] = ids[v]
  for i, r in tb:
    let v = b[r.first ..< r.last]
    if not ids.hasKey(v): ids[v] = ids.len.int32
    ib[i] = ids[v]
  var d = differ(a: ia, b: ib)
  d.histogram(0, ia.len, 0, ib.len, 0)
  let hs = d.hunks()
  var changed = 0
  for h in hs:
    if h.a0 < h.a1:
      joinRanges(result.ra, Range(first: ta[h.a0].first,
        last: ta[h.a1 - 1].last), a)
      changed += ta[h.a1 - 1].last - ta[h.a0].first
    if h.b0 < h.b1:
      joinRanges(result.rb, Range(first: tb[h.b0].first,
        last: tb[h.b1 - 1].last), b)
      changed += tb[h.b1 - 1].last - tb[h.b0].first
  let total = a.len + b.len
  result.same = if total > 0: 1 - changed / total else: 1

proc ints*(a, b: seq[int32]): seq[Hunk] =
  ## Compares two sequences of interned elements, equal elements
  ## having equal values, and returns the hunks turning a into b.
  var d = differ(a: a, b: b)
  d.histogram(0, a.len, 0, b.len, 0)
  d.hunks()

proc intern*(a, b: seq[string]): tuple[ia, ib: seq[int32]] =
  ## Numbers the distinct strings of a and b, equal strings sharing a
  ## number.
  var ids = initTable[string, int32](a.len + b.len)
  for v in a:
    if not ids.hasKey(v): ids[v] = ids.len.int32
    result.ia.add ids[v]
  for v in b:
    if not ids.hasKey(v): ids[v] = ids.len.int32
    result.ib.add ids[v]

proc lines*(a, b: seq[string]): seq[Hunk] =
  ## Compares the lines of two texts and returns the hunks of lines
  ## turning a into b, slid to read as blocks of code.
  let (ia, ib) = intern(a, b)
  var d = differ(a: ia, b: ib)
  d.histogram(0, ia.len, 0, ib.len, 0)
  if d.da.len == 0: return
  compact(d.da, d.db, ia, a)
  compact(d.db, d.da, ib, b)
  d.hunks()

proc words*(a, b: string): tuple[ra, rb: seq[Range], same: float64] =
  ## Compares two texts word by word: words (letters, digits and
  ## underscores), runs of whitespace and other characters one at a
  ## time. Returns the byte ranges of a and b that changed, joined
  ## across the whitespace between them, and how much stayed the same.
  tokens(a, b, wordTokens)

proc chars*(a, b: string): tuple[ra, rb: seq[Range], same: float64] =
  ## Compares two texts character by character, as words does by
  ## words.
  tokens(a, b, charTokens)
