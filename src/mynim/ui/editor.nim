## Persistent text buffers and byte-based positions for native code editors.

import std/[algorithm, locks, strutils]
import mynim/ui as ui

type
  Edit* = object ## A UTF-8 byte range to replace.
    start*: int ## Inclusive byte offset in the source document.
    pastLast*: int ## Exclusive byte offset in the source document.
    text*: string ## Replacement text.

  Pos* = object ## A zero-based line and UTF-8 byte column.
    line*: int
    column*: int

  Selection* = object ## Byte offsets with the caret at `head`.
    anchor*: int
    head*: int

  Snapshot* = object ## Immutable editor-buffer version.
    document: ui.TextSnapshot
    crlf: bool

  Buffer* = ref object ## Thread-safe document text, save state, and undo history.
    mu: Lock
    document: ui.TextBuffer
    saved: ui.TextSnapshot
    undo: seq[ui.TextSnapshot]
    redo: seq[ui.TextSnapshot]
    crlf: bool
    transactionDepth: int
    transactionBefore: ui.TextSnapshot

  State* = ref object ## App-owned state for one native code-editor view.
    buffer*: Buffer ## The document edited by the view.
    readOnly*: bool ## Keeps text selectable while preventing edits.
    label*: string ## Accessible name; defaults to "Code editor".
    fontFamily*: string ## Text family; defaults to the system monospace family.
    fontSize*: float32 ## Text size in DIPs; defaults to 13.
    caretSelection: Selection
    selectionPending: bool

const
  maxUndoSteps = 10_000

proc start*(selection: Selection): int =
  ## Returns the lower byte offset, regardless of selection direction.
  min(selection.anchor, selection.head)

proc pastLast*(selection: Selection): int =
  ## Returns the upper byte offset, regardless of selection direction.
  max(selection.anchor, selection.head)

proc empty*(selection: Selection): bool =
  ## Reports whether the selection is a caret without a selected range.
  selection.anchor == selection.head

proc lf(text: string): string =
  text.replace("\r\n", "\n")

proc newBuffer*(text = ""): Buffer =
  ## Creates a buffer; CRLF input is stored with LF and written back as CRLF.
  new(result)
  initLock(result.mu)
  result.crlf = "\r\n" in text
  result.document = ui.newTextBuffer(lf(text))
  result.saved = result.document.snapshot()

proc requireBuffer(buffer: Buffer) =
  if buffer == nil:
    raise newException(ValueError, "ui/editor: buffer cannot be nil")

proc snapshot*(buffer: Buffer): Snapshot =
  ## Returns a stable document version safe to read while the buffer changes.
  if buffer != nil:
    withLock buffer.mu:
      result.document = buffer.document.snapshot()
      result.crlf = buffer.crlf

proc version*(snapshot: Snapshot): uint64 = snapshot.document.version()
proc version*(buffer: Buffer): uint64 =
  if buffer != nil:
    withLock buffer.mu:
      result = buffer.document.version()

proc len*(snapshot: Snapshot): int = snapshot.document.byteLen()
proc len*(buffer: Buffer): int =
  if buffer != nil:
    withLock buffer.mu:
      result = buffer.document.byteLen()

proc lineCount*(snapshot: Snapshot): int = snapshot.document.lineCount()
proc lineCount*(buffer: Buffer): int =
  if buffer != nil:
    withLock buffer.mu:
      result = buffer.document.lineCount()
  else:
    result = 1

proc line*(snapshot: Snapshot; index: int): string =
  snapshot.document.line(index)
proc line*(buffer: Buffer; index: int): string =
  if buffer != nil: result = buffer.snapshot().line(index)

proc slice*(snapshot: Snapshot; start, pastLast: int): string =
  snapshot.document.byteSlice(start, pastLast)
proc slice*(buffer: Buffer; start, pastLast: int): string =
  if buffer != nil: result = buffer.snapshot().slice(start, pastLast)

