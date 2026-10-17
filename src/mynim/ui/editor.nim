## Persistent text buffers and byte-based positions for native code editors.

import std/[algorithm, locks, monotimes, strutils, times, unicode]
import mynim/internal/platform as platform
import mynim/internal/text as textStack
import mynim/ui as ui
import mynim/ui/editor/commands as editorCommands
import mynim/ui/editor/syntax as syntax
from mynim/internal/ucd import lookupGeneralCategory, Nd

export syntax

type
  Command* = editorCommands.Command ## A command that can be run by a binding.
  Binding* = editorCommands.Binding ## A key binding, optionally a chord.

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
    bindings*: seq[Binding] ## App bindings; matched before platform defaults.
    caretSelection: Selection
    selectionPending: bool
    pendingBinding: Binding
    chordPending, pendingBindingFromApp: bool
    chordStartedAt: MonoTime
    syntaxBuffer: Buffer
    syntaxLanguage: syntax.Language
    syntaxVersion: uint64
    syntaxStates: seq[uint64]
    syntaxFrontier: int ## Number of current line-start states validated.
    syntaxConfirmed: int ## Old states available to reuse after convergence.
    syntaxDirty: int ## Last changed line before which state cannot converge.

  BufferUndoEntry = object
    before, after: ui.TextSnapshot
    owner: State
    beforeSelection, afterSelection: Selection
    hasSelection: bool
    firstChangedLine: int

  SyntaxChange = object
    version: uint64
    firstChangedLine: int
    lastChangedLine: int
    lineDelta: int

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

proc commandName*(command: Command): string =
  ## Returns the stable keymap name for a command.
  editorCommands.commandName(command)

proc commandNamed*(name: string): tuple[command: Command, found: bool] =
  ## Finds a command by its stable keymap name.
  editorCommands.commandNamed(name)

proc defaultBindings*(): seq[Binding] =
  ## Returns the currently ported subset of platform editor shortcuts.
  editorCommands.defaultBindings()

const
  maxUndoSteps = 10_000
  maxSyntaxChanges = 20_000
  editorChordTimeout = initDuration(milliseconds = 1500)

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
  state.syntaxFrontier = 1
  state.syntaxConfirmed = 1
  state.syntaxDirty = -1

