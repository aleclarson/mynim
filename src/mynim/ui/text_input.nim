## Bound single-line text fields backed by the platform text-input client.

type TextFieldClient = ref object of platform.TextInputClient
  text, lastBoundValue, placeholder: string
  boundBuffer: TextBuffer
  bufferSnapshot: TextSnapshot
  anchor, caret: int
  mark: platform.TextRange
  hasMark, nativeChanged, readOnly, rightToLeft: bool
  insetX, insetY: float32
  placeholderColor: Color
  style: textStack.Style
  shaped: textStack.Layout

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
  client.shaped = textStack.shared().layout(textStack.Params(
    text: client.text, style: client.style, noWrap: true,
    keepSpaces: true, rtl: client.rightToLeft))

method textForRange*(client: TextFieldClient; r: platform.TextRange):
    tuple[s: string, actual: platform.TextRange] =
  let requested = platform.normalizeTextRange(r)
  let firstByte = platform.utf16ByteOffset(client.text, requested.start)
  let pastLastByte = platform.utf16ByteOffset(client.text, requested.`end`)
  let actual = platform.TextRange(
    start: platform.utf16Len(client.text[0 ..< firstByte]),
    `end`: platform.utf16Len(client.text[0 ..< pastLastByte]))
  (client.text[firstByte ..< pastLastByte], actual)

method selection*(client: TextFieldClient): platform.TextSelection =
  client.fieldSelection()

method markedRange*(client: TextFieldClient):
    tuple[r: platform.TextRange, ok: bool] =
  (client.mark, client.hasMark)

method replaceText*(client: TextFieldClient; r: ref platform.TextRange;
                    value: string) =
  if client.readOnly:
    return
  let target = if r == nil: client.fieldRange()
    else: platform.normalizeTextRange(r[])
  let firstByte = platform.utf16ByteOffset(client.text, target.start)
  let pastLastByte = platform.utf16ByteOffset(client.text, target.`end`)
  let start = platform.utf16Len(client.text[0 ..< firstByte])
  client.text = client.text[0 ..< firstByte] & value &
    client.text[pastLastByte .. ^1]
  client.caret = start + platform.utf16Len(value)
  client.anchor = client.caret
  client.hasMark = false
  client.nativeChanged = true
  client.rebuildFieldLayout()

method setMarkedText*(client: TextFieldClient; r: ref platform.TextRange;
                      value: string; selected: platform.TextRange) =
  if client.readOnly:
    return
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
  client.rebuildFieldLayout()

method unmarkText*(client: TextFieldClient) =
  client.hasMark = false

method boundsForRange*(client: TextFieldClient; r: platform.TextRange):
    tuple[bounds: platform.RectF, actual: platform.TextRange, ok: bool] =
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
  let index = client.shaped.indexAt(float32(x) - client.insetX,
                                    float32(y) - client.insetY)
  (utf16UnitAtRune(client.text, index), true)

proc fieldClient(e: Element): TextFieldClient =
  let n = e.node
  if n != nil and n[].textClient of TextFieldClient:
    result = TextFieldClient(n[].textClient)

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
  node[].textValue = if client.text.len == 0: client.placeholder else: client.text
  node[].textColor = if client.text.len == 0 and client.placeholder.len > 0:
      c.theme.textMuted
    else:
      c.theme.text
  node[].textColorSet = true
  node[].textStyle.family = c.theme.font
  node[].textStyle.size = c.theme.fontSize
  node[].clipX = true
  client.insetX = node[].pad[3] + node[].border[3]
  client.insetY = node[].pad[0] + node[].border[0]

