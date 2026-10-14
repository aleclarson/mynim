## uia_text.nim (uia_text.go): the text of a text field is UI
## Automation's Text pattern: the field is an ITextProvider, and
## ranges of its text are ITextRangeProviders, COM objects of their
## own, which Narrator moves by characters, formats, words and
## lines, reads, and asks the formats of: the font, its size and
## weight, italics, lines, colors and headings of a rich text's runs
## (AccessNode.textRuns). Ranges count runes of the node's value, as
## the tree does, and read the node as it is when they are used.

var
  iidITextRangeProvider* = guid(
    "5347ad7b-c355-46f8-aff5-909033582f63")

  textRangeVtbl*: seq[uint]
  eInvalidArg* = 0x80070057'u
  ## textRanges keeps the ranges COM holds alive.
  textRanges* = initHashSet[ptr textRange]()

## TextUnit and TextPatternRangeEndpoint.
const
  unitCharacter* = 0
  unitFormat* = 1
  unitWord* = 2
  unitLine* = 3
  unitParagraph* = 4
  unitPage* = 5
  unitDocument* = 6

## Text attributes of UI Automation.
const
  attrBackgroundColor* = 40001
  attrFontName* = 40005
  attrFontSize* = 40006
  attrFontWeight* = 40007
  attrForegroundColor* = 40008
  attrIsItalic* = 40014
  attrIsReadOnly* = 40015
  attrStrikethroughStyle* = 40026
  attrUnderlineStyle* = 40030
  attrStyleID* = 40034

  styleIDHeading1* = 70001
  styleIDNormal* = 70012

## textRange is an ITextRangeProvider: runes start to end of the
## text of element e. It is raw memory COM holds; the GC ref in it
## is the element's, kept alive by textRanges.
type textRange* = object
  vtbl*: ptr uint
  refs*: int32
  e*: uiaElement
  start*, `end`*: int

proc newTextRange*(e: uiaElement, start, `end`: int): ptr textRange =
  let r = cast[ptr textRange](alloc0(sizeof(textRange)))
  r.vtbl = addr textRangeVtbl[0]
  r.refs = 1
  r.e = e
  r.start = start
  r.`end` = `end`
  r.clamp()
  textRanges.incl(r)
  discard e.addRef()
  r

proc rangeOf*(this: uint): ptr textRange =
  cast[ptr textRange](cast[pointer](this))

proc ptr*(r: ptr textRange): uint = cast[uint](cast[pointer](r))

proc release*(r: ptr textRange): int32 =
  dec r.refs
  if r.refs == 0:
    textRanges.excl(r)
    discard r.e.release()
    dealloc(r)
  r.refs

## utf8 encodes runes as UTF-8.
proc utf8*(u: openArray[Rune]): string =
  for r in u:
    result.add($r)

## runes returns the runes of the element's value, decoded once for
## each value it has, as ranges ask for them call after call.
proc runes*(e: uiaElement): seq[Rune] =
  if e.runesOf != e.n.value or e.textRunes.isNil:
    e.runesOf = e.n.value
    e.textRunes = toSeq(unicode.runes(e.n.value))
  e.textRunes

## text returns the runes of the element's text.
proc text*(r: ptr textRange): seq[Rune] = r.e.runes()

## clamp keeps the range within the text, start before end.
proc clamp*(r: ptr textRange) =
  let n = r.e.runes().len
  r.start = max(0, min(r.start, n))
  r.`end` = max(0, min(r.`end`, n))
  if r.`end` < r.start:
    r.`end` = r.start

## outRange stores a range at a pointer, which its caller owns.
proc outRange*(p: uint, r: ptr textRange): uint =
  if r.isNil:
    cast[ptr uint](cast[pointer](p))[] = 0
    return sOK
  cast[ptr uint](cast[pointer](p))[] = r.ptr()
  sOK

## rangeArray returns a SAFEARRAY of ranges, which own a reference
## each.
proc rangeArray*(ranges: varargs[ptr textRange]): uint =
  let arr = procSafeArrayCreateVector(uint(vtUnknown), 0,
    uint(ranges.len))
  for i, r in ranges:
    var index = int32(i)
    var v = r.ptr()
    discard procSafeArrayPutElement(arr, cast[uint](addr index),
      cast[uint](addr v))
    discard r.release()
  arr