proc syntaxChangesSince(buffer: Buffer; oldVersion, newVersion: uint64):
    tuple[complete, lineStable: bool, firstChangedLine, lastChangedLine: int] =
  result.lineStable = true
  result.firstChangedLine = high(int)
  result.lastChangedLine = -1
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
      result.lastChangedLine = max(result.lastChangedLine,
        change.lastChangedLine)
      if change.lineDelta != 0:
        result.lineStable = false
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
    if changes.complete and changes.lineStable:
      if changes.firstChangedLine != high(int):
        state.syntaxDirty = max(state.syntaxDirty, changes.lastChangedLine)
        state.syntaxFrontier = min(state.syntaxFrontier,
          min(state.syntaxStates.len, changes.firstChangedLine + 1))
    else:
      state.syntaxStates = @[0'u64]
      state.syntaxFrontier = 1
      state.syntaxConfirmed = 1
      state.syntaxDirty = -1
    state.syntaxVersion = snapshot.version()
  var scratch: seq[syntax.Token]
  var tokenizedTarget = false
  while state.syntaxFrontier <= line + 1:
    let index = state.syntaxFrontier - 1
    let hasCachedEnd = index + 1 < state.syntaxStates.len
    let cachedEnd = if hasCachedEnd: state.syntaxStates[index + 1] else: 0'u64
    var next: uint64
    if index == line:
      next = language.tokenizer(snapshot.line(index),
        state.syntaxStates[index], result)
      tokenizedTarget = true
    else:
      scratch.setLen(0)
      next = language.tokenizer(snapshot.line(index),
        state.syntaxStates[index], scratch)
    if state.syntaxDirty >= 0 and index >= state.syntaxDirty and
        hasCachedEnd and state.syntaxConfirmed > index + 2 and
        cachedEnd == next:
      state.syntaxFrontier = state.syntaxConfirmed
      state.syntaxDirty = -1
      continue
    if hasCachedEnd:
      state.syntaxStates[index + 1] = next
    else:
      state.syntaxStates.add(next)
    state.syntaxFrontier = index + 2
    if state.syntaxDirty < 0:
      state.syntaxConfirmed = state.syntaxFrontier
    elif state.syntaxFrontier >= state.syntaxConfirmed:
      state.syntaxConfirmed = state.syntaxFrontier
      state.syntaxDirty = -1
  if not tokenizedTarget:
    discard language.tokenizer(snapshot.line(line),
      state.syntaxStates[line], result)

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

proc recordSyntaxChange(buffer: Buffer; firstChangedLine, lastChangedLine,
                        lineDelta: int) =
  if firstChangedLine == high(int):
    return
  let version = buffer.document.version()
  if buffer.syntaxChanges.len > 0 and
      buffer.syntaxChanges[^1].version == version:
    buffer.syntaxChanges[^1].firstChangedLine = min(
      buffer.syntaxChanges[^1].firstChangedLine, firstChangedLine)
    buffer.syntaxChanges[^1].lastChangedLine = max(
      buffer.syntaxChanges[^1].lastChangedLine, lastChangedLine)
    buffer.syntaxChanges[^1].lineDelta += lineDelta
  else:
    buffer.syntaxChanges.add(SyntaxChange(version: version,
      firstChangedLine: max(firstChangedLine, 0),
      lastChangedLine: max(lastChangedLine, firstChangedLine),
      lineDelta: lineDelta))
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
  let oldStartLine = edit.before.lineAt(edit.before.runeOffset(
    min(edit.beforeAnchor, edit.beforeCaret)))
  let oldEndLine = edit.before.lineAt(edit.before.runeOffset(
    max(edit.beforeAnchor, edit.beforeCaret)))
  let newStartLine = edit.after.lineAt(edit.after.runeOffset(
    min(edit.afterAnchor, edit.afterCaret)))
  let newEndLine = edit.after.lineAt(edit.after.runeOffset(
    max(edit.afterAnchor, edit.afterCaret)))
  let firstChangedLine = min(oldStartLine, newStartLine)
  let lastChangedLine = max(oldEndLine, newEndLine)
  withLock buffer.mu:
    if not buffer.document.snapshot().same(edit.after):
      return
    buffer.recordSyntaxChange(firstChangedLine, lastChangedLine,
      edit.after.lineCount() - edit.before.lineCount())
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
      let editBefore = buffer.document.snapshot()
      buffer.document.replace(edit.first, edit.pastLast, edit.text)
      let editAfter = buffer.document.snapshot()
      let changedLine = editBefore.lineAt(edit.first)
      let changedEndLine = editBefore.lineAt(edit.pastLast)
      firstChangedLine = min(firstChangedLine, changedLine)
      buffer.recordSyntaxChange(changedLine, changedEndLine,
        editAfter.lineCount() - editBefore.lineCount())
    buffer.recordEdit(before, firstChangedLine)

proc set*(buffer: Buffer; text: string) =
  ## Replaces the document as one undoable edit, preserving its line ending.
  buffer.requireBuffer()
  buffer.edit(Edit(start: 0, pastLast: high(int), text: text))

proc reset*(buffer: Buffer; text: string) =
  ## Replaces the document and clears undo history, as when loading a file.
  buffer.requireBuffer()
  withLock buffer.mu:
    let before = buffer.document.snapshot()
    buffer.crlf = "\r\n" in text
    buffer.document.set(lf(text))
    let after = buffer.document.snapshot()
    buffer.saved = buffer.document.snapshot()
    buffer.recordSyntaxChange(0, max(before.lineCount(), after.lineCount()) - 1,
      after.lineCount() - before.lineCount())
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
    let before = buffer.document.snapshot()
    buffer.document.restore(entry.before)
    let after = buffer.document.snapshot()
    buffer.recordSyntaxChange(entry.firstChangedLine,
      max(before.lineCount(), after.lineCount()) - 1,
      after.lineCount() - before.lineCount())
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
    let before = buffer.document.snapshot()
    buffer.document.restore(entry.after)
    let after = buffer.document.snapshot()
    buffer.recordSyntaxChange(entry.firstChangedLine,
      max(before.lineCount(), after.lineCount()) - 1,
      after.lineCount() - before.lineCount())
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

proc leadingIndent(text: string): string =
  var pastLast = 0
  while pastLast < text.len and text[pastLast] in {' ', '\t'}:
    inc pastLast
  text[0 ..< pastLast]

proc trailingSpaceStart(text: string): int =
  result = text.len
  while result > 0 and text[result - 1] in {' ', '\t'}:
    dec result

proc leadingSpaceEnd(text: string): int =
  while result < text.len and text[result] in {' ', '\t'}:
    inc result

proc startsAfterIndent(text, prefix: string): bool =
  let start = text.leadingSpaceEnd()
  prefix.len > 0 and start + prefix.len <= text.len and
    text[start ..< start + prefix.len] == prefix

proc tokenKindAt(state: State; snapshot: Snapshot;
                 language: syntax.Language; line, column: int):
    syntax.TokenKind =
  if language == nil or language.tokenizer == nil:
    return syntax.tokenText
  for token in state.cachedTokens(snapshot, language, line):
    if column < token.pastLast:
      return token.kind
  syntax.tokenText

proc indentationUnit(language: syntax.Language): string =
  if language != nil and language.hardTabs:
    return "\t"
  let width = if language == nil or language.tabSize <= 0: 4
    else: language.tabSize
  repeat(' ', width)

proc indentationColumn(text: string; tabSize: int): int =
  let width = max(tabSize, 1)
  for rune in text.runes:
    if ord(rune) == ord('\t'):
      result += width - result mod width
    else:
      inc result

proc tabIndentation(text: string; language: syntax.Language): string =
  if language != nil and language.hardTabs:
    return "\t"
  let width = if language == nil or language.tabSize <= 0: 4
    else: language.tabSize
  let column = text.indentationColumn(width)
  repeat(' ', width - column mod width)

proc outdentLength(line: string; tabSize: int): int =
  let indent = line.leadingIndent()
  if indent.startsWith("\t"):
    return 1
  var spaces = 0
  while spaces < indent.len and indent[spaces] == ' ':
    inc spaces
  if spaces > 0:
    let width = max(tabSize, 1)
    result = min(spaces, (spaces - 1) mod width + 1)

proc moveEditOffset(offset: int; biasLeft: bool; edits: seq[Edit]): int =
  var delta = 0
  for edit in edits:
    if offset < edit.start:
      break
    if edit.start == edit.pastLast:
      if offset == edit.start and biasLeft:
        return edit.start + delta
      delta += edit.text.len
    elif offset < edit.pastLast:
      return edit.start + delta + (if biasLeft: 0 else: edit.text.len)
    else:
      delta += edit.text.len - (edit.pastLast - edit.start)
  offset + delta

proc applyEditorEdits(state: State; before: Snapshot;
                      beforeSelection, afterSelection: Selection;
                      edits: seq[Edit]) =
  if edits.len == 0:
    return
  state.buffer.transact(proc() =
    for index in countdown(edits.high, 0):
      state.buffer.edit(edits[index])
  )
  let after = state.buffer.snapshot()
  let selection = Selection(
    anchor: after.normalizeOffset(afterSelection.anchor),
    head: after.normalizeOffset(afterSelection.head))
  state.caretSelection = selection
  state.selectionPending = true
  state.buffer.setEditOwner(state, before, after, beforeSelection, selection)
  state.buffer.setSelectionAfter(state, selection)

proc selectedLineSpan(snapshot: Snapshot; selection: Selection):
    tuple[first, last: int] =
  result.first = snapshot.pos(selection.start()).line
  result.last = snapshot.pos(selection.pastLast()).line
  if not selection.empty() and result.last > result.first and
      snapshot.pos(selection.pastLast()).column == 0:
    dec result.last
  result.last = max(result.first, result.last)

proc lineStart(snapshot: Snapshot; line: int): int =
  snapshot.offset(Pos(line: line, column: 0))

proc lineEnd(snapshot: Snapshot; line: int): int =
  snapshot.offset(Pos(line: line, column: snapshot.line(line).len))

proc moveSelectedLines(state: State; down: bool) =
  state.ensureState()
  if state.readOnly:
    return
  let snapshot = state.buffer.snapshot()
  let selection = state.caretSelection
  let span = snapshot.selectedLineSpan(selection)
  if (not down and span.first == 0) or
      (down and span.last + 1 >= snapshot.lineCount()):
    return

  let firstStart = snapshot.lineStart(span.first)
  let lastEnd = snapshot.lineEnd(span.last)
  let lineBlock = snapshot.slice(firstStart, lastEnd)
  var edit: Edit
  var shift: int
  if down:
    let nextLine = snapshot.line(span.last + 1)
    edit = Edit(start: firstStart,
      pastLast: snapshot.lineEnd(span.last + 1),
      text: nextLine & "\n" & lineBlock)
    shift = nextLine.len + 1
  else:
    let previousLine = snapshot.line(span.first - 1)
    edit = Edit(start: snapshot.lineStart(span.first - 1),
      pastLast: lastEnd, text: lineBlock & "\n" & previousLine)
    shift = -(previousLine.len + 1)
  let afterSelection = Selection(anchor: selection.anchor + shift,
    head: selection.head + shift)
  state.applyEditorEdits(snapshot, selection, afterSelection, @[edit])

proc duplicateSelectedLines(state: State; keepOriginal: bool) =
  state.ensureState()
  if state.readOnly:
    return
  let snapshot = state.buffer.snapshot()
  let selection = state.caretSelection
  let span = snapshot.selectedLineSpan(selection)
  let firstStart = snapshot.lineStart(span.first)
  let lastEnd = snapshot.lineEnd(span.last)
  let lineBlock = snapshot.slice(firstStart, lastEnd)
  let inserted = "\n" & lineBlock
  let edit = Edit(start: lastEnd, pastLast: lastEnd, text: inserted)
  let shift = if keepOriginal: 0 else: inserted.len
  let afterSelection = Selection(anchor: selection.anchor + shift,
    head: selection.head + shift)
  state.applyEditorEdits(snapshot, selection, afterSelection, @[edit])

proc deleteSelectedLines(state: State) =
  state.ensureState()
  if state.readOnly:
    return
  let snapshot = state.buffer.snapshot()
  let selection = state.caretSelection
  let span = snapshot.selectedLineSpan(selection)
  let deletesToEnd = span.last + 1 >= snapshot.lineCount()
  var edit = Edit(start: snapshot.lineStart(span.first),
    pastLast: if deletesToEnd: snapshot.len
      else: snapshot.lineStart(span.last + 1))
  if deletesToEnd and span.first > 0:
    edit.start = snapshot.lineEnd(span.first - 1)
  if edit.start == edit.pastLast:
    return

  let caretLine = snapshot.pos(selection.head).line
  let caretRune = snapshot.document.runeOffsetAtByte(selection.head)
  let caretLineStart = snapshot.lineStart(caretLine)
  let caretColumn = caretRune -
    snapshot.document.runeOffsetAtByte(caretLineStart)
  let replacementLine = if deletesToEnd:
      (if span.first > 0: span.first - 1 else: -1)
    else:
      span.last + 1
  var caret: int
  if replacementLine >= 0:
    let replacementStart = snapshot.lineStart(replacementLine)
    let replacementText = snapshot.line(replacementLine)
    let startRune = snapshot.document.runeOffsetAtByte(replacementStart)
    let endRune = snapshot.document.runeOffsetAtByte(
      replacementStart + replacementText.len)
    let column = min(caretColumn, endRune - startRune)
    let columnBytes = snapshot.document.byteOffset(startRune + column) -
      snapshot.document.byteOffset(startRune)
    let newLineStart = if deletesToEnd: replacementStart else: edit.start
    caret = newLineStart + columnBytes
  let afterSelection = Selection(anchor: caret, head: caret)
  state.applyEditorEdits(snapshot, selection, afterSelection, @[edit])

proc joinSelectedLines(state: State) =
  state.ensureState()
  if state.readOnly:
    return
  let snapshot = state.buffer.snapshot()
  let selection = state.caretSelection
  let span = snapshot.selectedLineSpan(selection)
  let lastLine = if span.first == span.last: span.last + 1 else: span.last
  if lastLine >= snapshot.lineCount():
    return

  type LineMapping = tuple[originalStart, leadingBytes, outputStart,
    keptBytes: int]
  var mappings = newSeq[LineMapping](lastLine - span.first + 1)
  let firstStart = snapshot.lineStart(span.first)
  let firstText = snapshot.line(span.first)
  mappings[0] = (firstStart, 0, 0, firstText.len)
  var joined = firstText
  var comment = ""
  let language = state.buffer.language
  if language != nil:
    comment = language.lineComment

  for lineIndex in span.first ..< lastLine:
    let current = snapshot.line(lineIndex)
    let next = snapshot.line(lineIndex + 1)
    let currentIndex = lineIndex - span.first
    let currentMap = mappings[currentIndex]
    let currentEnd = current.trailingSpaceStart()
    mappings[currentIndex].keptBytes = max(0,
      currentEnd - currentMap.leadingBytes)
    joined.setLen(currentMap.outputStart + mappings[currentIndex].keptBytes)

    var nextLeading = next.leadingSpaceEnd()
    if comment.len > 0 and
        current[0 ..< currentEnd].startsAfterIndent(comment) and
        next[nextLeading ..< next.len].startsWith(comment):
      nextLeading += comment.len
      nextLeading += next[nextLeading ..< next.len].leadingSpaceEnd()
    let rest = next[nextLeading ..< next.len]
    let trimmedCurrent = current[0 ..< currentEnd]
    let separator = if rest.len == 0 or rest.startsWith(")") or
        rest.startsWith("]") or trimmedCurrent.endsWith("(") or
        trimmedCurrent.endsWith("["): "" else: " "
    joined.add(separator)
    let nextIndex = currentIndex + 1
    mappings[nextIndex] = (snapshot.lineStart(lineIndex + 1), nextLeading,
      joined.len, next.len - nextLeading)
    joined.add(rest)

  let blockEnd = snapshot.lineEnd(lastLine)
  let oldText = snapshot.slice(firstStart, blockEnd)
  if joined == oldText:
    return
  let delta = joined.len - oldText.len
  let mapOffset = proc(offset: int): int =
    if offset < firstStart:
      return offset
    if offset > blockEnd:
      return offset + delta
    let lineIndex = snapshot.pos(offset).line
    if lineIndex < span.first or lineIndex > lastLine:
      return offset
    let mapping = mappings[lineIndex - span.first]
    let local = max(0, offset - mapping.originalStart -
      mapping.leadingBytes)
    firstStart + mapping.outputStart + min(local, mapping.keptBytes)
  let afterSelection = Selection(anchor: mapOffset(selection.anchor),
    head: mapOffset(selection.head))
  let edit = Edit(start: firstStart, pastLast: blockEnd, text: joined)
  state.applyEditorEdits(snapshot, selection, afterSelection, @[edit])

proc lineIncreasesIndent(state: State; snapshot: Snapshot; lineIndex: int;
                         line: string): bool =
  let language = state.buffer.language
  if language == nil:
    return
  let trimmedEnd = line.trailingSpaceStart()
  if trimmedEnd == 0:
    return
  for pair in language.brackets:
    if pair.open.len == 0 or pair.open == "<" or
        trimmedEnd < pair.open.len or
        line[trimmedEnd - pair.open.len ..< trimmedEnd] != pair.open:
      continue
    let column = trimmedEnd - pair.open.len
    if state.tokenKindAt(snapshot, language, lineIndex, column) notin
        {syntax.tokenString, syntax.tokenComment}:
      return true
  if language.name == "Python" and line[trimmedEnd - 1] == ':' and
      state.tokenKindAt(snapshot, language, lineIndex, trimmedEnd - 1) notin
        {syntax.tokenString, syntax.tokenComment}:
    return true

proc insertLineAround(state: State; above: bool) =
  state.ensureState()
  if state.readOnly:
    return
  let snapshot = state.buffer.snapshot()
  let selection = state.caretSelection
  let span = snapshot.selectedLineSpan(selection)
  let lineIndex = if above: span.first else: span.last
  let line = snapshot.line(lineIndex)
  var indent = line.leadingIndent()
  if not above and state.lineIncreasesIndent(snapshot, lineIndex, line):
    indent.add(state.buffer.language.indentationUnit())
  let at = if above: snapshot.lineStart(lineIndex)
    else: snapshot.lineEnd(lineIndex)
  let insertion = if above: indent & "\n" else: "\n" & indent
  let caret = at + (if above: indent.len else: insertion.len)
  let edit = Edit(start: at, pastLast: at, text: insertion)
  let afterSelection = Selection(anchor: caret, head: caret)
  state.applyEditorEdits(snapshot, selection, afterSelection, @[edit])

proc selectCurrentLines(state: State) =
  state.ensureState()
  let snapshot = state.buffer.snapshot()
  let selection = state.caretSelection
  let firstLine = snapshot.pos(selection.start()).line
  let lastLine = snapshot.pos(selection.pastLast()).line
  let start = snapshot.lineStart(firstLine)
  let pastLast = if lastLine + 1 >= snapshot.lineCount(): snapshot.len
    else: snapshot.lineStart(lastLine + 1)
  state.select(start, pastLast)

proc indentSelection(state: State; outdent: bool; wholeLine = false) =
  state.ensureState()
  if state.readOnly:
    return
  let snapshot = state.buffer.snapshot()
  let selection = state.caretSelection
  let firstPos = snapshot.pos(selection.start())
  let lastPos = snapshot.pos(selection.pastLast())
  if selection.empty() and not outdent and not wholeLine:
    let line = snapshot.line(firstPos.line)
    let prefix = line[0 ..< min(firstPos.column, line.len)]
    state.insert(prefix.tabIndentation(state.buffer.language))
    return

  let language = state.buffer.language
  let width = if language == nil or language.tabSize <= 0: 4
    else: language.tabSize
  var lastLine = lastPos.line
  if not selection.empty() and lastLine > firstPos.line and
      lastPos.column == 0:
    dec lastLine
  lastLine = max(firstPos.line, lastLine)
  var edits: seq[Edit]
  for lineIndex in firstPos.line .. lastLine:
    let line = snapshot.line(lineIndex)
    let lineStart = snapshot.offset(Pos(line: lineIndex, column: 0))
    if outdent:
      let count = line.outdentLength(width)
      if count > 0:
        edits.add(Edit(start: lineStart, pastLast: lineStart + count))
    elif firstPos.line == lastLine or line.strip().len > 0:
      edits.add(Edit(start: lineStart, pastLast: lineStart,
        text: language.indentationUnit()))

  if edits.len == 0:
    return
  var afterSelection: Selection
  if selection.empty():
    let caret = moveEditOffset(selection.head, false, edits)
    afterSelection = Selection(anchor: caret, head: caret)
  else:
    let move = proc(offset: int): int =
      let atStartOfSelection = offset == selection.start() and
        snapshot.pos(offset).column == 0
      moveEditOffset(offset, atStartOfSelection, edits)
    afterSelection = Selection(anchor: move(selection.anchor),
      head: move(selection.head))

  state.applyEditorEdits(snapshot, selection, afterSelection, edits)

proc toggleBlockComment(state: State) =
  let language = state.buffer.language
  if language == nil or language.blockComment[0].len == 0 or
      language.blockComment[1].len == 0:
    return
  let snapshot = state.buffer.snapshot()
  let selection = state.caretSelection
  var first = selection.start()
  var pastLast = selection.pastLast()
  if selection.empty():
    let position = snapshot.pos(first)
    let line = snapshot.line(position.line)
    let lineStart = snapshot.offset(Pos(line: position.line, column: 0))
    first = lineStart + line.leadingIndent().len
    pastLast = lineStart + line.len
  let text = snapshot.slice(first, pastLast)
  let open = language.blockComment[0]
  let close = language.blockComment[1]
  var edits: seq[Edit]
  var wraps = true
  if text.len >= open.len + close.len and text.startsWith(open) and
      text.endsWith(close):
    wraps = false
    var openLength = open.len
    var closeLength = close.len
    if text.len >= open.len + close.len + 2 and
        text[open.len] == ' ' and
        text[text.len - close.len - 1] == ' ':
      inc openLength
      inc closeLength
    edits.add(Edit(start: first, pastLast: first + openLength))
    edits.add(Edit(start: pastLast - closeLength, pastLast: pastLast))
  else:
    edits.add(Edit(start: first, pastLast: first, text: open & " "))
    edits.add(Edit(start: pastLast, pastLast: pastLast, text: " " & close))

  var afterSelection: Selection
  if selection.empty():
    let caret = moveEditOffset(selection.head, false, edits)
    afterSelection = Selection(anchor: caret, head: caret)
  else:
    let move = proc(offset: int): int =
      var biasLeft = false
      if wraps:
        biasLeft = offset == selection.start()
      moveEditOffset(offset, biasLeft, edits)
    afterSelection = Selection(anchor: move(selection.anchor),
      head: move(selection.head))
  state.applyEditorEdits(snapshot, selection, afterSelection, edits)

proc toggleComment(state: State) =
  state.ensureState()
  if state.readOnly:
    return
  let language = state.buffer.language
  if language == nil:
    return
  if language.lineComment.len == 0:
    state.toggleBlockComment()
    return

  let snapshot = state.buffer.snapshot()
  let selection = state.caretSelection
  let span = snapshot.selectedLineSpan(selection)
  let prefix = language.lineComment
  var minimumIndent = high(int)
  var allCommented = true
  for lineIndex in span.first .. span.last:
    let line = snapshot.line(lineIndex)
    let indent = line.leadingIndent().len
    if indent < line.len:
      minimumIndent = min(minimumIndent, indent)
      if not line[indent .. ^1].startsWith(prefix):
        allCommented = false
  if minimumIndent == high(int):
    minimumIndent = snapshot.line(span.first).leadingIndent().len

  var edits: seq[Edit]
  for lineIndex in span.first .. span.last:
    let line = snapshot.line(lineIndex)
    let indent = line.leadingIndent().len
    let body = if indent < line.len: line[indent .. ^1] else: ""
    let lineStart = snapshot.offset(Pos(line: lineIndex, column: 0))
    if allCommented:
      if body.len > 0:
        var remove = prefix.len
        if body.len > prefix.len and body[prefix.len] == ' ':
          inc remove
        let start = lineStart + indent
        edits.add(Edit(start: start, pastLast: start + remove))
    elif body.len > 0 or span.first == span.last:
      let start = lineStart + min(minimumIndent, line.len)
      edits.add(Edit(start: start, pastLast: start, text: prefix & " "))

  let afterSelection = Selection(
    anchor: moveEditOffset(selection.anchor, false, edits),
    head: moveEditOffset(selection.head, false, edits))
  state.applyEditorEdits(snapshot, selection, afterSelection, edits)

proc insertNewline(state: State) =
  ## Inserts a newline with the current indentation and basic syntax hints.
  state.ensureState()
  if state.readOnly:
    return
  let snapshot = state.buffer.snapshot()
  let selection = state.caretSelection
  let start = selection.start()
  let pastLast = selection.pastLast()
  let startPos = snapshot.pos(start)
  let line = snapshot.line(startPos.line)
  let column = max(0, min(startPos.column, line.len))
  let before = line[0 ..< column]
  let endPos = snapshot.pos(pastLast)
  let after = if endPos.line == startPos.line:
      line[max(column, min(endPos.column, line.len)) .. ^1]
    else:
      ""
  var indent = leadingIndent(line)
  if indent.len > before.len:
    indent = before
  let trimmedEnd = before.trailingSpaceStart()
  var nextIndent = indent
  var opensBlock = false
  let language = state.buffer.language
  if language != nil and trimmedEnd > 0:
    for pair in language.brackets:
      if pair.open.len == 0 or pair.open == "<" or
          trimmedEnd < pair.open.len or
          before[trimmedEnd - pair.open.len ..< trimmedEnd] != pair.open:
        continue
      let openColumn = trimmedEnd - pair.open.len
      if state.tokenKindAt(snapshot, language, startPos.line, openColumn) notin
          {syntax.tokenString, syntax.tokenComment}:
        opensBlock = true
        break
    if not opensBlock and language.name == "Python" and
        before[trimmedEnd - 1] == ':' and
        state.tokenKindAt(snapshot, language, startPos.line,
          trimmedEnd - 1) notin {syntax.tokenString, syntax.tokenComment}:
      opensBlock = true
  if opensBlock:
    nextIndent.add(language.indentationUnit())
  if language != nil and language.lineComment.len > 0:
    if before.startsAfterIndent(language.lineComment):
      nextIndent = indent & language.lineComment & " "

  var insertion = "\n" & nextIndent
  var caretInInsertion = insertion.len
  if selection.empty() and opensBlock:
    let afterStart = after.leadingSpaceEnd()
    for pair in language.brackets:
      if pair.open.len == 0 or pair.open == "<" or pair.close.len == 0 or
          trimmedEnd < pair.open.len or afterStart + pair.close.len > after.len or
          before[trimmedEnd - pair.open.len ..< trimmedEnd] != pair.open or
          after[afterStart ..< afterStart + pair.close.len] != pair.close:
        continue
      let openColumn = trimmedEnd - pair.open.len
      let closeColumn = column + afterStart
      if state.tokenKindAt(snapshot, language, startPos.line, openColumn) in
          {syntax.tokenString, syntax.tokenComment} or
          state.tokenKindAt(snapshot, language, startPos.line, closeColumn) in
          {syntax.tokenString, syntax.tokenComment}:
        continue
      insertion.add("\n" & indent)
      caretInInsertion = 1 + nextIndent.len
      break

  state.insert(insertion)
  let caret = state.buffer.snapshot().normalizeOffset(start + caretInInsertion)
  state.caretSelection = Selection(anchor: caret, head: caret)
  state.selectionPending = true
  state.buffer.setSelectionAfter(state, state.caretSelection)

proc graphemeMove(snapshot: Snapshot; runeOffset: int; direction: int): int =
  let document = snapshot.document
  let current = max(0, min(runeOffset, document.len()))
  let line = document.lineAt(current)
  let range = document.lineRange(line)
  if direction < 0:
    if current > range.start:
      var runes: seq[Rune]
      for rune in document.line(line).runes:
        runes.add(rune)
      var boundaries: textStack.Boundaries
      boundaries.reset(runes)
      return range.start + boundaries.prevGrapheme(current - range.start)
    if current > 0:
      return current - 1
  elif direction > 0:
    if current < range.`end`:
      var runes: seq[Rune]
      for rune in document.line(line).runes:
        runes.add(rune)
      var boundaries: textStack.Boundaries
      boundaries.reset(runes)
      return range.start + boundaries.nextGrapheme(current - range.start)
    if current < document.len():
      return current + 1
  current

proc wordCharClass(rune: Rune): int =
  if isAlpha(rune) or lookupGeneralCategory(int32(rune)) == Nd or
      rune == Rune('_'):
    return 1
  if rune.isWhiteSpace:
    return 0
  2

proc wordMove(snapshot: Snapshot; runeOffset: int; direction: int): int =
  let document = snapshot.document
  let current = max(0, min(runeOffset, document.len()))
  let line = document.lineAt(current)
  let range = document.lineRange(line)
  var runes: seq[Rune]
  for rune in document.line(line).runes:
    runes.add(rune)
  let local = current - range.start
  if direction < 0:
    if local == 0:
      if current > 0:
        return current - 1
      return current
    var target = local
    while target > 0 and runes[target - 1].isWhiteSpace:
      dec target
    if target > 0:
      let charClass = wordCharClass(runes[target - 1])
      dec target
      while target > 0 and wordCharClass(runes[target - 1]) == charClass:
        dec target
    if target != local:
      return range.start + target
    if current > 0:
      return current - 1
  elif direction > 0:
    if local < runes.len and runes[local] == Rune('\n'):
      return current + 1
    var target = local
    while target < runes.len and runes[target].isWhiteSpace:
      inc target
    if target < runes.len:
      let charClass = wordCharClass(runes[target])
      inc target
      while target < runes.len and runes[target] != Rune('\n') and
          wordCharClass(runes[target]) == charClass:
        inc target
    if target != local:
      return range.start + target
    if current < document.len():
      return current + 1
  current

proc smartHome(snapshot: Snapshot; runeOffset: int): int =
  let document = snapshot.document
  let current = max(0, min(runeOffset, document.len()))
  let line = document.lineAt(current)
  let range = document.lineRange(line)
  let firstNonIndent = range.start + document.line(line).leadingIndent().runeLen
  if current == firstNonIndent: range.start else: firstNonIndent

proc moveCaret(state: State; command: Command): bool =
  let snapshot = state.buffer.snapshot()
  let selection = state.caretSelection
  let selecting = command in {
    Command.selectLeft, Command.selectRight, Command.selectWordLeft,
    Command.selectWordRight, Command.selectLineStart, Command.selectLineEnd,
    Command.selectDocStart, Command.selectDocEnd}
  let movingLeft = command in {
    Command.moveLeft, Command.selectLeft, Command.moveWordLeft,
    Command.selectWordLeft, Command.moveLineStart, Command.selectLineStart,
    Command.moveDocStart, Command.selectDocStart}
  var targetByte = selection.head
  if not selecting and not selection.empty() and
      command in {Command.moveLeft, Command.moveRight}:
    targetByte = if movingLeft: selection.start() else: selection.pastLast()
  else:
    let currentRune = snapshot.document.runeOffsetAtByte(selection.head)
    var targetRune = currentRune
    case command
    of Command.moveLeft, Command.selectLeft:
      targetRune = snapshot.graphemeMove(currentRune, -1)
    of Command.moveRight, Command.selectRight:
      targetRune = snapshot.graphemeMove(currentRune, 1)
    of Command.moveWordLeft, Command.selectWordLeft:
      targetRune = snapshot.wordMove(currentRune, -1)
    of Command.moveWordRight, Command.selectWordRight:
      targetRune = snapshot.wordMove(currentRune, 1)
    of Command.moveLineStart, Command.selectLineStart:
      targetRune = snapshot.smartHome(currentRune)
    of Command.moveLineEnd, Command.selectLineEnd:
      targetRune = snapshot.document.lineRange(
        snapshot.document.lineAt(currentRune)).`end`
    of Command.moveDocStart, Command.selectDocStart:
      targetRune = 0
    of Command.moveDocEnd, Command.selectDocEnd:
      targetRune = snapshot.document.len()
    else:
      return false
    targetByte = snapshot.document.byteOffset(targetRune)
  let anchor = if selecting: selection.anchor else: targetByte
  if anchor == selection.anchor and targetByte == selection.head:
    return false
  state.select(anchor, targetByte)
  true

proc deleteByCommand(state: State; command: Command): bool =
  let snapshot = state.buffer.snapshot()
  let selection = state.caretSelection
  var firstRune: int
  var pastRune: int
  if selection.empty():
    let current = snapshot.document.runeOffsetAtByte(selection.head)
    firstRune = current
    pastRune = current
    case command
    of Command.backspace:
      firstRune = snapshot.graphemeMove(current, -1)
    of Command.delete:
      pastRune = snapshot.graphemeMove(current, 1)
    of Command.deleteWordLeft:
      firstRune = snapshot.wordMove(current, -1)
    of Command.deleteWordRight:
      pastRune = snapshot.wordMove(current, 1)
    of Command.deleteToLineStart:
      let range = snapshot.document.lineRange(snapshot.document.lineAt(current))
      firstRune = if current == range.start:
          snapshot.graphemeMove(current, -1)
        else: snapshot.smartHome(current)
    of Command.deleteToLineEnd:
      let range = snapshot.document.lineRange(snapshot.document.lineAt(current))
      pastRune = if current == range.`end`:
          snapshot.graphemeMove(current, 1)
        else: range.`end`
    else:
      return false
  else:
    firstRune = snapshot.document.runeOffsetAtByte(selection.start())
    pastRune = snapshot.document.runeOffsetAtByte(selection.pastLast())
  if firstRune == pastRune:
    return false
  let firstByte = snapshot.document.byteOffset(firstRune)
  let pastByte = snapshot.document.byteOffset(pastRune)
  state.select(firstByte, pastByte)
  state.insert("")
  true

proc transposeAtCaret(state: State): bool =
  let snapshot = state.buffer.snapshot()
  let selection = state.caretSelection
  if not selection.empty():
    return false
  var at = snapshot.document.runeOffsetAtByte(selection.head)
  let line = snapshot.document.lineAt(at)
  let range = snapshot.document.lineRange(line)
  if at == range.`end`:
    at = snapshot.graphemeMove(at, -1)
  let first = snapshot.graphemeMove(at, -1)
  let pastLast = snapshot.graphemeMove(at, 1)
  if first >= at or pastLast <= at or first < range.start:
    return false
  let firstByte = snapshot.document.byteOffset(first)
  let atByte = snapshot.document.byteOffset(at)
  let pastByte = snapshot.document.byteOffset(pastLast)
  let edit = Edit(start: firstByte, pastLast: pastByte,
    text: snapshot.slice(atByte, pastByte) & snapshot.slice(firstByte, atByte))
  let afterSelection = Selection(anchor: pastByte, head: pastByte)
  state.applyEditorEdits(snapshot, selection, afterSelection, @[edit])
  true

proc run*(state: State; command: Command): bool =
  ## Runs a supported editor command; unsupported commands return false.
  state.ensureState()
  if state.readOnly and command in {
      Command.undo, Command.redo, Command.backspace, Command.delete,
      Command.deleteWordLeft, Command.deleteWordRight,
      Command.deleteToLineStart, Command.deleteToLineEnd, Command.deleteLine,
      Command.newline, Command.newlineAbove, Command.newlineBelow,
      Command.moveLinesUp, Command.moveLinesDown,
      Command.duplicateLinesUp, Command.duplicateLinesDown,
      Command.duplicateSelection, Command.joinLines, Command.transpose,
      Command.indent, Command.outdent, Command.tab, Command.backtab,
      Command.toggleComment, Command.toggleBlockComment}:
    return false
  case command
  of Command.noCommand:
    return false
  of Command.undo:
    return state.undo()
  of Command.redo:
    return state.redo()
  of Command.moveLeft, Command.moveRight, Command.moveLineStart,
      Command.moveLineEnd, Command.moveDocStart, Command.moveDocEnd,
      Command.moveWordLeft, Command.moveWordRight,
      Command.selectLeft, Command.selectRight, Command.selectWordLeft,
      Command.selectWordRight, Command.selectLineStart, Command.selectLineEnd,
      Command.selectDocStart, Command.selectDocEnd:
    return state.moveCaret(command)
  of Command.backspace, Command.delete, Command.deleteWordLeft,
      Command.deleteWordRight, Command.deleteToLineStart,
      Command.deleteToLineEnd:
    return state.deleteByCommand(command)
  else:
    discard

  let beforeVersion = state.buffer.version()
  let beforeSelection = state.caretSelection
  case command
  of Command.deleteLine:
    state.deleteSelectedLines()
  of Command.duplicateSelection:
    if state.caretSelection.empty():
      state.duplicateSelectedLines(false)
    else:
      let snapshot = state.buffer.snapshot()
      let selection = state.caretSelection
      let start = selection.start()
      let pastLast = selection.pastLast()
      let selected = snapshot.slice(start, pastLast)
      let edit = Edit(start: start, pastLast: pastLast,
        text: selected & selected)
      let afterSelection = Selection(anchor: start,
        head: start + selected.len * 2)
      state.applyEditorEdits(snapshot, selection, afterSelection, @[edit])
  of Command.newline:
    state.insertNewline()
  of Command.newlineAbove:
    state.insertLineAround(true)
  of Command.newlineBelow:
    state.insertLineAround(false)
  of Command.moveLinesUp:
    state.moveSelectedLines(false)
  of Command.moveLinesDown:
    state.moveSelectedLines(true)
  of Command.duplicateLinesUp:
    state.duplicateSelectedLines(true)
  of Command.duplicateLinesDown:
    state.duplicateSelectedLines(false)
  of Command.joinLines:
    state.joinSelectedLines()
  of Command.indent:
    state.indentSelection(false, wholeLine = true)
  of Command.outdent:
    state.indentSelection(true, wholeLine = true)
  of Command.tab:
    state.indentSelection(false)
  of Command.backtab:
    state.indentSelection(true)
  of Command.toggleComment:
    state.toggleComment()
  of Command.toggleBlockComment:
    state.toggleBlockComment()
  of Command.selectLine:
    state.selectCurrentLines()
  of Command.selectAll:
    state.select(0, state.buffer.len())
  of Command.transpose:
    return state.transposeAtCaret()
  else:
    return false
  result = state.buffer.version() != beforeVersion or
    state.caretSelection != beforeSelection

proc findBinding(bindings: openArray[Binding]; mods: ui.Modifiers;
                 key: ui.Key): tuple[found: bool, binding: Binding] =
  for binding in bindings:
    if binding.mods == mods and binding.key == key:
      return (true, binding)

proc findChord(bindings: openArray[Binding]; prefix: Binding;
               mods: ui.Modifiers; key: ui.Key):
    tuple[found: bool, binding: Binding] =
  for binding in bindings:
    if binding.thenKey != ui.keyUnknown and binding.mods == prefix.mods and
        binding.key == prefix.key and binding.thenMods == mods and
        binding.thenKey == key:
      return (true, binding)

proc executeBinding(state: State; binding: Binding): bool =
  if binding.command == Command.noCommand:
    return true
  if state.readOnly and binding.command in {Command.tab, Command.backtab}:
    return false
  discard state.run(binding.command)
  true

proc handleBoundKey(state: State; key: ui.Key; mods: ui.Modifiers): bool =
  let now = getMonoTime()
  let defaults = defaultBindings()
  if state.chordPending:
    let prefix = state.pendingBinding
    let fromApp = state.pendingBindingFromApp
    state.chordPending = false
    if now - state.chordStartedAt <= editorChordTimeout:
      let chord = if fromApp:
          findChord(state.bindings, prefix, mods, key)
        else:
          findChord(defaults, prefix, mods, key)
      if chord.found:
        return state.executeBinding(chord.binding)

  var match = state.bindings.findBinding(mods, key)
  var fromApp = match.found
  if not match.found:
    match = defaults.findBinding(mods, key)
    fromApp = false
  if not match.found:
    return false
  if match.binding.thenKey != ui.keyUnknown:
    state.pendingBinding = match.binding
    state.pendingBindingFromApp = fromApp
    state.chordStartedAt = now
    state.chordPending = true
    return true
  state.executeBinding(match.binding)

proc view*(c: ui.Context; state: State): ui.Element =
  ## Builds a native, editable code-editor surface over `state.buffer`.
  ## The caller chooses its size with `fill`, `grow`, or an explicit size.
  ## Text rendering and native editing use the UI's virtualized text area;
  ## app bindings and implemented editor commands layer on top of it. Line
  ## gutters, multiple carets, and many commands remain to be ported.
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
  discard result.onTextKey(proc(key: ui.TextKey): bool =
    if state.handleBoundKey(key.key, key.mods):
      return true
    if key.key == platform.keyTab:
      return false
    if key.key != platform.keyEnter or
        (key.mods and not platform.modShift) != 0:
      return false
    if not state.readOnly:
      state.insertNewline()
    true
  )
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
