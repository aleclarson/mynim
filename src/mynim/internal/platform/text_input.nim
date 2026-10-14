## platform/text_input.go — UTF-16 text input helpers for input methods.
## (TextRange and TextSelection live in types.nim so ifaces.nim can use
## them.)

import std/unicode

proc caret*(s: TextSelection): int =
  if s.reversed: s.`range`.start else: s.`range`.`end`

## InputComposition preserves the native end-preedit/commit ordering
## without owning text. Some input methods unmark before delivering
## their result.
type
  InputComposition* = object
    pending: ref TextRange

proc reset*(c: var InputComposition) = c.pending = nil

proc `end`*(c: var InputComposition, client: TextInputClient) =
  let (r, ok) = client.markedRange()
  if ok:
    let rr = r
    c.pending = new TextRange
    c.pending[] = rr
  else:
    c.pending = nil
  client.unmarkText()

proc replace*(c: var InputComposition, client: TextInputClient,
              r: ref TextRange, text: string) =
  var r = r
  if r == nil and c.pending != nil: r = c.pending
  c.pending = nil
  client.replaceText(r, text)

proc utf16Len*(s: string): int =
  ## Counts native text offsets without allocating an encoded string.
  for r in runes(s):
    result += (if ord(r) < 0x10000: 1 else: 2)

proc utf16ByteOffset*(s: string, offset: int): int =
  ## Byte index of a UTF-16 unit offset, rounded down to its rune.
  var units = 0
  var bytePos = 0
  while bytePos < s.len:
    let n = runeLenAt(s, bytePos)
    let unitsN = if n <= 3: 1 else: 2
    if offset < units + unitsN: return bytePos
    units += unitsN
    bytePos += n
  s.len

proc normalizeTextRange*(r: TextRange): TextRange =
  TextRange(start: max(0, min(r.start, r.`end`)),
            `end`: max(0, max(r.start, r.`end`)))

type
  TextContext* = object
    ## A bounded window of a client document, with preedit removed as
    ## GTK and IMM32 surrounding-text protocols expect. Positions in
    ## text are UTF-16 units; `range` maps them back to the client's
    ## document.
    text*: string
    start*, `end`*, caret*, base*: int
    mark: TextRange
    hasMark: bool

proc runeCount(s: string): int =
  for r in runes(s): inc result

proc clientTextContext(client: TextInputClient, before, after: int): TextContext =
  let sel = client.selection()
  var r = normalizeTextRange(sel.`range`)
  var (mark, marked) = client.markedRange()
  if marked:
    mark = normalizeTextRange(mark)
    r = TextRange(start: min(r.start, mark.start), `end`: max(r.`end`, mark.`end`))
  ## A selection may cover a huge document. Query a bounded window
  ## around its active end; full text remains available through
  ## textForRange.
  var caret = max(0, sel.caret)
  if marked: caret = mark.start
  var wanted = TextRange(start: max(0, caret - before), `end`: caret + after)
  if marked:
    wanted = TextRange(start: min(wanted.start, mark.start),
                       `end`: max(wanted.`end`, mark.`end`))
  let (text, actualRaw) = client.textForRange(wanted)
  let actual = normalizeTextRange(actualRaw)
  var c = TextContext(text: text, base: actual.start, mark: mark,
                      hasMark: marked and mark.start >= actual.start and
                             mark.`end` <= actual.`end`)
  if c.hasMark:
    let a = utf16ByteOffset(text, mark.start - actual.start)
    let z = utf16ByteOffset(text, mark.`end` - actual.start)
    c.text = text[0 ..< a] & text[z .. ^1]
  proc local(i: int): int =
    var i = i
    if c.hasMark:
      if i >= mark.`end`: i -= mark.`end` - mark.start
      elif i > mark.start: i = mark.start
    max(0, min(i - c.base, utf16Len(c.text)))
  c.start = local(r.start); c.`end` = local(r.`end`)
  c.caret = local(sel.caret)
  if marked:
    c.start = local(mark.start); c.`end` = c.start
    c.caret = c.start
  c

proc clientTextContext*(client: TextInputClient): TextContext =
  clientTextContext(client, 1024, 1024)

proc `range`*(c: TextContext, r: TextRange): TextRange =
  ## Maps a range of the surrounding text to the actual document. A
  ## collapsed position at preedit stays collapsed; an explicit range
  ## crossing it includes preedit, so replacement remains one client
  ## operation.
  var r = normalizeTextRange(r)
  let n = utf16Len(c.text)
  r = TextRange(start: min(r.start, n) + c.base,
                `end`: min(r.`end`, n) + c.base)
  if c.hasMark:
    if r.start > c.mark.start: r.start += c.mark.`end` - c.mark.start
    if r.`end` > c.mark.start: r.`end` += c.mark.`end` - c.mark.start
  r

proc deleteRange*(c: TextContext, offset, count: int): TextRange =
  ## Maps GTK character offsets around the selection's end, rather than
  ## confusing Unicode characters with UTF-16 or UTF-8 offsets.
  let caretByte = utf16ByteOffset(c.text, c.caret)
  let caretRune = runeCount(c.text[0 ..< caretByte])
  var runesArr: seq[Rune]
  for r in runes(c.text): runesArr.add(r)
  let a = max(0, min(caretRune + offset, runesArr.len))
  let z = max(a, min(a + max(count, 0), runesArr.len))
  proc utf16Of(rs: seq[Rune]): int =
    for r in rs: result += (if ord(r) < 0x10000: 1 else: 2)
  c.`range`(TextRange(start: utf16Of(runesArr[0 ..< a]),
                      `end`: utf16Of(runesArr[0 ..< z])))

proc clientDeleteRange*(client: TextInputClient, offset, count: int): TextRange =
  ## Can query beyond the usual surrounding window when an input method
  ## asks to replace more text. GTK offsets count Unicode runes.
  let before = max(0, -offset) * 2
  let after = max(0, offset + max(count, 0)) * 2
  clientTextContext(client, before, after).deleteRange(offset, count)