proc textInputBase*(c: Context; value: var string): Element =
  ## Creates an unstyled single-line text field. It copies native edits into
  ## value on the next build before running that field's change/submit actions.
  result = c.newTextFieldElement()
  let node = result.node
  if node == nil:
    return
  let client = result.acquireTextField(value)

  if client.boundBuffer != nil:
    client.boundBuffer = nil
    client.bufferSnapshot = TextSnapshot()
    client.setFieldText(value)
  elif value != client.lastBoundValue:
    client.setFieldText(value)
  elif client.nativeChanged:
    value = client.text
    client.lastBoundValue = value
    client.nativeChanged = false

  if not result.deliverTextFieldCallbacks():
    return
  if value != client.text:
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
  if client.boundBuffer != buffer:
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
      client.setFieldText($snapshot)
  elif not client.hasMark:
    let snapshot = buffer.snapshot()
    if snapshot.version != client.bufferSnapshot.version:
      client.bufferSnapshot = snapshot
      client.setFieldText($snapshot)

  if not result.deliverTextFieldCallbacks():
    return
  c.finishTextField(result, client)

proc themeTextInput(c: Context; e: Element): Element =
  let theme = c.theme
  result = e
  result = result.padding(theme.space(1.5), theme.space(2.5))
  let node = result.node
  if node != nil:
    node[].radius = [theme.radius, theme.radius, theme.radius, theme.radius]
    node[].background = theme.surface
    node[].border = [1'f32, 1, 1, 1]
    node[].borderColor = if result.focused(): theme.accent
      elif result.hovered(): theme.border.mix(theme.text, 0.2'f32)
      else: theme.border

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
    if client.text.len == 0:
      node[].textValue = value
      node[].textColor = client.placeholderColor
      node[].textColorSet = true

proc readOnly*(e: Element; value = true): Element =
  ## Prevents edits while keeping the field focusable and selectable.
  result = e
  let client = e.fieldClient()
  if client != nil:
    client.readOnly = value

proc textSelection*(e: Element): tuple[start, `end`: int] =
  ## Returns the selected rune range, or the caret when both indices match.
  let client = e.fieldClient()
  if client != nil:
    result = (runeIndexAtUtf16(client.text, min(client.anchor, client.caret)),
              runeIndexAtUtf16(client.text, max(client.anchor, client.caret)))

proc setTextSelection*(e: Element; start, `end`: int): Element =
  ## Selects a rune range or places the caret at start when the indices match.
  result = e
  let client = e.fieldClient()
  if client != nil:
    let first = max(0, min(start, client.text.runeLen))
    let pastLast = max(0, min(`end`, client.text.runeLen))
    client.anchor = utf16UnitAtRune(client.text, first)
    client.caret = utf16UnitAtRune(client.text, pastLast)
    client.hasMark = false
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
  if not extend:
    client.anchor = index
  client.caret = index
  true

proc fieldMove(client: TextFieldClient; key: platform.Key;
               extend: bool): bool =
  let selection = client.fieldRange()
  var nextRune: int
  if not extend and selection.start != selection.`end` and
      key in {platform.keyLeft, platform.keyRight}:
    let unit = if key == platform.keyLeft: selection.start else: selection.`end`
    nextRune = runeIndexAtUtf16(client.text, unit)
  else:
    let current = runeIndexAtUtf16(client.text, client.caret)
    case key
    of platform.keyLeft:
      nextRune = client.shaped.moveCaret(
        textStack.CaretPosition(index: current, affinity: textStack.Downstream), -1).index
    of platform.keyRight:
      nextRune = client.shaped.moveCaret(
        textStack.CaretPosition(index: current, affinity: textStack.Downstream), 1).index
    of platform.keyHome:
      nextRune = 0
    of platform.keyEnd:
      nextRune = client.text.runeLen
    else:
      return false
  let next = utf16UnitAtRune(client.text, nextRune)
  if not extend:
    client.anchor = next
  client.caret = next
  true

proc fieldDeleteRange(client: TextFieldClient; key: platform.Key):
    tuple[r: platform.TextRange, ok: bool] =
  result.r = client.fieldRange()
  if result.r.start != result.r.`end`:
    result.ok = true
    return
  let current = runeIndexAtUtf16(client.text, client.caret)
  let direction = if key == platform.keyBackspace: -1 else: 1
  let next = client.shaped.moveCaret(
    textStack.CaretPosition(index: current, affinity: textStack.Downstream),
    direction).index
  if next == current:
    return
  let unit = utf16UnitAtRune(client.text, next)
  result.r = platform.TextRange(start: min(client.caret, unit),
                                `end`: max(client.caret, unit))
  result.ok = true
