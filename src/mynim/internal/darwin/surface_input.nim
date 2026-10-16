## surface_input.go: the text around the caret of the focused text input
## is the document input methods see, with the marked text, the
## composition, in place of the selection while there is one.
## NSTextInputClient counts in UTF-16 units of that document; the content
## gets rune offsets in TextInputState.text.

proc stringOf(obj: id): string
proc runesBefore(s: string, units: int): int

proc utf16RuneLen(r: Rune): int =
  if r.int32 <= 0xFFFF: 1 else: 2

## document returns the text input methods see, and where the selection,
## or the marked text, starts and ends in it, in runes.
proc document(s: macSurface): tuple[doc: seq[Rune], start, `end`: int] =
  let text = toRunes(s.input.text)
  let start = max(0, min(s.input.start, text.len))
  let `end` = max(start, min(s.input.`end`, text.len))
  if s.marked == "":
    return (text, start, `end`)
  let m = toRunes(s.marked)
  var doc = newSeqOfCap[Rune](text.len - (`end` - start) + m.len)
  doc.add(text[0 ..< start])
  doc.add(m)
  doc.add(text[`end` ..< text.len])
  (doc, start, start + m.len)

## units returns how many UTF-16 units runes take.
proc units(runes: openArray[Rune]): int =
  for r in runes:
    result += utf16RuneLen(r)

## runeAt returns the rune of runes that UTF-16 unit u starts, or the end.
proc runeAt(runes: openArray[Rune], u: int): int =
  var u = u
  for i, r in runes:
    if u <= 0:
      return i
    u -= utf16RuneLen(r)
  runes.len

proc markedRange(s: macSurface): nsRange =
  let c = s.input.client
  if c != nil:
    let (r, ok) = c.markedRange()
    if ok:
      return nsRange(location: uint(r.start),
                     length: uint(max(0, r.`end` - r.start)))
    return nsRange(location: nsNotFound)
  if s.marked == "":
    return nsRange(location: nsNotFound)
  let (doc, start, `end`) = s.document()
  nsRange(location: uint(units(doc[0 ..< start])),
          length: uint(units(doc[start ..< `end`])))

proc selectedRange(s: macSurface): nsRange =
  if not s.input.active:
    return nsRange(location: nsNotFound)
  let c = s.input.client
  if c != nil:
    let r = c.selection().range
    return nsRange(location: uint(r.start),
                   length: uint(max(0, r.`end` - r.start)))
  let (doc, start, `end`) = s.document()
  if s.marked != "":
    return nsRange(location: uint(units(doc[0 ..< start])) +
                     s.markedSel.location, length: s.markedSel.length)
  nsRange(location: uint(units(doc[0 ..< start])),
          length: uint(units(doc[start ..< `end`])))

## textRange converts a range of the document, in UTF-16 units, into
## runes of TextInputState.text: a range in the marked text stands for
## the selection it replaces.
proc textRange(s: macSurface, r: nsRange): tuple[`from`, to: int] =
  let (doc, start, `end`) = s.document()
  let lo = runeAt(doc, int(min(r.location, uint(1 shl 31))))
  let hi = runeAt(doc, int(min(r.location + r.length, uint(1 shl 31))))
  if s.marked == "":
    return (lo, hi)
  let n = toRunes(s.input.text).len
  let sel = max(0, min(s.input.`end`, n)) - max(0, min(s.input.start, n))
  proc conv(i: int, after: bool): int =
    if i <= start:
      return i
    if i < `end`: # in the marked text
      if after:
        return start + max(sel, 0)
      return start
    i - (`end` - start) + max(sel, 0)
  (conv(lo, false), conv(hi, true))

proc substring(s: macSurface, r: nsRange, actual: var nsRange,
               hasActual: bool): id =
  let c = s.input.client
  if c != nil:
    let (text, rangeUsed) = c.textForRange(TextRange(
      start: int(min(r.location, uint(1 shl 31))),
      `end`: int(min(r.location + r.length, uint(1 shl 31)))))
    if hasActual:
      actual = nsRange(location: uint(rangeUsed.start),
        length: uint(max(0, rangeUsed.`end` - rangeUsed.start)))
    return autorelease(send(send(`class`("NSAttributedString"), "alloc"),
      "initWithString:", argu(nsString(text))))
  let (doc, _, _) = s.document()
  var u16 = newSeqOfCap[uint16](doc.len)
  for ru in doc:
    if ru.int32 <= 0xFFFF:
      u16.add(uint16(ru.int32))
    else:
      let v = ru.int32 - 0x10000
      u16.add(uint16(0xD800 + (v shr 10)))
      u16.add(uint16(0xDC00 + (v and 0x3FF)))
  let lo = int(min(r.location, uint(u16.len)))
  let hi = int(min(uint(lo) + r.length, uint(u16.len)))
  if hasActual:
    actual = nsRange(location: uint(lo), length: uint(hi - lo))
  var runes = newSeqOfCap[Rune](hi - lo)
  var i = lo
  while i < hi:
    let u = u16[i]
    if u >= 0xD800 and u <= 0xDBFF and i + 1 < hi:
      runes.add(Rune(0x10000 + ((int(u) - 0xD800) shl 10) +
        int(u16[i + 1]) - 0xDC00))
      i += 2
    else:
      runes.add(Rune(u))
      inc i
  let str = send(send(`class`("NSAttributedString"), "alloc"),
    "initWithString:", argu(nsString($runes)))
  discard autorelease(str)

proc clientRange(r: nsRange): ref TextRange =
  if r.location == nsNotFound:
    return nil
  new(result)
  result[] = TextRange(start: int(min(r.location, uint(1 shl 31))),
    `end`: int(min(r.location + r.length, uint(1 shl 31))))

proc setMarkedText(s: macSurface, text: string,
                   selected, replacement: nsRange) =
  if s.input.noInputMethod:
    return
  let c = s.input.client
  if c != nil:
    c.setMarkedText(clientRange(replacement), text, TextRange(
      start: int(selected.location),
      `end`: int(selected.location + selected.length)))
    return
  var ev = platform.SurfaceEvent(kind: textComposition, text: text,
    caret: runesBefore(text, int(selected.location)))
  if replacement.location != nsNotFound:
    ev.replace = true
    (ev.`from`, ev.to) = s.textRange(replacement)
  s.marked = text
  s.markedSel = selected
  discard s.send(ev)

proc insertText(s: macSurface, text: string, replacement: nsRange) =
  let c = s.input.client
  if c != nil:
    c.replaceText(clientRange(replacement), text)
    return
  var ev = platform.SurfaceEvent(kind: textInput, text: text)
  if replacement.location != nsNotFound:
    ev.replace = true
    (ev.`from`, ev.to) = s.textRange(replacement)
  if s.marked != "":
    s.marked = ""
    discard s.send(platform.SurfaceEvent(kind: textComposition))
  if text != "" or ev.replace:
    discard s.send(ev)

proc hasMarkedText(s: macSurface): bool =
  let c = s.input.client
  if c != nil:
    let (_, ok) = c.markedRange()
    return ok
  s.marked != ""

proc unmarkText(s: macSurface) =
  let c = s.input.client
  if c != nil:
    c.unmarkText()
    return
  if s.marked != "":
    s.marked = ""
    discard s.send(platform.SurfaceEvent(kind: textComposition))
