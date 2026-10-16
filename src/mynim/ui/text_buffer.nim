## Indexed, persistent UTF-8 text storage for large editable documents.

import std/locks
import mynim/internal/rope as textRope

type
  TextBuffer* = ref object ## Mutable synchronized text; construct with `newTextBuffer`.
    mu: Lock
    root: textRope.Node
    version: uint64

  TextSnapshot* = object ## Immutable document version sharing rope chunks.
    root: textRope.Node
    version: uint64

  TextBufferEditResult* = object ## Outcome of an optimistic UTF-16 range edit.
    snapshot*: TextSnapshot ## The resulting snapshot, or current snapshot on conflict.
    replacedRange*: platform.TextRange ## Actual whole-rune range before replacement.
    committed*: bool ## False when the buffer no longer matched the source snapshot.

  TextWriter* = proc(chunk: string): int {.closure.} ## Number of bytes consumed.

proc newTextBuffer*(text = ""): TextBuffer =
  ## Creates indexed storage owning its text chunks.
  new(result)
  initLock(result.mu)
  result.root = textRope.build(text)

proc forkTextBuffer(snapshot: TextSnapshot): TextBuffer =
  ## Creates a copy-on-write editor view of an immutable document version.
  new(result)
  initLock(result.mu)
  result.root = snapshot.root
  result.version = snapshot.version

proc snapshot*(buffer: TextBuffer): TextSnapshot =
  ## Returns an immutable snapshot that remains valid after later edits.
  if buffer == nil:
    return
  withLock buffer.mu:
    result.root = buffer.root
    result.version = buffer.version

proc len*(snapshot: TextSnapshot): int =
  ## Returns the document's rune count.
  textRope.sum(snapshot.root).runes

proc byteLen*(snapshot: TextSnapshot): int =
  ## Returns the document's UTF-8 byte count.
  textRope.sum(snapshot.root).bytes

proc utf16Len*(snapshot: TextSnapshot): int =
  ## Returns the document's UTF-16 code-unit count.
  textRope.sum(snapshot.root).units

proc lineCount*(snapshot: TextSnapshot): int =
  ## Returns the number of lines, including an empty trailing line.
  textRope.sum(snapshot.root).lines + 1

proc version*(snapshot: TextSnapshot): uint64 =
  ## Returns the buffer edit version captured by this snapshot.
  snapshot.version

proc same*(a, b: TextSnapshot): bool =
  ## Reports whether snapshots share the same persistent document root.
  a.root == b.root

proc byteOffset*(snapshot: TextSnapshot; runeIndex: int): int =
  ## Maps a clamped rune offset to a UTF-8 byte offset.
  textRope.byteOfRune(snapshot.root, runeIndex)

proc runeOffsetAtByte*(snapshot: TextSnapshot; byteIndex: int): int =
  ## Maps a clamped byte offset to its containing rune, rounding down.
  textRope.runeOfByte(snapshot.root, byteIndex)

proc byteSlice*(snapshot: TextSnapshot; start, pastLast: int): string =
  ## Returns an exact clamped UTF-8 byte range.
  let total = snapshot.byteLen()
  let first = max(0, min(start, total))
  let last = max(0, min(pastLast, total))
  if first >= last:
    return
  result = newStringOfCap(last - first)
  textRope.read(snapshot.root, first, last, result)

proc len*(buffer: TextBuffer): int =
  ## Returns the current document's rune count.
  buffer.snapshot().len()

proc byteLen*(buffer: TextBuffer): int =
  ## Returns the current document's UTF-8 byte count.
  buffer.snapshot().byteLen()

proc utf16Len*(buffer: TextBuffer): int =
  ## Returns the current document's UTF-16 code-unit count.
  buffer.snapshot().utf16Len()

proc lineCount*(buffer: TextBuffer): int =
  ## Returns the number of lines, including an empty trailing line.
  buffer.snapshot().lineCount()

proc version*(buffer: TextBuffer): uint64 =
  ## Returns the current document edit version.
  buffer.snapshot().version()

