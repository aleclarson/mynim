## Persistent text buffers and byte-based positions for native code editors.

import std/[algorithm, locks, strutils]
import mynim/ui as ui
import mynim/ui/editor/syntax as syntax

export syntax

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

  State* = ref object ## App-owned state for one native code-editor view.
    buffer*: Buffer ## The document edited by the view.
    readOnly*: bool ## Keeps text selectable while preventing edits.
    label*: string ## Accessible name; defaults to "Code editor".
    fontFamily*: string ## Text family; defaults to the system monospace family.
    fontSize*: float32 ## Text size in DIPs; defaults to 13.
    caretSelection: Selection
    selectionPending: bool
    syntaxBuffer: Buffer
    syntaxLanguage: syntax.Language
    syntaxVersion: uint64
    syntaxStates: seq[uint64]

  BufferUndoEntry = object
    before, after: ui.TextSnapshot
    owner: State
    beforeSelection, afterSelection: Selection
    hasSelection: bool
    firstChangedLine: int

  SyntaxChange = object
    version: uint64
    firstChangedLine: int

  Buffer* = ref object ## Thread-safe document text, save state, and undo history.
    mu: Lock
    document: ui.TextBuffer
    saved: ui.TextSnapshot
    undo, redo: seq[BufferUndoEntry]
    crlf: bool
    language: syntax.Language
    transactionDepth: int
    transactionBefore: ui.TextSnapshot
    transactionFirstChangedLine: int
    syntaxChanges: seq[SyntaxChange]

const
  maxUndoSteps = 10_000
  maxSyntaxChanges = 20_000

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

proc language*(buffer: Buffer): syntax.Language =
  ## Returns the language metadata associated with the buffer, if any.
  if buffer != nil:
    withLock buffer.mu:
      result = buffer.language