## textProviderMethods are ITextProvider's.
proc textProviderMethods*(): seq[uint]

proc trLive*(this: uint): tuple[r: ptr textRange, hr: uint] =
  let r = rangeOf(this)
  if r.e.isNil or r.e.dead:
    return (nil, uiaElementNotAvailable)
  r.clamp()
  (r, sOK)

proc trOther*(p: uint): ptr textRange =
  if p == 0:
    return nil
  let r = rangeOf(p)
  if r notin textRanges:
    return nil
  r

proc trEndpoint*(r: ptr textRange, `end`: uint): int =
  if `end` != 0:
    return r.`end`
  r.start

## isBoundary reports whether rune i of text starts a unit: a word,
## a line or paragraph (after a newline), a run of a format
## (runs), or the document.
proc isBoundary*(text: openArray[Rune], runs: seq[AccessTextRun],
    i, unit: int): bool =
  let n = text.len
  if i <= 0 or i >= n:
    return true
  case unit
  of unitCharacter:
    return true
  of unitFormat:
    var lo = 0
    var hi = runs.len
    while lo < hi:
      let mid = (lo + hi) div 2
      if runs[mid].`end` >= i: hi = mid else: lo = mid + 1
    let k = lo
    return k < runs.len and
      (runs[k].start == i or runs[k].`end` == i)
  of unitWord:
    let a = text[i - 1]
    let b = text[i]
    return not b.isWhiteSpace and
      (a.isWhiteSpace or wordClass(a) != wordClass(b)) or
      a == Rune('\n')
  of unitLine, unitParagraph:
    return text[i - 1] == Rune('\n')
  else:
    discard
  false

## wordClass sorts runes into words, punctuation and spaces.
proc wordClass*(r: Rune): int =
  if isAlpha(r) or isDigit(r) or r == Rune('_'):
    return 1
  if r.isWhiteSpace:
    return 0
  2

## next returns the next start of a unit after i, or the end; prev
## the last one before i, or 0.
proc next*(text: openArray[Rune], runs: seq[AccessTextRun], i,
    unit: int): int =
  if unit == unitFormat:
    ## The nearest edge of a run after i, found by halves.
    var lo = 0
    var hi = runs.len
    while lo < hi:
      let mid = (lo + hi) div 2
      if runs[mid].`end` > i: hi = mid else: lo = mid + 1
    let k = lo
    if k < runs.len:
      if runs[k].start > i:
        return min(runs[k].start, text.len)
      return min(runs[k].`end`, text.len)
    return text.len
  var i = i
  inc i
  while i < text.len and not isBoundary(text, runs, i, unit):
    inc i
  min(i, text.len)

proc prev*(text: openArray[Rune], runs: seq[AccessTextRun], i,
    unit: int): int =
  if unit == unitFormat:
    ## The nearest edge of a run before i.
    var lo = 0
    var hi = runs.len
    while lo < hi:
      let mid = (lo + hi) div 2
      if runs[mid].start >= i: hi = mid else: lo = mid + 1
    let k = lo - 1
    if k >= 0:
      if runs[k].`end` < i:
        return runs[k].`end`
      return runs[k].start
    return 0
  var i = i
  dec i
  while i > 0 and not isBoundary(text, runs, i, unit):
    dec i
  max(i, 0)

## expand makes the range the unit holding its start.
proc expand*(r: ptr textRange, unit: int) =
  let text = r.text()
  let runs = r.e.n.textRuns
  let n = text.len
  if unit >= unitPage:
    r.start = 0
    r.`end` = n
    return
  var s = r.start
  if s >= n and n > 0:
    s = n - 1
  if not isBoundary(text, runs, s, unit):
    s = prev(text, runs, s, unit)
  r.start = s
  r.`end` = next(text, runs, s, unit)

## moveEndpoint moves the start (end false) or the end of the range
## by count units, the other with it where they cross, and returns
## how many it moved.
proc moveEndpoint*(r: ptr textRange, `end`: bool, unit,
    count: int): int =
  let text = r.text()
  let runs = r.e.n.textRuns
  var at = r.start
  if `end`:
    at = r.`end`
  var moved = 0
  var unit = unit
  if unit >= unitPage:
    unit = unitDocument
  var count = count
  while count > 0 and at < text.len:
    at = next(text, runs, at, unit)
    inc moved
    dec count
  while count < 0 and at > 0:
    at = prev(text, runs, at, unit)
    dec moved
    inc count
  if `end`:
    r.`end` = at
    r.start = min(r.start, at)
  else:
    r.start = at
    r.`end` = max(r.`end`, at)
  moved