proc `$`*(snapshot: Snapshot): string = $snapshot.document
proc `$`*(buffer: Buffer): string =
  if buffer != nil: result = $buffer.document

proc pos*(snapshot: Snapshot; byteOffset: int): Pos =
  let rune = snapshot.document.runeOffsetAtByte(byteOffset)
  result.line = snapshot.document.lineAt(rune)
  let lineStart = snapshot.document.lineRange(result.line).start
  result.column = snapshot.document.byteOffset(rune) -
    snapshot.document.byteOffset(lineStart)

proc pos*(buffer: Buffer; byteOffset: int): Pos =
  if buffer != nil: result = buffer.snapshot().pos(byteOffset)

proc offset*(snapshot: Snapshot; position: Pos): int =
  let line = max(0, min(position.line, snapshot.lineCount() - 1))
  let range = snapshot.document.lineRange(line)
  let startByte = snapshot.document.byteOffset(range.start)
  let lineBytes = snapshot.document.byteOffset(range.`end`) - startByte
  let target = startByte + max(0, min(position.column, lineBytes))
  let rune = snapshot.document.runeOffsetAtByte(target)
  snapshot.document.byteOffset(rune)

proc offset*(buffer: Buffer; position: Pos): int =
  if buffer != nil: result = buffer.snapshot().offset(position)

proc lineEnding*(snapshot: Snapshot): string =
  if snapshot.crlf: "\r\n" else: "\n"
proc lineEnding*(buffer: Buffer): string =
  if buffer != nil:
    withLock buffer.mu:
      result = if buffer.crlf: "\r\n" else: "\n"
  else:
    result = "\n"

proc setLineEnding*(buffer: Buffer; ending: string) =
  ## Selects the line ending written by `writeTo`; other values mean LF.
  buffer.requireBuffer()
  withLock buffer.mu:
    buffer.crlf = ending == "\r\n"

proc same*(a, b: Snapshot): bool =
  ## Reports whether snapshots share the same text root; line endings are
  ## excluded.
  a.document.same(b.document)

proc recordEdit(buffer: Buffer; before: ui.TextSnapshot) =
  let after = buffer.document.snapshot()
  if before.same(after):
    return
  if buffer.transactionDepth > 0:
    return
  buffer.undo.add(before)
  if buffer.undo.len > maxUndoSteps:
    buffer.undo = buffer.undo[(buffer.undo.len - maxUndoSteps) .. ^1]
  buffer.redo.setLen(0)

proc edit*(buffer: Buffer; edits: varargs[Edit]) =
  ## Applies byte-range edits from one source version as one undo step.
  ## Overlapping edits are trimmed to follow the preceding edit.
  buffer.requireBuffer()
  if edits.len == 0:
    return
  withLock buffer.mu:
    let before = buffer.document.snapshot()
    let sourceLength = before.byteLen()
    var ordered = newSeq[tuple[edit: Edit, order: int]](edits.len)
    for i, edit in edits:
      ordered[i] = (edit, i)
    ordered.sort(proc(a, b: tuple[edit: Edit, order: int]): int =
      result = cmp(a.edit.start, b.edit.start)
      if result == 0:
        result = cmp(a.order, b.order)
    )
    type EditRange = object
      first, pastLast: int
      text: string
    var ranges: seq[EditRange]
    var previousEnd = 0
    for entry in ordered:
      let edit = entry.edit
      let first = max(previousEnd,
        before.runeOffsetAtByte(max(0, min(edit.start, sourceLength))))
      let last = max(first,
        before.runeOffsetAtByte(max(0, min(edit.pastLast, sourceLength))))
      previousEnd = last
      ranges.add(EditRange(first: first, pastLast: last, text: lf(edit.text)))
    for i in countdown(ranges.high, 0):
      let edit = ranges[i]
      if edit.first == edit.pastLast and edit.text.len == 0:
        continue
      if before.slice(edit.first, edit.pastLast) == edit.text:
        continue
      buffer.document.replace(edit.first, edit.pastLast, edit.text)
    buffer.recordEdit(before)

