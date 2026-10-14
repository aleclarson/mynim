## surface_input.nim (surface_input.go): WM_IME_REQUEST handling —
## IMR_DOCUMENTFEED to convert in context, IMR_RECONVERTSTRING to
## convert again what was typed, whose range
## IMR_CONFIRMRECONVERTSTRING then settles. The composition that
## follows replaces that range.

const
  imrReconvertString* = 0x0004'u32
  imrConfirmReconvertString* = 0x0005'u32
  imrDocumentFeed* = 0x0007'u32

## reconvertString is RECONVERTSTRING, which the string follows in
## memory. Lengths count UTF-16 units; offsets, bytes from the
## string's start.
type reconvertString* = object
  size*, version*, strLen*, strOffset*: uint32
  compStrLen*, compStrOffset*: uint32
  targetStrLen*, targetStrOffset*: uint32

## unitOffset returns the UTF-16 offset of rune i of s.
proc unitOffset*(s: string, i: int): int =
  var i = i
  for r in runes(s):
    if i == 0:
      break
    result.inc utf16Len($r)
    dec i

## runeOffset returns the rune offset of UTF-16 unit i.
proc runeOffset*(units: openArray[uint16], i: int): int =
  runeLen(units.toOpenArray(0, i - 1))

## imeRequest answers WM_IME_REQUEST.
proc imeRequest*(s: w32Surface, wp, lp: uint): uint =
  if not s.input.active:
    return 0
  var units = utf16Units(s.input.text)
  var context: TextContext
  var start = unitOffset(s.input.text, s.input.start)
  var `end` = unitOffset(s.input.text, s.input.`end`)
  let c = s.input.client
  if not c.isNil:
    context = clientTextContext(c)
    units = utf16Units(context.text)
    start = context.start
    `end` = context.`end`
  case uint32(wp)
  of imrDocumentFeed, imrReconvertString:
    let head = uint32(sizeof(reconvertString))
    let size = head + uint32(units.len) * 2
    if lp == 0:
      return uint(size)
    let rs = cast[ptr reconvertString](cast[pointer](lp))
    if rs.size < size:
      return 0
    rs[] = reconvertString(size: size, strLen: uint32(units.len),
      strOffset: head, compStrLen: uint32(`end` - start),
      compStrOffset: uint32(start) * 2,
      targetStrLen: uint32(`end` - start),
      targetStrOffset: uint32(start) * 2)
    let dst = cast[ptr UncheckedArray[uint16]](
      cast[pointer](cast[uint](cast[pointer](lp)) + uint(head)))
    for i in 0 ..< units.len:
      dst[i] = units[i]
    return uint(size)
  of imrConfirmReconvertString:
    let rs = cast[ptr reconvertString](cast[pointer](lp))
    let `from` = int(rs.compStrOffset div 2)
    let to = `from` + int(rs.compStrLen)
    if `from` < 0 or to > units.len:
      return 0
    if not c.isNil:
      let r = context.`range`(TextRange(start: `from`, `end`: to))
      s.reconvert = new (ref tuple[a, b: int])
      s.reconvert[] = (r.start, r.`end`)
    else:
      s.reconvert = new (ref tuple[a, b: int])
      s.reconvert[] = (runeOffset(units, `from`),
        runeOffset(units, to))
    return 1
  else:
    discard
  0

## composed sends what an input method composed or committed, in
## place of the text it reconverts, if any.
proc composed*(s: w32Surface, ev: SurfaceEvent) =
  var ev = ev
  if not s.reconvert.isNil:
    ev.replace = true
    ev.`from` = s.reconvert.a
    ev.to = s.reconvert.b
    s.reconvert = nil
  let c = s.input.client
  if not c.isNil:
    var r: ref TextRange
    if ev.replace:
      r = new TextRange
      r[] = TextRange(start: ev.`from`, `end`: ev.to)
    if ev.kind == textInput:
      s.clientComposition.replace(c, r, ev.text)
    else:
      s.clientComposition.reset()
      let rr = toSeq(runes(ev.text))
      let caret = utf16Len($rr[0 ..< min(ev.caret, rr.len)])
      c.setMarkedText(r, ev.text,
        TextRange(start: caret, `end`: caret))
    return
  discard s.send(ev)