proc slice*(snapshot: TextSnapshot; start, pastLast: int): string =
  ## Returns a clamped half-open rune range.
  let n = snapshot.len()
  let first = max(0, min(min(start, pastLast), n))
  let last = max(0, min(max(start, pastLast), n))
  let firstByte = textRope.byteOfRune(snapshot.root, first)
  let lastByte = textRope.byteOfRune(snapshot.root, last)
  if firstByte >= lastByte:
    return
  result = newStringOfCap(lastByte - firstByte)
  textRope.read(snapshot.root, firstByte, lastByte, result)

proc slice*(buffer: TextBuffer; start, pastLast: int): string =
  ## Returns a clamped half-open rune range of the current document.
  buffer.snapshot().slice(start, pastLast)

proc editorWordRune(rune: Rune): bool =
  isAlpha(rune) or lookupGeneralCategory(int32(rune)) == Nd or
    int32(rune) == ord('_')

proc nextWordRune(snapshot: TextSnapshot; index: int): int =
  ## Returns the end of the next word, skipping punctuation and whitespace.
  const chunkRunes = 128
  result = max(0, min(index, snapshot.len()))
  var inWord = false
  while result < snapshot.len():
    let pastLast = min(result + chunkRunes, snapshot.len())
    let chunk = snapshot.slice(result, pastLast)
    for rune in chunk.runes:
      if editorWordRune(rune):
        inWord = true
      elif inWord:
        return
      inc result

proc prevWordRune(snapshot: TextSnapshot; index: int): int =
  ## Returns the start of the preceding word, skipping punctuation and space.
  const chunkRunes = 128
  result = max(0, min(index, snapshot.len()))
  var inWord = false
  while result > 0:
    let first = max(result - chunkRunes, 0)
    var runes: seq[Rune]
    for rune in snapshot.slice(first, result).runes:
      runes.add(rune)
    var i = runes.len
    while i > 0:
      dec i
      if editorWordRune(runes[i]):
        inWord = true
      elif inWord:
        return
      result = first + i

proc nextWordRune(text: string; index: int): int =
  ## Returns the end of the next word in a short, materialized field.
  var runes: seq[Rune]
  for rune in text.runes:
    runes.add(rune)
  result = max(0, min(index, runes.len))
  var inWord = false
  while result < runes.len:
    if editorWordRune(runes[result]):
      inWord = true
    elif inWord:
      return
    inc result

proc prevWordRune(text: string; index: int): int =
  ## Returns the start of the preceding word in a short, materialized field.
  var runes: seq[Rune]
  for rune in text.runes:
    runes.add(rune)
  result = max(0, min(index, runes.len))
  var inWord = false
  while result > 0:
    let previous = result - 1
    if editorWordRune(runes[previous]):
      inWord = true
    elif inWord:
      return
    result = previous

proc `$`*(snapshot: TextSnapshot): string =
  ## Materializes the snapshot as UTF-8 text.
  snapshot.slice(0, snapshot.len())

proc `$`*(buffer: TextBuffer): string =
  ## Materializes the current document as UTF-8 text.
  $buffer.snapshot()

proc utf16Offset*(snapshot: TextSnapshot; runeIndex: int): int =
  ## Maps a clamped rune index to a UTF-16 code-unit offset.
  let byteIndex = textRope.byteOfRune(snapshot.root, runeIndex)
  textRope.prefix(snapshot.root, byteIndex).units

proc runeOffset*(snapshot: TextSnapshot; utf16Index: int): int =
  ## Maps a clamped UTF-16 offset to a rune index, rounding down in surrogates.
  let units = max(0, min(utf16Index, snapshot.utf16Len()))
  textRope.runeOfUnit(snapshot.root, units)

proc utf16Offset*(buffer: TextBuffer; runeIndex: int): int =
  ## Maps a rune index in the current document to a UTF-16 offset.
  buffer.snapshot().utf16Offset(runeIndex)