## formatOf returns the value of a text attribute over the range:
## the format of each piece, the same for all, or the mixed value; a
## caret has that of the rune after it.
proc formatOf*(r: ptr textRange, attr: int): tuple[v: variant,
    ok: bool]

## runAt returns the run of runs holding rune i, or one without
## formats.
proc runAt*(runs: seq[AccessTextRun], i: int): AccessTextRun =
  var lo = 0
  var hi = runs.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if runs[mid].`end` > i: hi = mid else: lo = mid + 1
  let k = lo
  if k < runs.len and runs[k].start <= i:
    return runs[k]
  AccessTextRun()

## notSupported returns the value of attributes the text has not.
proc notSupported*(): variant =
  var unk: uint
  discard procUiaGetReservedNotSupportedValue(cast[uint](addr unk))
  variant(vt: vtUnknown, val: uint64(unk))

## bstrString reads a BSTR.
proc bstrString*(b: uint): string =
  if b == 0:
    return ""
  ## The length in bytes comes before the string.
  let n = cast[ptr uint32](cast[pointer](b - 4))[] div 2
  let p = cast[ptr UncheckedArray[uint16]](cast[pointer](b))
  var u = newSeq[uint16](n)
  for i in 0 ..< int(n):
    u[i] = p[i]
  u16str(u)

## sameVariant reports whether a value of an attribute is that of
## v, comparing strings by their text.
proc sameVariant*(a, b: variant): bool =
  if a.vt != b.vt:
    return false
  if a.vt == vtBSTR:
    return bstrString(uint(a.val)) == bstrString(uint(b.val))
  if a.vt == vtBool:
    return ((a.val and 0xFFFF) != 0) == ((b.val and 0xFFFF) != 0)
  if a.vt == vtI4:
    return uint32(a.val) == uint32(b.val)
  a.val == b.val

proc selectText*(e: uiaElement, start, `end`: int): uint

## The ITextRangeProvider callbacks.
proc trQueryInterface(this, riid, p: uint): uint {.stdcall.} =
  let iid = cast[ptr GUID](cast[pointer](riid))[]
  if iid == iidIUnknown or iid == iidITextRangeProvider:
    let r = rangeOf(this)
    inc r.refs
    cast[ptr uint](cast[pointer](p))[] = this
    return sOK
  cast[ptr uint](cast[pointer](p))[] = 0
  eNoInterface

proc trAddRef(this: uint): uint {.stdcall.} =
  let r = rangeOf(this)
  inc r.refs
  uint(r.refs)

proc trRelease(this: uint): uint {.stdcall.} =
  uint(rangeOf(this).release())

proc trClone(this, p: uint): uint {.stdcall.} =
  let r = rangeOf(this)
  outRange(p, newTextRange(r.e, r.start, r.`end`))

proc trCompare(this, q, p: uint): uint {.stdcall.} =
  let r = rangeOf(this)
  let o = trOther(q)
  setBool(p, not o.isNil and o.e == r.e and o.start == r.start and
    o.`end` == r.`end`)
  sOK

proc trCompareEndpoints(this, ep, q, qep, p: uint): uint {.stdcall.} =
  let r = rangeOf(this)
  let o = trOther(q)
  if o.isNil:
    return eInvalidArg
  cast[ptr int32](cast[pointer](p))[] =
    int32(trEndpoint(r, ep) - trEndpoint(o, qep))
  sOK

proc trExpandToEnclosingUnit(this, unit: uint): uint {.stdcall.} =
  let (r, hr) = trLive(this)
  if r.isNil:
    return hr
  r.expand(int(unit))
  sOK

