## Bound single-line text fields backed by the platform text-input client.

const maxTextUndoSteps = 200

type
  TextAreaUndoEntry = object
    before, after: TextSnapshot
    beforeAnchor, beforeCaret, afterAnchor, afterCaret: int

  TextFieldUndoEntry = object
    before, after: string
    beforeAnchor, beforeCaret, afterAnchor, afterCaret: int

type
  TextKey* = object ## Callback-scoped input key; text access expires on return.
    key*: platform.Key ## The key pressed.
    mods*: platform.Modifiers ## The modifiers held with the key.
    client: TextFieldClient
    sequence: uint64

  TextFieldClient = ref object of platform.TextInputClient
    text, lastBoundValue, placeholder: string
    onPaste: proc(text: string): bool {.closure.}
    onTextKey: proc(key: TextKey): bool {.closure.}
    textKeySequence: uint64
    textKeyActive, textKeyPending, textKeySet: bool
    textKeyPendingValue: string
    boundBuffer: TextBuffer
    bufferSnapshot: TextSnapshot
    anchor, caret: int
    mark: platform.TextRange
    hasMark, nativeChanged, readOnly, password, rightToLeft: bool
    insetX, insetY: float32
    placeholderColor: Color
    style: textStack.Style
    shaped: textStack.Layout
    multiline, areaInitialized: bool
    areaStringBound, areaStringChanged: bool
    areaStringValue: string
    areaScroll: ScrollState
    areaHeights: ParagraphHeightIndex
    areaLineHeights: seq[float32]
    areaLayouts: Table[int, textStack.Layout]
    areaCompositionBuffer: TextBuffer
    areaCompositionBase: TextSnapshot
    areaCompositionStart: int
    areaCompositionText: string
    areaCompositionActive: bool
    areaCommittedMark: platform.TextRange
    areaHasCommittedMark: bool
    areaUndo, areaRedo: seq[TextAreaUndoEntry]
    areaUndoGroupOpen: bool
    textUndo, textRedo: seq[TextFieldUndoEntry]
    textUndoGroupOpen: bool
    areaFirst, areaPastLast: int
    areaWidth, areaHeight, areaLineHeight: float32
    areaHasLayout, areaHasDesiredX: bool
    areaDesiredX: float32
    areaLastStyle: textStack.Style
    areaLastRightToLeft: bool

proc runeIndexAtUtf16(value: string; offset: int): int =
  let byteOffset = platform.utf16ByteOffset(value, max(offset, 0))
  for _ in value[0 ..< byteOffset].runes:
    inc result

proc utf16UnitAtRune(value: string; index: int): int =
  var remaining = max(index, 0)
  for rune in value.runes:
    if remaining == 0:
      break
    result += (if ord(rune) < 0x10000: 1 else: 2)
    dec remaining

proc fieldRange(client: TextFieldClient): platform.TextRange =
  platform.TextRange(start: min(client.anchor, client.caret),
                     `end`: max(client.anchor, client.caret))

proc fieldSelection(client: TextFieldClient): platform.TextSelection =
  platform.TextSelection(`range`: client.fieldRange(),
                         reversed: client.anchor > client.caret)

proc setFieldText(client: TextFieldClient; value: string) =
  client.text = value
  client.lastBoundValue = value
  client.caret = platform.utf16Len(value)
  client.anchor = client.caret
  client.hasMark = false
  client.nativeChanged = false

proc rebuildFieldLayout(client: TextFieldClient) =
  let display = if client.password:
      repeat("•", client.text.runeLen)
    else:
      client.text
  client.shaped = textStack.shared().layout(textStack.Params(
    text: display, style: client.style, noWrap: true,
    keepSpaces: true, rtl: client.rightToLeft))

proc fieldDisplayText(client: TextFieldClient): string =
  if client.text.len == 0:
    return client.placeholder
  if client.password:
    return repeat("•", client.text.runeLen)
  client.text

proc clearTextFieldHistory(client: TextFieldClient) =
  client.textUndo.setLen(0)
  client.textRedo.setLen(0)
  client.textUndoGroupOpen = false

proc rebaseTextFieldHistory(client: TextFieldClient; text: string;
                            anchor, caret: int) =
  if client.textUndo.len > 0:
    var entry = client.textUndo[^1]
    entry.after = text
    entry.afterAnchor = anchor
    entry.afterCaret = caret
    client.textUndo[^1] = entry
  client.textRedo.setLen(0)

proc recordTextFieldEdit(client: TextFieldClient; before, after: string;
                         range: platform.TextRange; inserted: string;
                         beforeAnchor, beforeCaret: int;
                         mergeComposition = false) =
  if mergeComposition and client.textUndo.len > 0:
    var entry = client.textUndo[^1]
    entry.after = after
    entry.afterAnchor = client.anchor
    entry.afterCaret = client.caret
    client.textUndo[^1] = entry
    client.textRedo.setLen(0)
    client.textUndoGroupOpen = false
    return
  if before == after:
    return
  let groupable = inserted.len > 0 and range.start == range.`end` and
    client.anchor == client.caret
  let join = groupable and client.textUndoGroupOpen and
    client.textUndo.len > 0 and beforeAnchor == beforeCaret and
    client.textUndo[^1].after == before and
    client.textUndo[^1].afterAnchor == beforeAnchor and
    client.textUndo[^1].afterCaret == beforeCaret
  if join:
    var entry = client.textUndo[^1]
    entry.after = after
    entry.afterAnchor = client.anchor
    entry.afterCaret = client.caret
    client.textUndo[^1] = entry
  else:
    client.textUndo.add(TextFieldUndoEntry(before: before, after: after,
      beforeAnchor: beforeAnchor, beforeCaret: beforeCaret,
      afterAnchor: client.anchor, afterCaret: client.caret))
  if client.textUndo.len > maxTextUndoSteps:
    client.textUndo.delete(0)
  client.textRedo.setLen(0)
  client.textUndoGroupOpen = groupable

proc restoreTextFieldHistory(client: TextFieldClient; text: string;
                             anchor, caret: int) =
  client.text = text
  let limit = platform.utf16Len(client.text)
  client.anchor = max(0, min(anchor, limit))
  client.caret = max(0, min(caret, limit))
  client.hasMark = false
  client.nativeChanged = true
  client.textUndoGroupOpen = false
  client.rebuildFieldLayout()

proc undoTextField(client: TextFieldClient): bool =
  if client.textUndo.len == 0:
    return false
  let entry = client.textUndo[^1]
  client.textUndo.setLen(client.textUndo.len - 1)
  client.textRedo.add(entry)
  client.restoreTextFieldHistory(entry.before, entry.beforeAnchor,
                                 entry.beforeCaret)
  result = true

proc redoTextField(client: TextFieldClient): bool =
  if client.textRedo.len == 0:
    return false
  let entry = client.textRedo[^1]
  client.textRedo.setLen(client.textRedo.len - 1)
  client.textUndo.add(entry)
  client.restoreTextFieldHistory(entry.after, entry.afterAnchor,
                                 entry.afterCaret)
  result = true

proc resetAreaCache(client: TextFieldClient; lineCount: int) =
  client.areaLineHeights = newSeq[float32](max(lineCount, 0))
  client.areaHeights.reset(client.areaLineHeights)
  if client.areaLineHeight > 0:
    client.areaHeights.setEstimate(float64(client.areaLineHeight))
  client.areaLayouts.clear()

proc rebaseAreaUndo(client: TextFieldClient; snapshot: TextSnapshot;
                    anchor, caret: int) =
  if client.areaUndoGroupOpen and client.areaUndo.len > 0:
    var entry = client.areaUndo[^1]
    entry.after = snapshot
    entry.afterAnchor = anchor
    entry.afterCaret = caret
    client.areaUndo[^1] = entry
  client.areaRedo.setLen(0)