proc runeOffset*(buffer: TextBuffer; utf16Index: int): int =
  ## Maps a UTF-16 offset in the current document to a rune index.
  buffer.snapshot().runeOffset(utf16Index)

proc textForRange*(snapshot: TextSnapshot; range: platform.TextRange):
    tuple[text: string, actual: platform.TextRange] =
  ## Reads a UTF-16 range and returns the actual whole-rune range read.
  let normalized = platform.normalizeTextRange(range)
  let first = snapshot.runeOffset(normalized.start)
  let last = snapshot.runeOffset(normalized.`end`)
  result.text = snapshot.slice(first, last)
  result.actual = platform.TextRange(start: snapshot.utf16Offset(first),
                                     `end`: snapshot.utf16Offset(last))

proc textForRange*(buffer: TextBuffer; range: platform.TextRange):
    tuple[text: string, actual: platform.TextRange] =
  ## Reads and normalizes a native UTF-16 range in the current document.
  buffer.snapshot().textForRange(range)

proc lineRange*(snapshot: TextSnapshot; line: int): tuple[start, `end`: int] =
  ## Returns rune offsets for a line, excluding its following newline.
  let line = max(0, min(line, snapshot.lineCount() - 1))
  let firstByte = textRope.lineStart(snapshot.root, line)
  let lastByte = if line + 1 < snapshot.lineCount():
      textRope.lineStart(snapshot.root, line + 1) - 1
    else:
      snapshot.byteLen()
  result.start = textRope.prefix(snapshot.root, firstByte).runes
  result.`end` = textRope.prefix(snapshot.root, lastByte).runes

proc line*(snapshot: TextSnapshot; index: int): string =
  ## Returns a line without its following newline; indices clamp.
  let range = snapshot.lineRange(index)
  snapshot.slice(range.start, range.`end`)

proc lineAt*(snapshot: TextSnapshot; runeIndex: int): int =
  ## Returns the line containing a clamped rune offset.
  let byteIndex = textRope.byteOfRune(snapshot.root, runeIndex)
  textRope.prefix(snapshot.root, byteIndex).lines

proc lineRange*(buffer: TextBuffer; line: int): tuple[start, `end`: int] =
  ## Returns rune offsets for a current-document line.
  buffer.snapshot().lineRange(line)

proc line*(buffer: TextBuffer; index: int): string =
  ## Returns a current-document line without its following newline.
  buffer.snapshot().line(index)

proc lineAt*(buffer: TextBuffer; runeIndex: int): int =
  ## Returns the current-document line containing a rune offset.
  buffer.snapshot().lineAt(runeIndex)

proc writeTo*(snapshot: TextSnapshot; writer: TextWriter): int64 =
  ## Writes rope chunks and returns the byte count. Short writes are retried;
  ## an invalid count raises IOError.
  if writer == nil:
    return
  var written = 0'i64
  textRope.chunks(snapshot.root, 0, snapshot.byteLen(),
    proc(chunk: string): bool =
      var offset = 0
      while offset < chunk.len:
        let count = writer(chunk[offset .. ^1])
        if count <= 0 or count > chunk.len - offset:
          raise newException(IOError, "ui: text writer returned an invalid count")
        offset += count
        written += int64(count)
      true)
  result = written

proc writeTo*(buffer: TextBuffer; writer: TextWriter): int64 =
  ## Writes the current document and returns the byte count.
  buffer.snapshot().writeTo(writer)

proc requireTextBuffer(buffer: TextBuffer) =
  if buffer == nil:
    raise newException(ValueError,
      "ui: cannot mutate a nil TextBuffer; use newTextBuffer")

proc commitTextBuffer(buffer: TextBuffer; before: TextSnapshot; text: string):
    tuple[snapshot: TextSnapshot, committed: bool] =
  buffer.requireTextBuffer()
  let root = textRope.build(text)
  withLock buffer.mu:
    if buffer.root != before.root or buffer.version != before.version:
      result.snapshot = TextSnapshot(root: buffer.root, version: buffer.version)
    else:
      buffer.root = root
      inc buffer.version
      result.snapshot = TextSnapshot(root: buffer.root, version: buffer.version)
      result.committed = true