proc trFindAttribute(this, attr, val, backward,
    p: uint): uint {.stdcall.} =
  let (r, hr) = trLive(this)
  if r.isNil:
    cast[ptr uint](cast[pointer](p))[] = 0
    return hr
  let want = cast[ptr variant](cast[pointer](val))[]
  let text = r.text()
  ## The pieces of one format within the range, in order.
  var pieces: seq[tuple[a, b: int]]
  var at = r.start
  while at < r.`end`:
    let to = min(next(text, r.e.n.textRuns, at, unitFormat),
      r.`end`)
    pieces.add((at, to))
    at = to
  if backward != 0:
    for i in 0 ..< pieces.len div 2:
      swap(pieces[i], pieces[pieces.len - 1 - i])
  for piece in pieces:
    var probe = textRange(e: r.e, start: piece.a,
      `end`: piece.b)
    let (v, ok) = addr(probe).formatOf(int(attr))
    let match = ok and sameVariant(v, want)
    if v.vt == vtBSTR:
      discard procSysFreeString(uint(v.val))
    if match:
      return outRange(p, newTextRange(r.e, piece.a, piece.b))
  outRange(p, nil)

proc trFindText(this, s, backward, ignoreCase,
    p: uint): uint {.stdcall.} =
  let (r, hr) = trLive(this)
  if r.isNil:
    cast[ptr uint](cast[pointer](p))[] = 0
    return hr
  let text = r.text()
  var hay = utf8(text[r.start ..< r.`end`])
  var needle = bstrString(s)
  if ignoreCase != 0:
    hay = hay.toLower()
    needle = needle.toLower()
  var i = hay.find(needle)
  if backward != 0:
    i = hay.rfind(needle)
  if needle == "" or i < 0:
    return outRange(p, nil)
  let at = r.start + runeLen(hay[0 ..< i])
  outRange(p, newTextRange(r.e, at, at + runeLen(needle)))

proc trGetAttributeValue(this, attr, p: uint): uint {.stdcall.} =
  let v = cast[ptr variant](cast[pointer](p))
  let (r, hr) = trLive(this)
  if r.isNil:
    v[] = variant()
    return hr
  let (value, ok) = r.formatOf(int(attr))
  if ok:
    v[] = value
  else:
    v[] = notSupported()
  sOK

proc trGetBoundingRectangles(this, p: uint): uint {.stdcall.} =
  let (r, hr) = trLive(this)
  if r.isNil:
    cast[ptr uint](cast[pointer](p))[] = 0
    return hr
  ## The field's box: the geometry of its characters is the
  ## content's.
  var rects: seq[float64]
  if r.`end` > r.start:
    let b = r.e.screenRect()
    rects = @[b.left, b.top, b.width, b.height]
  let arr = procSafeArrayCreateVector(uint(vtR8), 0,
    uint(rects.len))
  for i in 0 ..< rects.len:
    var index = int32(i)
    var v = rects[i]
    discard procSafeArrayPutElement(arr, cast[uint](addr index),
      cast[uint](addr v))
  cast[ptr uint](cast[pointer](p))[] = arr
  sOK

proc trGetEnclosingElement(this, p: uint): uint {.stdcall.} =
  out0(p, rangeOf(this).e, ifaceSimple)

proc trGetText(this, maxLength, p: uint): uint {.stdcall.} =
  let (r, hr) = trLive(this)
  if r.isNil:
    cast[ptr uint](cast[pointer](p))[] = 0
    return hr
  var u = utf16Units(utf8(r.text()[r.start ..< r.`end`]))
  let m = int32(maxLength)
  if m >= 0 and int(m) < u.len:
    u = u[0 ..< int(m)]
  cast[ptr uint](cast[pointer](p))[] = bstr(u16str(u))
  sOK

proc trMove(this, unit, count, p: uint): uint {.stdcall.} =
  let (r, hr) = trLive(this)
  if r.isNil:
    return hr
  let n = int(int32(count))
  let u = int(unit)
  var moved = 0
  if n == 0:
    discard
  elif r.start == r.`end`:
    ## An insertion point moves as one.
    moved = r.moveEndpoint(false, u, n)
    r.`end` = r.start
  elif u >= unitPage:
    ## The one page is the whole text: there is none to move to.
    r.start = 0
    r.`end` = r.text().len
  else:
    ## As the UIA documentation says: collapse to the start, back
    ## to the start of its unit, move by units, then take the unit
    ## there; a range doesn't move past the last unit.
    let text = r.text()
    let runs = r.e.n.textRuns
    var at = r.start
    if at < text.len and not isBoundary(text, runs, at, u):
      at = prev(text, runs, at, u)
    while moved < n:
      let nx = next(text, runs, at, u)
      if nx >= text.len or nx == at:
        break
      at = nx
      inc moved
    while moved > n and at > 0:
      at = prev(text, runs, at, u)
      dec moved
    r.start = at
    r.`end` = next(text, runs, at, u)
  cast[ptr int32](cast[pointer](p))[] = int32(moved)
  sOK