proc set*(buffer: Buffer; text: string) =
  ## Replaces the document as one undoable edit, preserving its line ending.
  buffer.requireBuffer()
  buffer.edit(Edit(start: 0, pastLast: high(int), text: text))

proc reset*(buffer: Buffer; text: string) =
  ## Replaces the document and clears undo history, as when loading a file.
  buffer.requireBuffer()
  withLock buffer.mu:
    buffer.crlf = "\r\n" in text
    buffer.document.set(lf(text))
    buffer.saved = buffer.document.snapshot()
    buffer.undo.setLen(0)
    buffer.redo.setLen(0)
    if buffer.transactionDepth > 0:
      buffer.transactionBefore = buffer.saved

proc modified*(buffer: Buffer): bool =
  if buffer != nil:
    withLock buffer.mu:
      let current = buffer.document.snapshot()
      result = not current.same(buffer.saved) and $current != $buffer.saved

proc markSaved*(buffer: Buffer) =
  buffer.requireBuffer()
  withLock buffer.mu:
    buffer.saved = buffer.document.snapshot()

proc canUndo*(buffer: Buffer): bool =
  if buffer != nil:
    withLock buffer.mu:
      result = buffer.undo.len > 0
proc canRedo*(buffer: Buffer): bool =
  if buffer != nil:
    withLock buffer.mu:
      result = buffer.redo.len > 0

proc undo*(buffer: Buffer): bool =
  buffer.requireBuffer()
  withLock buffer.mu:
    if buffer.transactionDepth > 0 or buffer.undo.len == 0:
      return false
    let current = buffer.document.snapshot()
    let previous = buffer.undo.pop()
    buffer.redo.add(current)
    buffer.document.restore(previous)
    result = true

proc redo*(buffer: Buffer): bool =
  buffer.requireBuffer()
  withLock buffer.mu:
    if buffer.transactionDepth > 0 or buffer.redo.len == 0:
      return false
    let current = buffer.document.snapshot()
    let next = buffer.redo.pop()
    buffer.undo.add(current)
    buffer.document.restore(next)
    result = true

proc transact*(buffer: Buffer; body: proc() {.closure.}) =
  ## Groups edits made by `body` into one undo step; nesting is supported.
  buffer.requireBuffer()
  withLock buffer.mu:
    if buffer.transactionDepth == 0:
      buffer.transactionBefore = buffer.document.snapshot()
    inc buffer.transactionDepth
  try:
    if body != nil:
      body()
  finally:
    withLock buffer.mu:
      dec buffer.transactionDepth
      if buffer.transactionDepth == 0:
        let before = buffer.transactionBefore
        buffer.transactionBefore = default(ui.TextSnapshot)
        buffer.recordEdit(before)

proc normalizeOffset(snapshot: Snapshot; byteOffset: int): int =
  snapshot.document.byteOffset(
    snapshot.document.runeOffsetAtByte(byteOffset))

proc ensureState(state: State) =
  if state == nil:
    raise newException(ValueError, "ui/editor: state cannot be nil")
  if state.buffer == nil:
    state.buffer = newBuffer()
    state.caretSelection = Selection(anchor: 0, head: 0)
    state.selectionPending = false