proc set*(buffer: TextBuffer; text: string) =
  ## Replaces the document; existing snapshots keep their previous content.
  ## Raises `ValueError` when buffer is nil.
  buffer.requireTextBuffer()
  let root = textRope.build(text)
  withLock buffer.mu:
    buffer.root = root
    inc buffer.version

proc restore*(buffer: TextBuffer; snapshot: TextSnapshot) =
  ## Adopts a snapshot in constant time and advances the document version.
  ## Raises `ValueError` when buffer is nil.
  buffer.requireTextBuffer()
  withLock buffer.mu:
    buffer.root = snapshot.root
    inc buffer.version

proc replace*(buffer: TextBuffer; start, pastLast: int; text: string) =
  ## Replaces a clamped half-open rune range.
  ## Raises `ValueError` when buffer is nil.
  buffer.requireTextBuffer()
  withLock buffer.mu:
    let n = textRope.sum(buffer.root).runes
    let first = max(0, min(min(start, pastLast), n))
    let last = max(0, min(max(start, pastLast), n))
    let firstByte = textRope.byteOfRune(buffer.root, first)
    let lastByte = textRope.byteOfRune(buffer.root, last)
    buffer.root = textRope.replaceBytes(buffer.root, firstByte, lastByte, text)
    inc buffer.version

proc replaceUtf16*(buffer: TextBuffer; range: platform.TextRange;
                   text: string): platform.TextRange =
  ## Replaces a native UTF-16 range, rounding surrogate interiors down.
  ## Raises `ValueError` when buffer is nil.
  buffer.requireTextBuffer()
  withLock buffer.mu:
    let units = textRope.sum(buffer.root).units
    let normalized = platform.normalizeTextRange(range)
    let first = textRope.runeOfUnit(buffer.root,
      max(0, min(normalized.start, units)))
    let last = textRope.runeOfUnit(buffer.root,
      max(0, min(normalized.`end`, units)))
    result = platform.TextRange(
      start: textRope.prefix(buffer.root,
        textRope.byteOfRune(buffer.root, first)).units,
      `end`: textRope.prefix(buffer.root,
        textRope.byteOfRune(buffer.root, last)).units)
    buffer.root = textRope.replaceBytes(buffer.root,
      textRope.byteOfRune(buffer.root, first),
      textRope.byteOfRune(buffer.root, last), text)
    inc buffer.version

proc replaceUtf16IfCurrent*(buffer: TextBuffer; before: TextSnapshot;
                            range: platform.TextRange; text: string):
    TextBufferEditResult =
  ## Replaces a UTF-16 range only if `before` is still the current snapshot.
  ## The edit runs directly on the rope and does not materialize the document.
  ## On conflict, returns the current snapshot with `committed` false.
  ## Raises `ValueError` when buffer is nil.
  buffer.requireTextBuffer()
  withLock buffer.mu:
    if buffer.root != before.root or buffer.version != before.version:
      result.snapshot = TextSnapshot(root: buffer.root, version: buffer.version)
      return
    let units = textRope.sum(buffer.root).units
    let normalized = platform.normalizeTextRange(range)
    let first = textRope.runeOfUnit(buffer.root,
      max(0, min(normalized.start, units)))
    let last = textRope.runeOfUnit(buffer.root,
      max(0, min(normalized.`end`, units)))
    let firstByte = textRope.byteOfRune(buffer.root, first)
    let lastByte = textRope.byteOfRune(buffer.root, last)
    result.replacedRange = platform.TextRange(
      start: textRope.prefix(buffer.root, firstByte).units,
      `end`: textRope.prefix(buffer.root, lastByte).units)
    buffer.root = textRope.replaceBytes(buffer.root, firstByte, lastByte, text)
    inc buffer.version
    result.snapshot = TextSnapshot(root: buffer.root, version: buffer.version)
    result.committed = true