proc trMoveEndpointByUnit(this, ep, unit, count,
    p: uint): uint {.stdcall.} =
  let (r, hr) = trLive(this)
  if r.isNil:
    return hr
  cast[ptr int32](cast[pointer](p))[] = int32(
    r.moveEndpoint(ep != 0, int(unit), int(int32(count))))
  sOK

proc trMoveEndpointByRange(this, ep, q, qep: uint): uint {.stdcall.} =
  let r = rangeOf(this)
  let o = trOther(q)
  if o.isNil:
    return eInvalidArg
  let at = trEndpoint(o, qep)
  if ep != 0:
    r.`end` = at
    r.start = min(r.start, at)
  else:
    r.start = at
    r.`end` = max(r.`end`, at)
  sOK

proc trSelect(this: uint): uint {.stdcall.} =
  let (r, hr) = trLive(this)
  if r.isNil:
    return hr
  r.e.selectText(r.start, r.`end`)

proc trAddToSelection(this: uint): uint {.stdcall.} =
  uiaInvalidOperation

proc trRemoveFromSelection(this: uint): uint {.stdcall.} =
  uiaInvalidOperation

proc trScrollIntoView(this, top: uint): uint {.stdcall.} =
  let (r, hr) = trLive(this)
  if r.isNil:
    return hr
  r.e.act(accessScrollIntoView, "")

proc trGetChildren(this, p: uint): uint {.stdcall.} =
  let arr = procSafeArrayCreateVector(uint(vtUnknown), 0, 0)
  cast[ptr uint](cast[pointer](p))[] = arr
  sOK

## initTextRanges builds the vtable of ITextRangeProvider, once.
proc initTextRanges*() =
  textRangeVtbl = @[
    cast[uint](trQueryInterface),
    cast[uint](trAddRef),
    cast[uint](trRelease),
    cast[uint](trClone),
    cast[uint](trCompare),
    cast[uint](trCompareEndpoints),
    cast[uint](trExpandToEnclosingUnit),
    cast[uint](trFindAttribute),
    cast[uint](trFindText),
    cast[uint](trGetAttributeValue),
    cast[uint](trGetBoundingRectangles),
    cast[uint](trGetEnclosingElement),
    cast[uint](trGetText),
    cast[uint](trMove),
    cast[uint](trMoveEndpointByUnit),
    cast[uint](trMoveEndpointByRange),
    cast[uint](trSelect),
    cast[uint](trAddToSelection),
    cast[uint](trRemoveFromSelection),
    cast[uint](trScrollIntoView),
    cast[uint](trGetChildren)]