proc recordAreaEdit(client: TextFieldClient; before, after: TextSnapshot;
                    range: platform.TextRange; inserted: string;
                    beforeAnchor, beforeCaret: int;
                    mergeComposition = false) =
  if mergeComposition and client.areaUndo.len > 0:
    var entry = client.areaUndo[^1]
    entry.after = after
    entry.afterAnchor = client.anchor
    entry.afterCaret = client.caret
    client.areaUndo[^1] = entry
    client.areaRedo.setLen(0)
    client.areaUndoGroupOpen = false
    return
  let groupable = inserted.len > 0 and client.anchor == client.caret
  let join = groupable and client.areaUndoGroupOpen and
    client.areaUndo.len > 0 and beforeAnchor == beforeCaret and
    client.areaUndo[^1].afterAnchor == beforeAnchor and
    client.areaUndo[^1].afterCaret == beforeCaret and
    range.start == range.`end`
  if join:
    var entry = client.areaUndo[^1]
    entry.after = after
    entry.afterAnchor = client.anchor
    entry.afterCaret = client.caret
    client.areaUndo[^1] = entry
  else:
    client.areaUndo.add(TextAreaUndoEntry(before: before, after: after,
      beforeAnchor: beforeAnchor, beforeCaret: beforeCaret,
      afterAnchor: client.anchor, afterCaret: client.caret))
  if client.areaUndo.len > maxTextUndoSteps:
    client.areaUndo.delete(0)
  client.areaRedo.setLen(0)
  client.areaUndoGroupOpen = groupable

proc revealAreaCaret(client: TextFieldClient)

proc clearAreaComposition(client: TextFieldClient; restoreBase: bool;
                          keepTransaction = false) =
  if client.areaCompositionBuffer != nil:
    if restoreBase:
      client.bufferSnapshot = client.areaCompositionBase
    client.areaCompositionBuffer = nil
    client.areaCompositionBase = TextSnapshot()
    client.areaCompositionStart = 0
    client.areaCompositionText.setLen(0)
  client.hasMark = false
  client.mark = platform.TextRange()
  if not keepTransaction:
    client.areaCompositionActive = false
    client.areaCommittedMark = platform.TextRange()
    client.areaHasCommittedMark = false
  client.areaHasDesiredX = false
  client.resetAreaCache(client.bufferSnapshot.lineCount())
  if client.areaLineHeight > 0:
    client.areaHeights.setEstimate(float64(client.areaLineHeight))

proc restoreAreaHistory(client: TextFieldClient; snapshot: TextSnapshot;
                        anchor, caret: int) =
  client.boundBuffer.restore(snapshot)
  client.bufferSnapshot = client.boundBuffer.snapshot()
  client.areaInitialized = true
  client.text.setLen(0)
  client.lastBoundValue.setLen(0)
  client.hasMark = false
  client.nativeChanged = false
  let limit = client.bufferSnapshot.utf16Len()
  client.anchor = max(0, min(anchor, limit))
  client.caret = max(0, min(caret, limit))
  client.areaStringChanged = client.areaStringBound
  client.areaHasDesiredX = false
  client.areaUndoGroupOpen = false
  client.areaCompositionBuffer = nil
  client.areaCompositionBase = TextSnapshot()
  client.areaCompositionStart = 0
  client.areaCompositionText.setLen(0)
  client.areaCompositionActive = false
  client.areaCommittedMark = platform.TextRange()
  client.areaHasCommittedMark = false
  client.resetAreaCache(client.bufferSnapshot.lineCount())
  client.revealAreaCaret()

proc undoTextArea(client: TextFieldClient): bool =
  if client.areaUndo.len == 0:
    return false
  let entry = client.areaUndo[^1]
  client.areaUndo.setLen(client.areaUndo.len - 1)
  client.areaRedo.add(entry)
  client.restoreAreaHistory(entry.before, entry.beforeAnchor,
                            entry.beforeCaret)
  result = true

proc redoTextArea(client: TextFieldClient): bool =
  if client.areaRedo.len == 0:
    return false
  let entry = client.areaRedo[^1]
  client.areaRedo.setLen(client.areaRedo.len - 1)
  client.areaUndo.add(entry)
  client.restoreAreaHistory(entry.after, entry.afterAnchor, entry.afterCaret)
  result = true

proc syncTextAreaBuffer(client: TextFieldClient): bool =
  if not client.multiline or client.boundBuffer == nil:
    return false
  let snapshot = client.boundBuffer.snapshot()
  let expectedVersion = if client.areaCompositionBuffer != nil:
      client.areaCompositionBase.version()
    else:
      client.bufferSnapshot.version()
  if client.areaInitialized and
      snapshot.version() == expectedVersion:
    return false
  let initial = not client.areaInitialized
  client.clearAreaComposition(restoreBase = false)
  client.bufferSnapshot = snapshot
  client.text.setLen(0)
  client.lastBoundValue.setLen(0)
  client.hasMark = false
  client.nativeChanged = false
  if initial:
    client.caret = snapshot.utf16Len()
    client.anchor = client.caret
  else:
    client.caret = min(client.caret, snapshot.utf16Len())
    client.anchor = min(client.anchor, snapshot.utf16Len())
    client.rebaseAreaUndo(snapshot, client.anchor, client.caret)
  client.areaInitialized = true
  client.resetAreaCache(snapshot.lineCount())
  result = true

proc fieldRuneLen(client: TextFieldClient): int =
  if client.multiline:
    discard client.syncTextAreaBuffer()
    client.bufferSnapshot.len()
  else:
    client.text.runeLen

proc fieldUtf16Len(client: TextFieldClient): int =
  if client.multiline:
    discard client.syncTextAreaBuffer()
    client.bufferSnapshot.utf16Len()
  else:
    platform.utf16Len(client.text)

proc fieldRuneIndex(client: TextFieldClient; unit: int): int =
  if client.multiline:
    discard client.syncTextAreaBuffer()
    client.bufferSnapshot.runeOffset(unit)
  else:
    runeIndexAtUtf16(client.text, unit)

proc fieldUtf16Offset(client: TextFieldClient; rune: int): int =
  if client.multiline:
    discard client.syncTextAreaBuffer()
    client.bufferSnapshot.utf16Offset(rune)
  else:
    utf16UnitAtRune(client.text, rune)

proc fieldWordBoundary(client: TextFieldClient; rune: int;
                       forward: bool): int =
  if client.multiline:
    discard client.syncTextAreaBuffer()
    if forward:
      return client.bufferSnapshot.nextWordRune(rune)
    return client.bufferSnapshot.prevWordRune(rune)
  if forward:
    client.text.nextWordRune(rune)
  else:
    client.text.prevWordRune(rune)

proc areaParagraphLayout(client: TextFieldClient; paragraph: int):
    textStack.Layout

proc fieldCaretRightToLeft(client: TextFieldClient; rune: int): bool =
  if client.multiline:
    discard client.syncTextAreaBuffer()
    let paragraph = client.bufferSnapshot.lineAt(rune)
    let layout = client.areaParagraphLayout(paragraph)
    if layout.lines.len > 0:
      return layout.lines[0].rtl
  elif client.shaped != nil and client.shaped.lines.len > 0:
    return client.shaped.lines[0].rtl
  client.rightToLeft

proc setAreaParagraphHeight(client: TextFieldClient; paragraph: int;
                            height: float32): bool =
  if paragraph < 0 or paragraph >= client.areaLineHeights.len:
    return false
  let height = max(height, client.areaLineHeight)
  let old = client.areaLineHeights[paragraph]
  if abs(old - height) < 0.5'f32:
    return false
  if old <= 0:
    client.areaHeights.add(paragraph, float64(height), -1)
  else:
    client.areaHeights.add(paragraph, float64(height - old), 0)
  client.areaLineHeights[paragraph] = height
  result = true