proc clearSyntaxCache(state: State; language: syntax.Language;
                      version: uint64) =
  state.syntaxBuffer = state.buffer
  state.syntaxLanguage = language
  state.syntaxVersion = version
  state.syntaxStates = @[0'u64]

proc syntaxChangesSince(buffer: Buffer; oldVersion, newVersion: uint64):
    tuple[complete: bool, firstChangedLine: int] =
  result.firstChangedLine = high(int)
  if buffer == nil:
    return
  withLock buffer.mu:
    if oldVersion == newVersion:
      result.complete = true
      return
    var expected = oldVersion + 1
    for change in buffer.syntaxChanges:
      if change.version <= oldVersion:
        continue
      if change.version > newVersion:
        break
      if change.version != expected:
        return
      result.firstChangedLine = min(result.firstChangedLine,
        change.firstChangedLine)
      inc expected
    result.complete = expected == newVersion + 1

proc cachedTokens(state: State; snapshot: Snapshot;
                  language: syntax.Language; line: int): seq[syntax.Token] =
  if language == nil or language.tokenizer == nil or line < 0 or
      line >= snapshot.lineCount():
    return
  if state.syntaxBuffer != state.buffer or
      state.syntaxLanguage != language:
    state.clearSyntaxCache(language, snapshot.version())
  elif state.syntaxVersion != snapshot.version():
    let changes = state.buffer.syntaxChangesSince(state.syntaxVersion,
      snapshot.version())
    if changes.complete:
      if changes.firstChangedLine != high(int):
        state.syntaxStates.setLen(min(state.syntaxStates.len,
          changes.firstChangedLine + 1))
    else:
      state.syntaxStates = @[0'u64]
    state.syntaxVersion = snapshot.version()
  var scratch: seq[syntax.Token]
  while state.syntaxStates.len <= line:
    let index = state.syntaxStates.len - 1
    let next = language.tokenizer(snapshot.line(index),
      state.syntaxStates[index], scratch)
    state.syntaxStates.add(next)
    scratch.setLen(0)
  let next = language.tokenizer(snapshot.line(line),
    state.syntaxStates[line], result)
  if line == state.syntaxStates.len - 1:
    state.syntaxStates.add(next)

proc syntaxColor(theme: ui.Theme; kind: syntax.TokenKind): ui.Color =
  case kind
  of syntax.tokenKeyword, syntax.tokenTag, syntax.tokenHeading,
      syntax.tokenLink, syntax.tokenMeta:
    result = theme.accent
  of syntax.tokenType, syntax.tokenNumber, syntax.tokenAttribute,
      syntax.tokenRegexp:
    result = theme.warning
  of syntax.tokenFunction, syntax.tokenConstant, syntax.tokenEscape,
      syntax.tokenEmphasis, syntax.tokenStrong:
    result = theme.accentHover
  of syntax.tokenString, syntax.tokenCode, syntax.tokenInserted:
    result = theme.success
  of syntax.tokenComment, syntax.tokenProperty, syntax.tokenOperator,
      syntax.tokenPunctuation:
    result = theme.textMuted
  of syntax.tokenDeleted, syntax.tokenInvalid:
    result = theme.danger
  of syntax.tokenText, syntax.tokenVariable:
    result = theme.text

proc syntaxSpans(state: State; snapshot: Snapshot;
                 language: syntax.Language; theme: ui.Theme;
                 line: int; text: string): seq[ui.Span] =
  let tokens = state.cachedTokens(snapshot, language, line)
  if tokens.len == 0:
    return
  var byteStart = 0
  for token in tokens:
    let pastLast = min(text.len, token.pastLast)
    if pastLast <= byteStart:
      continue
    result.add(ui.Span(text: text[byteStart ..< pastLast],
      color: theme.syntaxColor(token.kind)))
    byteStart = pastLast
  if byteStart < text.len:
    result.add(ui.Span(text: text[byteStart .. ^1], color: theme.text))

proc setLanguage*(buffer: Buffer; language: syntax.Language) =
  ## Associates language metadata with the buffer; nil means plain text.
  buffer.requireBuffer()
  withLock buffer.mu:
    buffer.language = language

proc same*(a, b: Snapshot): bool =
  ## Reports whether snapshots share the same text root; line endings are
  ## excluded.
  a.document.same(b.document)

proc recordSyntaxChange(buffer: Buffer; firstChangedLine: int) =
  if firstChangedLine == high(int):
    return
  let version = buffer.document.version()
  if buffer.syntaxChanges.len > 0 and
      buffer.syntaxChanges[^1].version == version:
    buffer.syntaxChanges[^1].firstChangedLine = min(
      buffer.syntaxChanges[^1].firstChangedLine, firstChangedLine)
  else:
    buffer.syntaxChanges.add(SyntaxChange(version: version,
      firstChangedLine: max(firstChangedLine, 0)))
  if buffer.transactionDepth > 0:
    buffer.transactionFirstChangedLine = min(
      buffer.transactionFirstChangedLine, firstChangedLine)
  if buffer.syntaxChanges.len > maxSyntaxChanges:
    buffer.syntaxChanges = buffer.syntaxChanges[(maxSyntaxChanges div 2) .. ^1]

proc recordHistory(buffer: Buffer; before, after: ui.TextSnapshot;
                   owner: State;
                   beforeSelection, afterSelection: Selection;
                   firstChangedLine: int; grouped = false) =
  if before.same(after):
    return
  if buffer.transactionDepth > 0:
    return
  if grouped and buffer.undo.len > 0 and
      buffer.undo[^1].owner == owner and buffer.undo[^1].after.same(before):
    buffer.undo[^1].after = after
    buffer.undo[^1].firstChangedLine = min(
      buffer.undo[^1].firstChangedLine, firstChangedLine)
    if owner != nil:
      buffer.undo[^1].afterSelection = afterSelection
  else:
    buffer.undo.add(BufferUndoEntry(before: before, after: after,
      owner: owner, beforeSelection: beforeSelection,
      afterSelection: afterSelection, hasSelection: owner != nil,
      firstChangedLine: firstChangedLine))
  if buffer.undo.len > maxUndoSteps:
    buffer.undo = buffer.undo[(buffer.undo.len - maxUndoSteps) .. ^1]
  buffer.redo.setLen(0)

proc recordEdit(buffer: Buffer; before: ui.TextSnapshot;
                firstChangedLine: int) =
  buffer.recordHistory(before, buffer.document.snapshot(), nil,
    default(Selection), default(Selection), firstChangedLine)

proc recordTextAreaEdit(buffer: Buffer; owner: State; edit: ui.TextAreaEdit) =
  if buffer == nil or owner == nil or owner.buffer != buffer:
    return
  let beforeSelection = Selection(
    anchor: edit.before.byteOffset(edit.before.runeOffset(edit.beforeAnchor)),
    head: edit.before.byteOffset(edit.before.runeOffset(edit.beforeCaret)))
  let afterSelection = Selection(
    anchor: edit.after.byteOffset(edit.after.runeOffset(edit.afterAnchor)),
    head: edit.after.byteOffset(edit.after.runeOffset(edit.afterCaret)))
  let firstChangedLine = edit.before.lineAt(edit.before.runeOffset(
    min(edit.beforeAnchor, edit.beforeCaret)))
  withLock buffer.mu:
    if not buffer.document.snapshot().same(edit.after):
      return
    buffer.recordSyntaxChange(firstChangedLine)
    buffer.recordHistory(edit.before, edit.after, owner, beforeSelection,
      afterSelection, firstChangedLine, edit.grouped)

proc setSelectionAfter(buffer: Buffer; owner: State; selection: Selection) =
  if buffer == nil or owner == nil or owner.buffer != buffer:
    return
  withLock buffer.mu:
    if buffer.undo.len > 0 and buffer.undo[^1].owner == owner and
        buffer.undo[^1].after.same(buffer.document.snapshot()):
      buffer.undo[^1].afterSelection = selection

proc setEditOwner(buffer: Buffer; owner: State; before, after: Snapshot;
                  beforeSelection, afterSelection: Selection) =
  if buffer == nil or owner == nil or owner.buffer != buffer or
      before.same(after):
    return
  withLock buffer.mu:
    if buffer.undo.len > 0 and buffer.undo[^1].after.same(after.document) and
        buffer.undo[^1].before.same(before.document):
      buffer.undo[^1].owner = owner
      buffer.undo[^1].beforeSelection = beforeSelection
      buffer.undo[^1].afterSelection = afterSelection
      buffer.undo[^1].hasSelection = true

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
    var firstChangedLine = high(int)
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
      let changedLine = before.lineAt(edit.first)
      firstChangedLine = min(firstChangedLine, changedLine)
      buffer.recordSyntaxChange(changedLine)
    buffer.recordEdit(before, firstChangedLine)

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
    buffer.recordSyntaxChange(0)
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
    let entry = buffer.undo.pop()
    buffer.redo.add(entry)
    buffer.document.restore(entry.before)
    buffer.recordSyntaxChange(entry.firstChangedLine)
    if entry.owner != nil and entry.owner.buffer == buffer and
        entry.hasSelection:
      entry.owner.caretSelection = entry.beforeSelection
      entry.owner.selectionPending = true
    result = true

proc redo*(buffer: Buffer): bool =
  buffer.requireBuffer()
  withLock buffer.mu:
    if buffer.transactionDepth > 0 or buffer.redo.len == 0:
      return false
    let entry = buffer.redo.pop()
    buffer.undo.add(entry)
    buffer.document.restore(entry.after)
    buffer.recordSyntaxChange(entry.firstChangedLine)
    if entry.owner != nil and entry.owner.buffer == buffer and
        entry.hasSelection:
      entry.owner.caretSelection = entry.afterSelection
      entry.owner.selectionPending = true
    result = true

proc transact*(buffer: Buffer; body: proc() {.closure.}) =
  ## Groups edits made by `body` into one undo step; nesting is supported.
  buffer.requireBuffer()
  withLock buffer.mu:
    if buffer.transactionDepth == 0:
      buffer.transactionBefore = buffer.document.snapshot()
      buffer.transactionFirstChangedLine = high(int)
    inc buffer.transactionDepth
  try:
    if body != nil:
      body()
  finally:
    withLock buffer.mu:
      dec buffer.transactionDepth
      if buffer.transactionDepth == 0:
        let before = buffer.transactionBefore
        let firstChangedLine = buffer.transactionFirstChangedLine
        buffer.transactionBefore = default(ui.TextSnapshot)
        buffer.transactionFirstChangedLine = high(int)
        buffer.recordEdit(before, firstChangedLine)

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
  state.buffer.setSelectionAfter(state, state.caretSelection)

proc goTo*(state: State; position: Pos) =
  ## Places the caret at a clamped line and UTF-8 byte column.
  state.ensureState()
  let offset = state.buffer.snapshot().offset(position)
  state.caretSelection = Selection(anchor: offset, head: offset)
  state.selectionPending = true
  state.buffer.setSelectionAfter(state, state.caretSelection)

proc insert*(state: State; text: string) =
  ## Replaces the primary selection with text and moves the caret after it.
  state.ensureState()
  let beforeSnapshot = state.buffer.snapshot()
  let selection = state.caretSelection
  let start = selection.start()
  let inserted = lf(text)
  state.buffer.edit(Edit(start: start, pastLast: selection.pastLast(),
                         text: inserted))
  let snapshot = state.buffer.snapshot()
  let caret = snapshot.normalizeOffset(start + inserted.len)
  state.caretSelection = Selection(anchor: caret, head: caret)
  state.selectionPending = true
  state.buffer.setEditOwner(state, beforeSnapshot, snapshot, selection,
    state.caretSelection)

proc undo*(state: State): bool =
  ## Undoes the buffer's latest editor or application edit.
  state.ensureState()
  result = state.buffer.undo()
  if result:
    let snapshot = state.buffer.snapshot()
    state.caretSelection = Selection(
      anchor: snapshot.normalizeOffset(state.caretSelection.anchor),
      head: snapshot.normalizeOffset(state.caretSelection.head))
    state.selectionPending = true

proc redo*(state: State): bool =
  ## Redoes the buffer's latest undone editor or application edit.
  state.ensureState()
  result = state.buffer.redo()
  if result:
    let snapshot = state.buffer.snapshot()
    state.caretSelection = Selection(
      anchor: snapshot.normalizeOffset(state.caretSelection.anchor),
      head: snapshot.normalizeOffset(state.caretSelection.head))
    state.selectionPending = true

proc view*(c: ui.Context; state: State): ui.Element =
  ## Builds a native, editable code-editor surface over `state.buffer`.
  ## The caller chooses its size with `fill`, `grow`, or an explicit size.
  ## Text rendering and native editing use the UI's virtualized text area;
  ## line gutters, multi-caret input, and editor commands are added by later
  ## editor layers.
  state.ensureState()
  let snapshot = state.buffer.snapshot()
  let language = state.buffer.language
  let theme = c.theme()
  let styleLine: ui.TextAreaStyler =
    if language == nil or language.tokenizer == nil: nil
    else:
      proc(line: int; text: string): seq[ui.Span] =
        state.syntaxSpans(snapshot, language, theme, line, text)
  result = if styleLine == nil:
      c.textAreaBufferBase(state.buffer.document)
    else:
      c.textAreaBufferStyledBase(state.buffer.document, styleLine)
  let family = if state.fontFamily.len == 0: "monospace" else: state.fontFamily
  let size = if state.fontSize <= 0: 13'f32 else: state.fontSize
  discard result.textFamily(family).textSize(size)
    .readOnly(state.readOnly)
    .label(if state.label.len == 0: "Code editor" else: state.label)
  let buffer = state.buffer
  let recordAreaEdit = proc(edit: ui.TextAreaEdit) =
    buffer.recordTextAreaEdit(state, edit)
  let undoArea = proc(): ui.TextAreaHistoryResult =
    result.changed = buffer.undo()
    if result.changed:
      let current = buffer.snapshot()
      result.anchor = current.document.utf16Offset(
        current.document.runeOffsetAtByte(state.caretSelection.anchor))
      result.caret = current.document.utf16Offset(
        current.document.runeOffsetAtByte(state.caretSelection.head))
      state.selectionPending = false
  let redoArea = proc(): ui.TextAreaHistoryResult =
    result.changed = buffer.redo()
    if result.changed:
      let current = buffer.snapshot()
      result.anchor = current.document.utf16Offset(
        current.document.runeOffsetAtByte(state.caretSelection.anchor))
      result.caret = current.document.utf16Offset(
        current.document.runeOffsetAtByte(state.caretSelection.head))
      state.selectionPending = false
  discard result.textAreaHistory(recordAreaEdit, undoArea, redoArea)
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
  state.buffer.setSelectionAfter(state, state.caretSelection)

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