## ITextProvider's methods.
proc tpGetSelectionCb(this, p: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  cast[ptr uint](cast[pointer](p))[] =
    rangeArray(newTextRange(e, e.n.selStart, e.n.selEnd))
  sOK

proc tpGetVisibleRangesCb(this, p: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  cast[ptr uint](cast[pointer](p))[] =
    rangeArray(newTextRange(e, 0, e.runes().len))
  sOK

proc tpRangeFromChildCb(this, child, p: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  outRange(p, newTextRange(e, 0, 0))

proc tpRangeFromPointCb(this, a1, a2: uint): uint {.stdcall.} =
  ## RangeFromPoint(UiaPoint, out): the point, two doubles, comes
  ## by reference on x64 and in floating point registers on ARM64,
  ## where the out pointer is the next integer argument. Without
  ## the geometry of characters, the caret's place answers.
  let (e, hr) = liveElement(this)
  var p = a2
  when defined(arm64):
    p = a1
  if e.isNil:
    cast[ptr uint](cast[pointer](p))[] = 0
    return hr
  outRange(p, newTextRange(e, e.n.selEnd, e.n.selEnd))

proc tpGetDocumentRangeCb(this, p: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    cast[ptr uint](cast[pointer](p))[] = 0
    return hr
  outRange(p, newTextRange(e, 0, e.runes().len))

proc tpGetSupportedTextSelectionCb(this, p: uint): uint {.stdcall.} =
  ## SupportedTextSelection_Single
  cast[ptr int32](cast[pointer](p))[] = 1
  sOK

proc textProviderMethods*(): seq[uint] =
  @[cast[uint](tpGetSelectionCb),
    cast[uint](tpGetVisibleRangesCb),
    cast[uint](tpRangeFromChildCb),
    cast[uint](tpRangeFromPointCb),
    cast[uint](tpGetDocumentRangeCb),
    cast[uint](tpGetSupportedTextSelectionCb)]

## formatOf returns the value of a text attribute over the range:
## the format of each piece, the same for all, or the mixed value;
## a caret has that of the rune after it.
proc formatOf*(r: ptr textRange, attr: int): tuple[v: variant,
    ok: bool] =
  let n = r.e.n
  let text = r.text()
  proc value(run: AccessTextRun): tuple[v: variant, ok: bool] =
    case attr
    of attrFontName:
      var family = run.family
      if family == "" or family == "system-ui":
        family = "Segoe UI"
      return (variant(vt: vtBSTR, val: uint64(bstr(family))), true)
    of attrFontSize:
      var size = float64(run.size)
      if size <= 0:
        size = 14
      return (variant(vt: vtR8,
        val: cast[uint64](size * 0.75)), true)
    of attrFontWeight:
      var w = run.weight
      if w <= 0:
        w = 400
      return (variant(vt: vtI4, val: uint64(w)), true)
    of attrIsItalic:
      return (boolVariant(run.italic), true)
    of attrUnderlineStyle:
      if run.underline:
        ## TextDecorationLineStyle_Single
        return (variant(vt: vtI4, val: 1), true)
      return (variant(vt: vtI4), true)
    of attrStrikethroughStyle:
      if run.strikethrough:
        return (variant(vt: vtI4, val: 1), true)
      return (variant(vt: vtI4), true)
    of attrForegroundColor, attrBackgroundColor:
      var c = run.color
      if attr == attrBackgroundColor:
        c = run.background
      if c[3] == 0:
        return (variant(), false)
      ## COLORREF
      return (variant(vt: vtI4, val: uint64(c[0]) or
        (uint64(c[1]) shl 8) or (uint64(c[2]) shl 16)), true)
    of attrStyleID:
      if run.heading > 0:
        return (variant(vt: vtI4, val: uint64(
          styleIDHeading1 + min(run.heading, 9) - 1)), true)
      return (variant(vt: vtI4, val: uint64(styleIDNormal)), true)
    of attrIsReadOnly:
      return (boolVariant((n.states and accessReadOnly) !=
        AccessStates(0)), true)
    else:
      discard
    (variant(), false)
  ## The pieces of the range, of one format each.
  var start = r.start
  var `end` = r.`end`
  if start == `end`:
    `end` = min(start + 1, text.len)
    if start == `end` and start > 0:
      dec start
  var first: variant
  var firstOK = false
  var mixed = false
  var at = start
  while at < `end` or at == start:
    let run = runAt(n.textRuns, at)
    let (v, ok) = value(run)
    if at == start:
      first = v
      firstOK = ok
    elif ok != firstOK or not sameVariant(v, first):
      if v.vt == vtBSTR:
        discard procSysFreeString(uint(v.val))
      mixed = true
      break
    elif v.vt == vtBSTR:
      discard procSysFreeString(uint(v.val))
    if at >= `end`:
      break
    at = next(text, n.textRuns, at, unitFormat)
  if mixed:
    if first.vt == vtBSTR:
      discard procSysFreeString(uint(first.val))
    var unk: uint
    discard procUiaGetReservedMixedAttributeValue(
      cast[uint](addr unk))
    return (variant(vt: vtUnknown, val: uint64(unk)), true)
  (first, firstOK)

## selectText selects runes start to end of a text field, as
## assistive technology asks.
proc selectText*(e: uiaElement, start, `end`: int): uint =
  if e.dead:
    return uiaElementNotAvailable
  if (e.n.states and accessDisabled) != AccessStates(0):
    return uiaElementNotEnabled
  discard e.tree.s.send(SurfaceEvent(kind: accessAction,
    id: e.n.id, action: accessSelectText, `from`: start, to: `end`))
  sOK