proc newState*(text = ""): State =
  ## Creates editor state with a new buffer and the caret at its end.
  let buffer = newBuffer(text)
  let caret = buffer.len()
  State(buffer: buffer, caretSelection: Selection(anchor: caret, head: caret),
    fontFamily: "monospace", fontSize: 13'f32)

proc selection*(state: State): Selection =
  ## Returns the primary selection in UTF-8 byte offsets.
  if state != nil:
    result = state.caretSelection

proc selections*(state: State): seq[Selection] =
  ## Returns the editor's current selection. Multiple carets are not yet
  ## supported by the native view.
  if state != nil:
    result.add(state.caretSelection)

proc cursor*(state: State): int =
  ## Returns the byte offset of the primary caret.
  state.selection().head

proc cursorPos*(state: State): Pos =
  ## Returns the primary caret's line and UTF-8 byte column.
  if state != nil and state.buffer != nil:
    result = state.buffer.pos(state.cursor())

proc selectedText*(state: State): string =
  ## Returns the text in the primary selection.
  if state != nil and state.buffer != nil:
    let selection = state.caretSelection
    result = state.buffer.slice(selection.start(), selection.pastLast())

proc select*(state: State; start, pastLast: int) =
  ## Sets the primary selection using clamped UTF-8 byte offsets.
  state.ensureState()
  let snapshot = state.buffer.snapshot()
  state.caretSelection = Selection(
    anchor: snapshot.normalizeOffset(start),
    head: snapshot.normalizeOffset(pastLast))
  state.selectionPending = true

proc goTo*(state: State; position: Pos) =
  ## Places the caret at a clamped line and UTF-8 byte column.
  state.ensureState()
  let offset = state.buffer.snapshot().offset(position)
  state.caretSelection = Selection(anchor: offset, head: offset)
  state.selectionPending = true

proc insert*(state: State; text: string) =
  ## Replaces the primary selection with text and moves the caret after it.
  state.ensureState()
  let selection = state.caretSelection
  let start = selection.start()
  let inserted = lf(text)
  state.buffer.edit(Edit(start: start, pastLast: selection.pastLast(),
                         text: inserted))
  let snapshot = state.buffer.snapshot()
  let caret = snapshot.normalizeOffset(start + inserted.len)
  state.caretSelection = Selection(anchor: caret, head: caret)
  state.selectionPending = true

proc view*(c: ui.Context; state: State): ui.Element =
  ## Builds a native, editable code-editor surface over `state.buffer`.
  ## The caller chooses its size with `fill`, `grow`, or an explicit size.
  ## Text rendering and native editing use the UI's virtualized text area;
  ## line gutters, syntax styling, multi-caret input, and editor commands are
  ## added by later editor layers.
  state.ensureState()
  let snapshot = state.buffer.snapshot()
  result = c.textAreaBufferBase(state.buffer.document)
  let family = if state.fontFamily.len == 0: "monospace" else: state.fontFamily
  let size = if state.fontSize <= 0: 13'f32 else: state.fontSize
  discard result.textFamily(family).textSize(size)
    .readOnly(state.readOnly)
    .label(if state.label.len == 0: "Code editor" else: state.label)
  if state.selectionPending:
    let anchor = snapshot.document.runeOffsetAtByte(
      state.caretSelection.anchor)
    let head = snapshot.document.runeOffsetAtByte(state.caretSelection.head)
    discard result.setTextSelection(anchor, head)
    state.selectionPending = false
  let native = result.textAnchorCaret()
  let current = state.buffer.snapshot()
  state.caretSelection = Selection(
    anchor: current.document.byteOffset(native.anchor),
    head: current.document.byteOffset(native.caret))

type TextWriter* = ui.TextWriter

proc writeTo*(snapshot: Snapshot; writer: TextWriter): int64 =
  ## Writes the text in chunks using the snapshot's selected line ending.
  if writer == nil:
    return
  var written = 0'i64
  discard snapshot.document.writeTo(proc(chunk: string): int =
    let output = if snapshot.crlf: chunk.replace("\n", "\r\n") else: chunk
    var offset = 0
    while offset < output.len:
      let count = writer(output[offset .. ^1])
      if count <= 0 or count > output.len - offset:
        raise newException(IOError,
          "ui/editor: text writer returned an invalid count")
      offset += count
      written += int64(count)
    chunk.len
  )
  written

proc writeTo*(buffer: Buffer; writer: TextWriter): int64 =
  buffer.snapshot().writeTo(writer)