proc areaParagraphLayout(client: TextFieldClient; paragraph: int):
    textStack.Layout =
  discard client.syncTextAreaBuffer()
  if paragraph < 0 or paragraph >= client.bufferSnapshot.lineCount():
    return
  if client.areaLayouts.hasKey(paragraph):
    return client.areaLayouts[paragraph]
  let text = client.bufferSnapshot.line(paragraph)
  let params = textStack.Params(text: text, style: client.style,
    width: max(client.areaWidth, 1'f32), keepSpaces: true,
    rtl: client.rightToLeft)
  result = textStack.shared().layout(params)
  client.areaLayouts[paragraph] = result
  let height = max(result.height, client.areaLineHeight)
  discard client.setAreaParagraphHeight(paragraph, height)

proc revealAreaCaret(client: TextFieldClient) =
  if not client.multiline or client.areaScroll == nil or
      client.areaHeight <= 0:
    return
  discard client.syncTextAreaBuffer()
  let rune = client.bufferSnapshot.runeOffset(client.caret)
  let paragraph = client.bufferSnapshot.lineAt(rune)
  let lineRange = client.bufferSnapshot.lineRange(paragraph)
  let layout = client.areaParagraphLayout(paragraph)
  let (_, y, height) = layout.caret(rune - lineRange.start)
  let top = float32(client.areaHeights.top(paragraph)) + y
  let bottom = top + max(height, client.areaLineHeight)
  let viewTop = client.areaScroll.offsetY
  if top < viewTop:
    client.areaScroll.offsetY = max(top, 0'f32)
  elif bottom > viewTop + client.areaHeight:
    client.areaScroll.offsetY = max(bottom - client.areaHeight, 0'f32)

proc areaContentHeight(client: TextFieldClient): float32 =
  float32(max(client.areaHeights.top(client.areaLineHeights.len), 0.0))

proc prepareAreaWindow(client: TextFieldClient; viewportHeight: float32) =
  let count = client.bufferSnapshot.lineCount()
  if count == 0:
    client.areaFirst = 0
    client.areaPastLast = 0
    return
  let overscan = max(client.areaLineHeight * 2, 1'f32)
  let scroll = if client.areaScroll == nil: 0'f32
    else: client.areaScroll.offsetY
  let firstY = max(float64(scroll - overscan), 0.0)
  let lastY = float64(scroll + max(viewportHeight, client.areaLineHeight) + overscan)
  let first = client.areaHeights.at(firstY)
  var pastLast = first
  while pastLast < count and client.areaHeights.top(pastLast) < lastY:
    inc pastLast
  if pastLast <= first:
    pastLast = min(first + 1, count)
  client.areaFirst = first
  client.areaPastLast = pastLast

proc captureAreaLayout(client: TextFieldClient; owner: ElementOwner;
                       rects: seq[Rect]; parentSlot: int): bool =
  if owner == nil or parentSlot <= 0 or parentSlot >= owner.nodes.len or
      rects.len != owner.nodes.len:
    return false
  let parent = owner.nodes[parentSlot]
  let box = rects[parentSlot]
  let width = max(box.w - parent.contentInsetX, 1'f32)
  let height = max(box.h - parent.contentInsetY, 0'f32)
  let oldContentHeight = client.areaContentHeight()
  let newLayout = not client.areaHasLayout or
    abs(width - client.areaWidth) >= 0.5'f32 or
    client.areaLastStyle != client.style or
    client.areaLastRightToLeft != client.rightToLeft
  if newLayout:
    client.areaWidth = width
    client.areaLastStyle = client.style
    client.areaLastRightToLeft = client.rightToLeft
    let line = textStack.shared().layout(textStack.Params(text: " ",
      style: client.style, width: width, keepSpaces: true,
      rtl: client.rightToLeft))
    client.areaLineHeight = max(line.height, max(client.style.size, 1'f32))
    client.resetAreaCache(client.bufferSnapshot.lineCount())
    client.areaHeights.setEstimate(float64(client.areaLineHeight))
    client.areaHasLayout = true
    result = true
  if abs(height - client.areaHeight) >= 0.5'f32:
    client.areaHeight = height
    result = true
  for slot in 1..<owner.nodes.len:
    let row = owner.nodes[slot]
    if row.textAreaOwner != client or row.textAreaLine < 0 or
        row.textAreaLine >= client.areaLineHeights.len:
      continue
    if row.shapedText != nil:
      result = client.setAreaParagraphHeight(row.textAreaLine,
        row.shapedText.height) or result
      client.areaLayouts[row.textAreaLine] = row.shapedText
  let totals = client.areaHeights.totals()
  let measured = client.areaLineHeights.len - totals.unknown
  if measured > 0:
    client.areaHeights.setEstimate(totals.measured / float64(measured))
  var expired: seq[int]
  for paragraph in client.areaLayouts.keys:
    if paragraph < client.areaFirst - 128 or
        paragraph >= client.areaPastLast + 128:
      expired.add(paragraph)
  for paragraph in expired:
    client.areaLayouts.del(paragraph)
  result = result or abs(client.areaContentHeight() - oldContentHeight) >= 0.5'f32

proc invalidateAreaEdit(client: TextFieldClient; before: TextSnapshot;
                        after: TextSnapshot; replaced: platform.TextRange;
                        inserted: string) =
  let startRune = before.runeOffset(replaced.start)
  let endRune = before.runeOffset(replaced.`end`)
  let firstLine = before.lineAt(startRune)
  let lastLine = before.lineAt(endRune)
  client.bufferSnapshot = after
  if before.lineCount() != after.lineCount():
    client.resetAreaCache(after.lineCount())
    return
  let insertedRunes = inserted.runeLen
  let afterLine = after.lineAt(startRune + insertedRunes)
  let last = min(client.areaLineHeights.len - 1,
    max(lastLine, afterLine))
  for paragraph in firstLine..last:
    client.areaLineHeights[paragraph] = 0
    client.areaLayouts.del(paragraph)
  client.areaHeights.reset(client.areaLineHeights)
  if client.areaLineHeight > 0:
    client.areaHeights.setEstimate(float64(client.areaLineHeight))
  client.areaHasDesiredX = false

proc replaceAreaText(client: TextFieldClient; range: platform.TextRange;
                     value: string; mergeComposition = false): bool =
  discard client.syncTextAreaBuffer()
  let before = client.bufferSnapshot
  let beforeAnchor = client.anchor
  let beforeCaret = client.caret
  let edit = client.boundBuffer.replaceUtf16IfCurrent(before, range, value)
  if not edit.committed:
    discard client.syncTextAreaBuffer()
    return
  client.invalidateAreaEdit(before, edit.snapshot, edit.replacedRange, value)
  let startRune = before.runeOffset(edit.replacedRange.start)
  client.caret = edit.snapshot.utf16Offset(startRune + value.runeLen)
  client.anchor = client.caret
  client.hasMark = false
  client.nativeChanged = false
  client.areaStringChanged = client.areaStringBound
  client.recordAreaEdit(before, edit.snapshot, edit.replacedRange, value,
    beforeAnchor, beforeCaret, mergeComposition)
  client.revealAreaCaret()
  result = true

proc beginAreaComposition(client: TextFieldClient; range: platform.TextRange;
                          mergeComposition: bool): bool =
  discard client.syncTextAreaBuffer()
  let target = platform.normalizeTextRange(range)
  let before = client.bufferSnapshot
  let beforeAnchor = client.anchor
  let beforeCaret = client.caret
  if target.start == target.`end`:
    client.recordAreaEdit(before, before, target, "", beforeAnchor,
      beforeCaret, mergeComposition)
    client.anchor = target.start
    client.caret = target.start
    client.areaHasDesiredX = false
  elif not client.replaceAreaText(target, "", mergeComposition):
    return false
  client.areaCompositionBase = client.bufferSnapshot
  client.areaCompositionBuffer = forkTextBuffer(client.areaCompositionBase)
  client.areaCompositionStart = client.caret
  client.areaCompositionText.setLen(0)
  client.areaCompositionActive = true
  client.areaCommittedMark = platform.TextRange()
  client.areaHasCommittedMark = false
  client.areaUndoGroupOpen = false
  client.hasMark = false
  client.mark = platform.TextRange()
  result = true

proc updateAreaComposition(client: TextFieldClient; value: string;
                           selected: platform.TextRange): bool =
  if client.areaCompositionBuffer == nil:
    return false
  let target = if client.hasMark: client.mark
    else: platform.TextRange(start: client.areaCompositionStart,
                             `end`: client.areaCompositionStart)
  let edit = client.areaCompositionBuffer.replaceUtf16IfCurrent(
    client.bufferSnapshot, target, value)
  if not edit.committed:
    let snapshot = client.boundBuffer.snapshot()
    client.clearAreaComposition(restoreBase = false)
    client.bufferSnapshot = snapshot
    let limit = snapshot.utf16Len()
    client.caret = max(0, min(client.caret, limit))
    client.anchor = max(0, min(client.anchor, limit))
    client.rebaseAreaUndo(snapshot, client.anchor, client.caret)
    client.resetAreaCache(snapshot.lineCount())
    return false
  client.bufferSnapshot = edit.snapshot
  client.areaCompositionText = value
  let units = platform.utf16Len(value)
  client.mark = platform.TextRange(start: client.areaCompositionStart,
                                    `end`: client.areaCompositionStart + units)
  client.hasMark = value.len > 0
  let normalized = platform.normalizeTextRange(selected)
  client.anchor = client.areaCompositionStart + min(normalized.start, units)
  client.caret = client.areaCompositionStart + min(normalized.`end`, units)
  client.areaHasDesiredX = false
  client.resetAreaCache(client.bufferSnapshot.lineCount())
  if client.areaLineHeight > 0:
    client.areaHeights.setEstimate(float64(client.areaLineHeight))
  client.revealAreaCaret()
  result = true

proc commitAreaComposition(client: TextFieldClient;
                          keepTransaction: bool): bool =
  if client.areaCompositionBuffer == nil:
    return false
  if client.areaCompositionText.len == 0:
    client.clearAreaComposition(restoreBase = true,
                                keepTransaction = keepTransaction)
    return true
  let before = client.areaCompositionBase
  let value = client.areaCompositionText
  let committedMark = client.mark
  let insertion = platform.TextRange(start: client.areaCompositionStart,
                                      `end`: client.areaCompositionStart)
  let edit = client.boundBuffer.replaceUtf16IfCurrent(before, insertion, value)
  if not edit.committed:
    client.clearAreaComposition(restoreBase = false)
    client.bufferSnapshot = edit.snapshot
    let limit = edit.snapshot.utf16Len()
    client.caret = max(0, min(client.caret, limit))
    client.anchor = max(0, min(client.anchor, limit))
    client.rebaseAreaUndo(edit.snapshot, client.anchor, client.caret)
    client.resetAreaCache(edit.snapshot.lineCount())
    return false
  client.invalidateAreaEdit(before, edit.snapshot, edit.replacedRange, value)
  client.recordAreaEdit(before, edit.snapshot, edit.replacedRange, value,
    client.anchor, client.caret, mergeComposition = true)
  client.bufferSnapshot = edit.snapshot
  client.clearAreaComposition(restoreBase = false,
                              keepTransaction = keepTransaction)
  client.areaCommittedMark = committedMark
  client.areaHasCommittedMark = keepTransaction
  client.areaStringChanged = client.areaStringBound
  client.areaUndoGroupOpen = false
  client.revealAreaCaret()
  result = true

method textForRange*(client: TextFieldClient; r: platform.TextRange):
    tuple[s: string, actual: platform.TextRange] =
  if client.multiline:
    discard client.syncTextAreaBuffer()
    let (text, actual) = client.bufferSnapshot.textForRange(r)
    return (text, actual)
  let requested = platform.normalizeTextRange(r)
  let firstByte = platform.utf16ByteOffset(client.text, requested.start)
  let pastLastByte = platform.utf16ByteOffset(client.text, requested.`end`)
  let actual = platform.TextRange(
    start: platform.utf16Len(client.text[0 ..< firstByte]),
    `end`: platform.utf16Len(client.text[0 ..< pastLastByte]))
  if client.password:
    return (repeat("•", actual.`end` - actual.start), actual)
  (client.text[firstByte ..< pastLastByte], actual)

method selection*(client: TextFieldClient): platform.TextSelection =
  if client.multiline:
    discard client.syncTextAreaBuffer()
  client.fieldSelection()

method markedRange*(client: TextFieldClient):
    tuple[r: platform.TextRange, ok: bool] =
  (client.mark, client.hasMark)

method replaceText*(client: TextFieldClient; r: ref platform.TextRange;
                    value: string) =
  if client.readOnly:
    return
  if client.multiline:
    var target: platform.TextRange
    var mergeComposition = false
    if client.areaCompositionBuffer != nil:
      if r == nil:
        let start = client.areaCompositionStart
        client.clearAreaComposition(restoreBase = true,
                                    keepTransaction = true)
        client.anchor = start
        client.caret = start
        target = platform.TextRange(start: start, `end`: start)
      else:
        if not client.commitAreaComposition(keepTransaction = true):
          return
        target = platform.normalizeTextRange(r[])
      mergeComposition = true
    else:
      target = if r == nil: client.fieldRange()
        else: platform.normalizeTextRange(r[])
      mergeComposition = client.areaCompositionActive and
        client.areaHasCommittedMark and r != nil and
        platform.normalizeTextRange(r[]) == client.areaCommittedMark
      if client.areaCompositionActive and not mergeComposition:
        client.areaUndoGroupOpen = false
    if client.replaceAreaText(target, value, mergeComposition):
      client.areaCompositionActive = false
      client.areaCommittedMark = platform.TextRange()
      client.areaHasCommittedMark = false
    elif client.areaCompositionActive:
      client.areaCompositionActive = false
      client.areaCommittedMark = platform.TextRange()
      client.areaHasCommittedMark = false
    return
  let target = if r == nil: client.fieldRange()
    else: platform.normalizeTextRange(r[])
  let before = client.text
  let beforeAnchor = client.anchor
  let beforeCaret = client.caret
  let firstByte = platform.utf16ByteOffset(client.text, target.start)
  let pastLastByte = platform.utf16ByteOffset(client.text, target.`end`)
  let start = platform.utf16Len(client.text[0 ..< firstByte])
  client.text = client.text[0 ..< firstByte] & value &
    client.text[pastLastByte .. ^1]
  client.caret = start + platform.utf16Len(value)
  client.anchor = client.caret
  client.hasMark = false
  client.nativeChanged = true
  client.recordTextFieldEdit(before, client.text, target, value,
    beforeAnchor, beforeCaret)
  client.rebuildFieldLayout()

method setMarkedText*(client: TextFieldClient; r: ref platform.TextRange;
                      value: string; selected: platform.TextRange) =
  if client.readOnly:
    return
  if client.multiline:
    if client.areaCompositionBuffer != nil:
      if r != nil:
        if not client.commitAreaComposition(keepTransaction = true):
          return
        if not client.beginAreaComposition(platform.normalizeTextRange(r[]),
                                            mergeComposition = true):
          return
      else:
        discard client.updateAreaComposition(value, selected)
        return
    else:
      discard client.syncTextAreaBuffer()
      client.areaCompositionActive = false
      let target = if r == nil: client.fieldRange()
        else: platform.normalizeTextRange(r[])
      if not client.beginAreaComposition(target, mergeComposition = false):
        return
    discard client.updateAreaComposition(value, selected)
    return
  let mergeComposition = client.hasMark
  let before = client.text
  let beforeAnchor = client.anchor
  let beforeCaret = client.caret
  let target = if r == nil: client.fieldRange()
    else: platform.normalizeTextRange(r[])
  let firstByte = platform.utf16ByteOffset(client.text, target.start)
  let pastLastByte = platform.utf16ByteOffset(client.text, target.`end`)
  let start = platform.utf16Len(client.text[0 ..< firstByte])
  client.text = client.text[0 ..< firstByte] & value &
    client.text[pastLastByte .. ^1]
  client.mark = platform.TextRange(start: start,
    `end`: start + platform.utf16Len(value))
  client.hasMark = true
  let normalizedSelection = platform.normalizeTextRange(selected)
  let selectedStart = min(normalizedSelection.start,
                           platform.utf16Len(value))
  let selectedEnd = min(normalizedSelection.`end`,
                         platform.utf16Len(value))
  client.anchor = start + selectedStart
  client.caret = start + selectedEnd
  client.nativeChanged = true
  client.recordTextFieldEdit(before, client.text, target, value,
    beforeAnchor, beforeCaret, mergeComposition)
  client.rebuildFieldLayout()

method unmarkText*(client: TextFieldClient) =
  if client.multiline and client.areaCompositionBuffer != nil:
    discard client.commitAreaComposition(keepTransaction = true)
  client.hasMark = false
  client.textUndoGroupOpen = false
  if client.multiline:
    client.areaUndoGroupOpen = false

method boundsForRange*(client: TextFieldClient; r: platform.TextRange):
    tuple[bounds: platform.RectF, actual: platform.TextRange, ok: bool] =
  if client.multiline:
    discard client.syncTextAreaBuffer()
    let requested = platform.normalizeTextRange(r)
    let first = client.bufferSnapshot.runeOffset(requested.start)
    let last = client.bufferSnapshot.runeOffset(requested.`end`)
    let actual = platform.TextRange(
      start: client.bufferSnapshot.utf16Offset(first),
      `end`: client.bufferSnapshot.utf16Offset(last))
    let paragraph = client.bufferSnapshot.lineAt(first)
    let lineRange = client.bufferSnapshot.lineRange(paragraph)
    let layout = client.areaParagraphLayout(paragraph)
    let local = max(0, min(first - lineRange.start,
      client.bufferSnapshot.line(paragraph).runeLen))
    let (x, y, height) = layout.caret(local)
    let scroll = if client.areaScroll == nil: 0'f32
      else: client.areaScroll.offsetY
    result = (platform.RectF(
      x: float64(client.insetX + x),
      y: float64(client.insetY + client.areaHeights.top(paragraph) -
        float64(scroll) + float64(y)),
      w: 1, h: float64(max(height, 1'f32))), actual, true)
    return
  let requested = platform.normalizeTextRange(r)
  let startByte = platform.utf16ByteOffset(client.text, requested.start)
  let endByte = platform.utf16ByteOffset(client.text, requested.`end`)
  let actual = platform.TextRange(
    start: platform.utf16Len(client.text[0 ..< startByte]),
    `end`: platform.utf16Len(client.text[0 ..< endByte]))
  let index = runeIndexAtUtf16(client.text, actual.start)
  let (x, y, height) = client.shaped.caret(index)
  (platform.RectF(x: float64(client.insetX + x),
    y: float64(client.insetY + y), w: 1, h: float64(max(height, 1'f32))),
   actual, true)

method indexForPoint*(client: TextFieldClient; x, y: float64):
    tuple[i: int, ok: bool] =
  if client.multiline:
    discard client.syncTextAreaBuffer()
    let scroll = if client.areaScroll == nil: 0'f32
      else: client.areaScroll.offsetY
    let contentY = max(y - float64(client.insetY) + float64(scroll), 0.0)
    let paragraph = client.areaHeights.at(contentY)
    let layout = client.areaParagraphLayout(paragraph)
    let top = client.areaHeights.top(paragraph)
    let local = layout.indexAt(float32(x - float64(client.insetX)),
      float32(contentY - top))
    let lineRange = client.bufferSnapshot.lineRange(paragraph)
    result = (client.bufferSnapshot.utf16Offset(lineRange.start + local), true)
    return
  let index = client.shaped.indexAt(float32(x) - client.insetX,
                                    float32(y) - client.insetY)
  (utf16UnitAtRune(client.text, index), true)

proc fieldClient(e: Element): TextFieldClient =
  let n = e.node
  if n != nil and n[].textClient of TextFieldClient:
    result = TextFieldClient(n[].textClient)

proc fieldText(client: TextFieldClient): string =
  if client.multiline:
    discard client.syncTextAreaBuffer()
    return client.bufferSnapshot.slice(0, client.bufferSnapshot.len())
  if client.boundBuffer != nil:
    let snapshot = client.boundBuffer.snapshot()
    return snapshot.slice(0, snapshot.len())
  client.text

proc validTextKeyClient(key: TextKey): TextFieldClient =
  if key.client == nil or not key.client.textKeyActive or
      key.client.textKeySequence != key.sequence:
    raise newException(ValueError,
      "ui: TextKey is valid only while its onTextKey callback runs")
  key.client

proc text*(key: TextKey): string =
  ## Returns the input's current text while the callback runs.
  key.validTextKeyClient().fieldText()

proc setText*(key: TextKey; value: string) =
  ## Replaces this input's text while its `onTextKey` callback runs.
  let client = key.validTextKeyClient()
  client.textKeySet = true
  client.textUndoGroupOpen = false
  if client.multiline:
    client.areaUndoGroupOpen = false
    discard client.syncTextAreaBuffer()
    let oldText = client.fieldText()
    if oldText != value:
      client.boundBuffer.set(value)
      discard client.syncTextAreaBuffer()
      client.areaStringChanged = client.areaStringBound
      client.areaHasDesiredX = false
      client.revealAreaCaret()
    client.textKeyPending = client.areaStringBound
    if client.areaStringBound:
      client.textKeyPendingValue = value
    return

  if client.boundBuffer != nil:
    let oldText = client.fieldText()
    if oldText != value:
      let anchor = client.anchor
      let caret = client.caret
      client.boundBuffer.set(value)
      client.bufferSnapshot = client.boundBuffer.snapshot()
      client.rebaseTextFieldHistory(value, anchor, caret)
      client.setFieldText(value)
      let limit = client.bufferSnapshot.utf16Len()
      client.anchor = min(anchor, limit)
      client.caret = min(caret, limit)
      client.rebuildFieldLayout()
    return

  if client.text != value:
    let anchor = client.anchor
    let caret = client.caret
    client.rebaseTextFieldHistory(value, anchor, caret)
    client.text = value
    let limit = platform.utf16Len(value)
    client.anchor = min(anchor, limit)
    client.caret = min(caret, limit)
    client.hasMark = false
    client.nativeChanged = true
    client.rebuildFieldLayout()
  client.textKeyPending = true
  client.textKeyPendingValue = value

proc fieldTypesText(key: platform.Key; mods: platform.Modifiers): bool =
  if (mods and not (platform.modShift or platform.modAlt)) != 0:
    return false
  if key in {platform.keyUnknown, platform.keySpace, platform.keyMinus,
      platform.keyEqual, platform.keyComma, platform.keyPeriod,
      platform.keySlash, platform.keySemicolon, platform.keyQuote,
      platform.keyBracketLeft, platform.keyBracketRight,
      platform.keyBackslash, platform.keyBackquote}:
    return true
  (key >= platform.key0 and key <= platform.key9) or
    (key >= platform.keyA and key <= platform.keyZ)

proc fieldWantsKey(client: TextFieldClient; key: platform.Key;
                   mods: platform.Modifiers): bool =
  let baseMods = mods and not platform.modShift
  let command = when defined(macosx): platform.modSuper else: platform.modCtrl
  if client.readOnly:
    if key in {platform.keyA, platform.keyC} and mods == command:
      return true
    return key in {platform.keyLeft, platform.keyRight, platform.keyUp,
      platform.keyDown, platform.keyHome, platform.keyEnd} and
      (mods and platform.modShift) != 0

  case key
  of platform.keyBackspace:
    return true
  of platform.keyLeft, platform.keyRight:
    return baseMods != platform.modAlt or defined(macosx)
  of platform.keyHome, platform.keyEnd, platform.keyDelete:
    return true
  of platform.keyUp, platform.keyDown, platform.keyPageUp,
      platform.keyPageDown:
    return client.multiline or baseMods != 0
  of platform.keyEnter:
    return baseMods == 0
  of platform.keyTab, platform.keyEscape, platform.keyF1, platform.keyF2,
      platform.keyF3, platform.keyF4, platform.keyF5, platform.keyF6,
      platform.keyF7, platform.keyF8, platform.keyF9, platform.keyF10,
      platform.keyF11, platform.keyF12, platform.keyBack, platform.keyForward:
    return false
  of platform.keyA, platform.keyC, platform.keyX, platform.keyV,
      platform.keyZ, platform.keyY:
    if baseMods == command:
      return true
  else:
    discard

  when defined(macosx):
    if baseMods == platform.modCtrl and key in {platform.keyA, platform.keyB,
        platform.keyD, platform.keyE, platform.keyF, platform.keyH,
        platform.keyK, platform.keyN, platform.keyP}:
      return true
  baseMods == 0 or (defined(macosx) and baseMods == platform.modAlt)

proc dispatchTextKey(client: TextFieldClient; key: platform.Key;
                     mods: platform.Modifiers): bool =
  inc client.textKeySequence
  client.textKeyActive = true
  client.textKeySet = false
  try:
    result = client.onTextKey(TextKey(key: key, mods: mods, client: client,
      sequence: client.textKeySequence))
  finally:
    client.textKeyActive = false

proc newTextFieldElement(c: Context): Element =
  c.newElement(false, identityKindTextInput)

proc acquireTextField(e: Element; initial: string): TextFieldClient =
  let node = e.node
  if node == nil:
    return
  let identity = node[].identity
  let oldClient = e.owner.textInputClients.getOrDefault(identity)
  if oldClient of TextFieldClient:
    result = TextFieldClient(oldClient)
  else:
    result = TextFieldClient(text: initial, lastBoundValue: initial,
      caret: platform.utf16Len(initial), anchor: platform.utf16Len(initial))
    e.owner.textInputClients[identity] = result

proc deliverTextFieldCallbacks(e: Element): bool =
  let owner = e.owner
  let identity = e.node[].identity
  let changeCallbacks = owner.pendingTextCallbacks.getOrDefault(identity)
  let submitCallbacks = owner.pendingTextSubmitCallbacks.getOrDefault(identity)
  owner.pendingTextCallbacks.del(identity)
  owner.pendingTextSubmitCallbacks.del(identity)
  for callback in changeCallbacks:
    callback()
    if owner.closed or not owner.inBuild:
      return false
  for callback in submitCallbacks:
    callback()
    if owner.closed or not owner.inBuild:
      return false
  true

proc finishTextField(c: Context; e: Element; client: TextFieldClient) =
  let node = e.node
  if node == nil:
    return
  client.style = textStack.Style(family: c.theme.font,
                                 size: c.theme.fontSize)
  client.rightToLeft = node[].rightToLeft
  client.placeholderColor = c.theme.textMuted
  client.rebuildFieldLayout()
  node[].textClient = client
  node[].focusable = true
  node[].hasText = true
  node[].textNoWrap = true
  node[].textValue = client.fieldDisplayText()
  node[].textColor = if client.text.len == 0 and client.placeholder.len > 0:
      c.theme.textMuted
    else:
      c.theme.text
  node[].textColorSet = true
  node[].placeholder = client.placeholder
  node[].textStyle.family = c.theme.font
  node[].textStyle.size = c.theme.fontSize
  node[].clipX = true
  client.insetX = node[].pad[3] + node[].border[3]
  client.insetY = node[].pad[0] + node[].border[0]

proc leaveTextAreaMode(client: TextFieldClient) =
  if not client.multiline:
    return
  client.clearTextFieldHistory()
  client.multiline = false
  client.boundBuffer = nil
  client.bufferSnapshot = TextSnapshot()
  client.areaInitialized = false
  client.areaHasLayout = false
  client.areaHasDesiredX = false
  client.areaStringBound = false
  client.areaStringChanged = false
  client.areaStringValue.setLen(0)
  client.areaUndo.setLen(0)
  client.areaRedo.setLen(0)
  client.areaUndoGroupOpen = false
  client.areaCompositionBuffer = nil
  client.areaCompositionBase = TextSnapshot()
  client.areaCompositionStart = 0
  client.areaCompositionText.setLen(0)
  client.areaCompositionActive = false
  client.areaCommittedMark = platform.TextRange()
  client.areaHasCommittedMark = false
  client.areaScroll = nil
  client.areaLayouts.clear()

proc initializeTextArea(client: TextFieldClient; buffer: TextBuffer) =
  client.clearTextFieldHistory()
  client.textKeyPending = false
  client.textKeyPendingValue.setLen(0)
  client.password = false
  client.multiline = true
  client.boundBuffer = buffer
  client.areaScroll = newScrollState()
  client.areaHasLayout = false
  client.areaLineHeight = 0
  client.areaLayouts = initTable[int, textStack.Layout]()
  client.areaInitialized = false
  client.areaStringBound = false
  client.areaStringChanged = false
  client.areaStringValue.setLen(0)
  client.areaUndo.setLen(0)
  client.areaRedo.setLen(0)
  client.areaUndoGroupOpen = false
  client.areaCompositionBuffer = nil
  client.areaCompositionBase = TextSnapshot()
  client.areaCompositionStart = 0
  client.areaCompositionText.setLen(0)
  client.areaCompositionActive = false
  client.areaCommittedMark = platform.TextRange()
  client.areaHasCommittedMark = false

proc updateTextAreaPlaceholder(client: TextFieldClient; e: Element) =
  let node = e.node
  if node == nil:
    return
  let show = client.bufferSnapshot.len() == 0 and client.placeholder.len > 0
  node[].placeholder = client.placeholder
  node[].hasText = show
  node[].textOverlay = show
  node[].textNoWrap = false
  node[].textValue = if show: client.placeholder else: ""
  if show:
    node[].textColor = client.placeholderColor
    node[].textColorSet = true

proc textInputBase*(c: Context; value: var string): Element =
  ## Creates an unstyled single-line text field. It copies native edits into
  ## value on the next build before running that field's change/submit actions.
  result = c.newTextFieldElement()
  let node = result.node
  if node == nil:
    return
  let client = result.acquireTextField(value)
  client.onPaste = nil
  client.onTextKey = nil
  client.leaveTextAreaMode()
  client.password = false

  if client.textKeyPending:
    value = client.textKeyPendingValue
    if client.text != value:
      client.setFieldText(value)
    client.lastBoundValue = value
    client.nativeChanged = false
    client.textKeyPending = false
    client.textKeyPendingValue.setLen(0)
  elif client.boundBuffer != nil:
    client.clearTextFieldHistory()
    client.boundBuffer = nil
    client.bufferSnapshot = TextSnapshot()
    client.setFieldText(value)
  elif value != client.lastBoundValue:
    client.rebaseTextFieldHistory(value, platform.utf16Len(value),
                                  platform.utf16Len(value))
    client.setFieldText(value)
  elif client.nativeChanged:
    value = client.text
    client.lastBoundValue = value
    client.nativeChanged = false

  if not result.deliverTextFieldCallbacks():
    return
  if value != client.text:
    client.rebaseTextFieldHistory(value, platform.utf16Len(value),
                                  platform.utf16Len(value))
    client.setFieldText(value)

  c.finishTextField(result, client)

proc textInputBufferBase*(c: Context; buffer: TextBuffer): Element =
  ## Creates an unstyled single-line field editing an indexed text buffer.
  ## Edits publish on the next build before change/submit actions run.
  buffer.requireTextBuffer()
  result = c.newTextFieldElement()
  let node = result.node
  if node == nil:
    return
  let client = result.acquireTextField("")
  client.onPaste = nil
  client.onTextKey = nil
  client.leaveTextAreaMode()
  client.password = false
  if client.boundBuffer != buffer:
    client.textKeyPending = false
    client.textKeyPendingValue.setLen(0)
    client.clearTextFieldHistory()
    client.boundBuffer = buffer
    client.bufferSnapshot = buffer.snapshot()
    client.setFieldText($client.bufferSnapshot)
  elif client.nativeChanged and not client.hasMark:
    let (snapshot, committed) = buffer.commitTextBuffer(client.bufferSnapshot,
                                                         client.text)
    client.bufferSnapshot = snapshot
    if committed:
      client.lastBoundValue = client.text
      client.nativeChanged = false
    else:
      let text = $snapshot
      client.rebaseTextFieldHistory(text, platform.utf16Len(text),
                                    platform.utf16Len(text))
      client.setFieldText($snapshot)
  elif not client.hasMark:
    let snapshot = buffer.snapshot()
    if snapshot.version != client.bufferSnapshot.version:
      client.bufferSnapshot = snapshot
      let text = $snapshot
      client.rebaseTextFieldHistory(text, platform.utf16Len(text),
                                    platform.utf16Len(text))
      client.setFieldText(text)

  if not result.deliverTextFieldCallbacks():
    return
  c.finishTextField(result, client)

proc textAreaCore(c: Context; buffer: TextBuffer;
                  boundValue: ptr string): Element =
  result = c.newTextFieldElement()
  let node = result.node
  if node == nil:
    return
  node[].textAreaInput = true
  let client = result.acquireTextField("")
  client.onPaste = nil
  client.onTextKey = nil
  var buffer = buffer
  if boundValue == nil:
    buffer.requireTextBuffer()
    if client.areaStringBound:
      client.areaStringBound = false
      client.areaStringChanged = false
      client.areaStringValue.setLen(0)
    if not client.multiline or client.boundBuffer != buffer:
      client.initializeTextArea(buffer)
  elif not client.multiline or not client.areaStringBound:
    buffer = newTextBuffer(boundValue[])
    client.initializeTextArea(buffer)
    client.areaStringBound = true
    client.areaStringValue = boundValue[]
  elif client.textKeyPending and client.areaStringBound:
    boundValue[] = client.textKeyPendingValue
    client.areaStringValue = boundValue[]
    client.areaStringChanged = false
    client.textKeyPending = false
    client.textKeyPendingValue.setLen(0)
  elif boundValue[] != client.areaStringValue:
    client.clearAreaComposition(restoreBase = false)
    client.boundBuffer.set(boundValue[])
    let snapshot = client.boundBuffer.snapshot()
    client.rebaseAreaUndo(snapshot, snapshot.utf16Len(),
                          snapshot.utf16Len())
    client.areaStringValue = boundValue[]
    client.areaStringChanged = false
    client.areaInitialized = false
    client.areaHasDesiredX = false
  elif client.areaStringChanged and not client.hasMark:
    boundValue[] = $client.boundBuffer
    client.areaStringValue = boundValue[]
    client.areaStringChanged = false
  discard client.syncTextAreaBuffer()
  node[].textColor = c.theme.text
  node[].textColorSet = true
  node[].textStyle.family = c.theme.font
  node[].textStyle.size = c.theme.fontSize
  node[].textSelectionColor = c.theme.selection
  client.style = node[].textStyle
  client.rightToLeft = node[].rightToLeft
  client.placeholderColor = c.theme.textMuted
  if client.areaLineHeight <= 0:
    let sample = textStack.shared().layout(textStack.Params(text: " ",
      style: client.style, keepSpaces: true, rtl: client.rightToLeft))
    client.areaLineHeight = max(sample.height, max(client.style.size, 1'f32))
    client.areaHeights.setEstimate(float64(client.areaLineHeight))
  let viewportHeight = max(client.areaHeight, c.theme.space(20))
  client.prepareAreaWindow(viewportHeight)
  node[].textClient = client
  node[].focusable = true
  client.updateTextAreaPlaceholder(result)
  node[].scrollY = true
  node[].scrollState = client.areaScroll
  node[].clipX = true
  node[].clipY = true
  let snapshot = client.bufferSnapshot
  let count = snapshot.lineCount()
  node[].textAreaParagraphs = count
  let first = client.areaFirst
  let pastLast = client.areaPastLast
  let top = client.areaHeights.top(first).float32
  let bottom = max(client.areaContentHeight() -
    client.areaHeights.top(pastLast).float32, 0'f32)
  let lineHeight = client.areaLineHeight
  discard result.children(proc() =
    if top > 0:
      discard c.box().height(top).shrink(0)
    for line in first..<pastLast:
      let paragraph = c.text(snapshot.line(line)).shrink(0)
        .minHeight(lineHeight)
      if paragraph.node != nil:
        paragraph.node[].textAreaOwner = client
        paragraph.node[].textAreaLine = line
        paragraph.node[].textStyle = node[].textStyle
        paragraph.node[].textColor = node[].textColor
        paragraph.node[].textColorSet = node[].textColorSet
        paragraph.node[].textAlign = node[].textAlign
        paragraph.node[].rightToLeft = node[].rightToLeft
    if pastLast < count and bottom > 0:
      discard c.box().height(bottom).shrink(0)
  )
  if not result.deliverTextFieldCallbacks():
    return

proc lines*(e: Element; min, max: int): Element =
  ## Grows a text area with its wrapped text up to `max` lines.
  ## The area remains at least `min` lines high. A nonpositive `max` leaves
  ## its natural height unconstrained.
  result = e
  let node = e.node
  if node != nil and node[].textAreaInput:
    node[].textAreaMinLines = min
    node[].textAreaMaxLines = max

proc textAreaBase*(c: Context; value: var string): Element =
  ## Creates an unstyled multiline editor bound to a string. Native edits are
  ## copied into value on the next build before the field's change actions.
  ## Without `lines()`, its height follows the paragraph count, at least three
  ## lines, and wrapped text scrolls within it.
  result = c.textAreaCore(nil, addr value)

proc textAreaBufferBase*(c: Context; buffer: TextBuffer): Element =
  ## Creates an unstyled multiline editor over an indexed text buffer.
  ## Without `lines()`, its height follows the paragraph count, at least three
  ## lines, and wrapped text scrolls within it.
  result = c.textAreaCore(buffer, nil)

proc themeTextInput(c: Context; e: Element): Element =
  let theme = c.theme
  result = e
  result = result.padding(theme.space(1.5), theme.space(2.5))
  let node = result.node
  if node != nil:
    node[].radius = [theme.radius, theme.radius, theme.radius, theme.radius]
    node[].background = theme.surface
    node[].border = [1'f32, 1, 1, 1]
    node[].borderColor = if node[].invalid: theme.danger
      elif result.focused(): theme.accent
      elif result.hovered(): theme.border.mix(theme.text, 0.2'f32)
      else: theme.border
    if node[].textClient of TextFieldClient:
      let client = TextFieldClient(node[].textClient)
      client.insetX = node[].pad[3] + node[].border[3]
      client.insetY = node[].pad[0] + node[].border[0]

proc textAreaBuffer*(c: Context; buffer: TextBuffer): Element =
  ## Creates a themed multiline editor backed by indexed text storage.
  let theme = c.theme
  result = c.themeTextInput(c.textAreaBufferBase(buffer))
  discard result.minHeight(theme.space(20))

proc textArea*(c: Context; value: var string): Element =
  ## Creates a themed multiline editor bound to a string.
  let theme = c.theme
  result = c.themeTextInput(c.textAreaBase(value))
  discard result.minHeight(theme.space(20))

proc textInput*(c: Context; value: var string): Element =
  ## Creates a themed single-line text input editing value. Native edits are
  ## copied back on the next build before change/submit actions run.
  result = c.themeTextInput(c.textInputBase(value))

proc textInputBuffer*(c: Context; buffer: TextBuffer): Element =
  ## Creates a themed single-line input editing an indexed text buffer.
  ## Native edits publish on the next build before change/submit actions run.
  result = c.themeTextInput(c.textInputBufferBase(buffer))

proc placeholder*(e: Element; value: string): Element =
  ## Shows value while the text field is empty.
  result = e
  let client = e.fieldClient()
  let node = e.node
  if client != nil and node != nil:
    client.placeholder = value
    node[].placeholder = value
    if client.multiline:
      client.updateTextAreaPlaceholder(e)
    elif client.text.len == 0:
      node[].textValue = value
      node[].textColor = client.placeholderColor
      node[].textColorSet = true

proc readOnly*(e: Element; value = true): Element =
  ## Prevents edits while keeping the field focusable and selectable.
  result = e
  let client = e.fieldClient()
  if client != nil:
    client.readOnly = value

proc password*(e: Element): Element =
  ## Masks a single-line field and hides its value from clipboard and input methods.
  result = e
  let client = e.fieldClient()
  let node = e.node
  if client != nil and node != nil and not client.multiline:
    client.password = true
    client.rebuildFieldLayout()
    node[].textValue = client.fieldDisplayText()

proc onPaste*(e: Element; action: proc(text: string): bool {.closure.}): Element =
  ## Lets action handle clipboard text before the field inserts it. An empty
  ## string is passed when the clipboard has no plain text. This setting lasts
  ## for the current build of the field.
  result = e
  let client = e.fieldClient()
  if client != nil:
    client.onPaste = action

proc onTextKey*(e: Element;
                action: proc(key: TextKey): bool {.closure.}): Element =
  ## Runs action for a non-printing key before the field handles it. Return
  ## true to consume the key. TextKey.text and TextKey.setText are valid only
  ## while action runs. This setting lasts for the current build of the field.
  result = e
  let client = e.fieldClient()
  if client != nil:
    client.onTextKey = action

proc textSelection*(e: Element): tuple[start, `end`: int] =
  ## Returns the selected rune range, or the caret when both indices match.
  let client = e.fieldClient()
  if client != nil:
    result = (client.fieldRuneIndex(min(client.anchor, client.caret)),
              client.fieldRuneIndex(max(client.anchor, client.caret)))

proc textAnchorCaret*(e: Element): tuple[anchor, caret: int] =
  ## Returns the text selection endpoints in runes, preserving its direction.
  let client = e.fieldClient()
  if client != nil:
    result = (client.fieldRuneIndex(client.anchor),
              client.fieldRuneIndex(client.caret))

proc setTextSelection*(e: Element; start, `end`: int): Element =
  ## Selects a rune range or places the caret at start when the indices match.
  result = e
  let client = e.fieldClient()
  if client != nil:
    if client.multiline:
      if client.areaCompositionBuffer != nil:
        discard client.commitAreaComposition(keepTransaction = false)
      else:
        client.areaCompositionActive = false
    client.textUndoGroupOpen = false
    let count = client.fieldRuneLen()
    let first = max(0, min(start, count))
    let pastLast = max(0, min(`end`, count))
    client.anchor = client.fieldUtf16Offset(first)
    client.caret = client.fieldUtf16Offset(pastLast)
    client.hasMark = false
    client.areaHasDesiredX = false
    client.revealAreaCaret()
    if e.owner.invalidate != nil:
      e.owner.invalidate()

proc composing*(e: Element): bool =
  ## Reports whether an input method currently has marked text in this field.
  let client = e.fieldClient()
  client != nil and client.hasMark

proc fieldPointerSelection(client: TextFieldClient; x, y: float64;
                           extend: bool): bool =
  let (index, ok) = client.indexForPoint(x, y)
  if not ok:
    return false
  client.textUndoGroupOpen = false
  if not extend:
    client.anchor = index
  client.caret = index
  client.areaHasDesiredX = false
  client.revealAreaCaret()
  true

proc fieldMove(client: TextFieldClient; key: platform.Key;
               extend: bool; byWord = false;
               documentEdge = false): bool =
  client.textUndoGroupOpen = false
  if client.multiline:
    client.areaUndoGroupOpen = false
    discard client.syncTextAreaBuffer()
    let snapshot = client.bufferSnapshot
    let selection = client.fieldRange()
    let current = snapshot.runeOffset(client.caret)
    var nextRune = current
    var keepDesiredX = false
    if not byWord and not extend and selection.start != selection.`end` and
        key in {platform.keyLeft, platform.keyRight}:
      let unit = if key == platform.keyLeft: selection.start
        else: selection.`end`
      nextRune = snapshot.runeOffset(unit)
    else:
      let paragraph = snapshot.lineAt(current)
      let lineRange = snapshot.lineRange(paragraph)
      let local = current - lineRange.start
      let layout = client.areaParagraphLayout(paragraph)
      if byWord:
        let rtl = client.fieldCaretRightToLeft(current)
        let forward = if rtl: key == platform.keyLeft
          else: key == platform.keyRight
        nextRune = client.fieldWordBoundary(current, forward)
        client.areaHasDesiredX = false
      else:
        case key
        of platform.keyLeft, platform.keyRight:
          let direction = if key == platform.keyLeft: -1 else: 1
          let moved = layout.moveCaret(textStack.CaretPosition(index: local,
            affinity: textStack.Downstream), direction).index
          nextRune = lineRange.start + moved
          if moved == local and
              (if direction < 0: current > 0 else: current < snapshot.len()):
            nextRune = current + direction
          client.areaHasDesiredX = false
        of platform.keyHome, platform.keyEnd:
          if documentEdge:
            nextRune = if key == platform.keyHome: 0 else: snapshot.len()
          else:
            let visualLine = layout.lineAt(local)
            let target = layout.lines[visualLine]
            nextRune = lineRange.start +
              (if key == platform.keyHome: target.start else: target.`end`)
          client.areaHasDesiredX = false
        of platform.keyUp, platform.keyDown:
          let visualLine = layout.lineAt(local)
          if not client.areaHasDesiredX:
            let (x, _, _) = layout.caret(local)
            client.areaDesiredX = x
            client.areaHasDesiredX = true
          let direction = if key == platform.keyUp: -1 else: 1
          var targetParagraph = paragraph
          var targetLine = visualLine + direction
          if targetLine < 0 and targetParagraph > 0:
            dec targetParagraph
            targetLine = client.areaParagraphLayout(targetParagraph).lines.high
          elif targetLine >= layout.lines.len and
              targetParagraph + 1 < snapshot.lineCount():
            inc targetParagraph
            targetLine = 0
          let targetLayout = client.areaParagraphLayout(targetParagraph)
          targetLine = max(0, min(targetLine, targetLayout.lines.high))
          let targetMetrics = targetLayout.lines[targetLine]
          let targetLocal = targetLayout.indexAt(client.areaDesiredX,
            targetMetrics.y + targetMetrics.height / 2)
          let targetRange = snapshot.lineRange(targetParagraph)
          nextRune = targetRange.start + targetLocal
          keepDesiredX = true
        else:
          return false
    nextRune = max(0, min(nextRune, snapshot.len()))
    let next = snapshot.utf16Offset(nextRune)
    if not extend:
      client.anchor = next
    client.caret = next
    if not keepDesiredX:
      client.areaHasDesiredX = false
    client.revealAreaCaret()
    return true

  let selection = client.fieldRange()
  var nextRune: int
  if not byWord and not extend and selection.start != selection.`end` and
      key in {platform.keyLeft, platform.keyRight}:
    let unit = if key == platform.keyLeft: selection.start else: selection.`end`
    nextRune = runeIndexAtUtf16(client.text, unit)
  else:
    let current = runeIndexAtUtf16(client.text, client.caret)
    if byWord:
      let rtl = client.fieldCaretRightToLeft(current)
      let forward = if rtl: key == platform.keyLeft
        else: key == platform.keyRight
      nextRune = client.fieldWordBoundary(current, forward)
    else:
      case key
      of platform.keyLeft:
        nextRune = client.shaped.moveCaret(
          textStack.CaretPosition(index: current,
            affinity: textStack.Downstream), -1).index
      of platform.keyRight:
        nextRune = client.shaped.moveCaret(
          textStack.CaretPosition(index: current,
            affinity: textStack.Downstream), 1).index
      of platform.keyHome:
        nextRune = 0
      of platform.keyEnd:
        nextRune = client.text.runeLen
      of platform.keyUp:
        nextRune = 0
      of platform.keyDown:
        nextRune = client.text.runeLen
      else:
        return false
  let next = utf16UnitAtRune(client.text, nextRune)
  if not extend:
    client.anchor = next
  client.caret = next
  true

proc fieldVisualLineRange(client: TextFieldClient; rune: int):
    tuple[start, `end`: int] =
  if client.multiline:
    discard client.syncTextAreaBuffer()
    let paragraph = client.bufferSnapshot.lineAt(rune)
    let lineRange = client.bufferSnapshot.lineRange(paragraph)
    let local = rune - lineRange.start
    let layout = client.areaParagraphLayout(paragraph)
    let line = layout.lines[layout.lineAt(local)]
    return (lineRange.start + line.start, lineRange.start + line.`end`)
  (0, client.text.runeLen)

when defined(macosx):
  proc fieldParagraphRange(client: TextFieldClient; rune: int):
      tuple[start, `end`: int] =
    if client.multiline:
      discard client.syncTextAreaBuffer()
      return client.bufferSnapshot.lineRange(client.bufferSnapshot.lineAt(rune))
    (0, client.text.runeLen)

  proc fieldMoveParagraphEdge(client: TextFieldClient; toEnd, extend: bool) =
    client.textUndoGroupOpen = false
    let current = client.fieldRuneIndex(client.caret)
    let paragraph = client.fieldParagraphRange(current)
    let rune = if toEnd: paragraph.`end` else: paragraph.start
    let unit = client.fieldUtf16Offset(rune)
    if not extend:
      client.anchor = unit
    client.caret = unit
    client.areaHasDesiredX = false
    client.revealAreaCaret()

proc fieldDeleteRange(client: TextFieldClient; key: platform.Key;
                      byWord = false; toLineStart = false):
    tuple[r: platform.TextRange, ok: bool] =
  result.r = client.fieldRange()
  if result.r.start != result.r.`end`:
    result.ok = true
    return
  if client.multiline:
    discard client.syncTextAreaBuffer()
    let snapshot = client.bufferSnapshot
    let current = snapshot.runeOffset(client.caret)
    if current < 0 or current > snapshot.len():
      return
    var next: int
    if toLineStart:
      next = client.fieldVisualLineRange(current).start
    elif byWord:
      next = client.fieldWordBoundary(current, key == platform.keyDelete)
    else:
      let direction = if key == platform.keyBackspace: -1 else: 1
      let paragraph = snapshot.lineAt(current)
      let lineRange = snapshot.lineRange(paragraph)
      let local = current - lineRange.start
      let layout = client.areaParagraphLayout(paragraph)
      let moved = layout.moveCaret(textStack.CaretPosition(index: local,
        affinity: textStack.Downstream), direction).index
      next = lineRange.start + moved
      if moved == local and
          (if direction < 0: current > 0 else: current < snapshot.len()):
        next = current + direction
    if next == current:
      return
    let first = snapshot.utf16Offset(min(current, next))
    let pastLast = snapshot.utf16Offset(max(current, next))
    result.r = platform.TextRange(start: first, `end`: pastLast)
    result.ok = true
    return
  let current = runeIndexAtUtf16(client.text, client.caret)
  var next: int
  if toLineStart:
    next = 0
  elif byWord:
    next = client.fieldWordBoundary(current, key == platform.keyDelete)
  else:
    let direction = if key == platform.keyBackspace: -1 else: 1
    next = client.shaped.moveCaret(
      textStack.CaretPosition(index: current, affinity: textStack.Downstream),
      direction).index
  if next == current:
    return
  let unit = utf16UnitAtRune(client.text, next)
  result.r = platform.TextRange(start: min(client.caret, unit),
                                `end`: max(client.caret, unit))
  result.ok = true
