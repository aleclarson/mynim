import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

type
  Editor = ref object of ui.TextInputClient
    value: string
    selected: ui.TextSelection
    marked: ui.TextRange
    hasMark: bool
    lastReplacement: ui.TextRange
    hasReplacement: bool
    lastPointX, lastPointY: float64
    unmarks: int

method textForRange*(editor: Editor; r: ui.TextRange):
    tuple[s: string, actual: ui.TextRange] =
  (editor.value, ui.TextRange(start: 0, `end`: platform.utf16Len(editor.value)))

method selection*(editor: Editor): ui.TextSelection = editor.selected

method markedRange*(editor: Editor): tuple[r: ui.TextRange, ok: bool] =
  (editor.marked, editor.hasMark)

method replaceText*(editor: Editor; r: ref ui.TextRange; text: string) =
  let replacement = if r == nil: editor.selected.`range`
    else: platform.normalizeTextRange(r[])
  let first = platform.utf16ByteOffset(editor.value, replacement.start)
  let pastLast = platform.utf16ByteOffset(editor.value, replacement.`end`)
  editor.value = editor.value[0 ..< first] & text & editor.value[pastLast .. ^1]
  editor.lastReplacement = replacement
  editor.hasReplacement = true
  let caret = replacement.start + platform.utf16Len(text)
  editor.selected = ui.TextSelection(
    `range`: ui.TextRange(start: caret, `end`: caret))
  editor.hasMark = false

method setMarkedText*(editor: Editor; r: ref ui.TextRange; text: string;
                      selected: ui.TextRange) =
  let replacement = if r == nil: editor.selected.`range`
    else: platform.normalizeTextRange(r[])
  let first = platform.utf16ByteOffset(editor.value, replacement.start)
  let pastLast = platform.utf16ByteOffset(editor.value, replacement.`end`)
  editor.value = editor.value[0 ..< first] & text & editor.value[pastLast .. ^1]
  editor.marked = ui.TextRange(start: replacement.start,
    `end`: replacement.start + platform.utf16Len(text))
  editor.hasMark = true
  editor.selected = ui.TextSelection(`range`: ui.TextRange(
    start: editor.marked.start + selected.start,
    `end`: editor.marked.start + selected.`end`))

method unmarkText*(editor: Editor) =
  editor.hasMark = false
  inc editor.unmarks

method boundsForRange*(editor: Editor; r: ui.TextRange):
    tuple[bounds: ui.RectF, actual: ui.TextRange, ok: bool] =
  (ui.RectF(x: 2, y: 3, w: 1, h: 16), r, true)

method indexForPoint*(editor: Editor; x, y: float64): tuple[i: int, ok: bool] =
  editor.lastPointX = x
  editor.lastPointY = y
  (7, true)

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui text input client test"))
app.initialized = true
app.handleReady()

let editor = Editor(value: "A😀B",
  selected: ui.TextSelection(`range`: ui.TextRange(start: 3, `end`: 3)))
var editorFocused, otherFocused: bool
let content = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().size(180, 100).padding(8).label("Panel").children(proc() =
    let input = ctx.box().size(100, 30).label("Editor").textInput(editor)
    editorFocused = input.focused()
    let other = ctx.box().size(100, 30).label("Other")
      .onClick(proc() = discard)
    otherFocused = other.focused()
  )
)
let win = newWindow(WindowOptions(width: 200, height: 120, hidden: true,
  content: content))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert not native.lastTextInput().active
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let (initialTree, _) = native.accessibility()
doAssert initialTree != nil and initialTree.nodes.len == 3
doAssert initialTree.nodes[1].role == platform.roleTextField
doAssert initialTree.nodes[1].label == "Editor"
doAssert initialTree.nodes[1].value == "A😀B"
doAssert initialTree.nodes[1].states == platform.accessFocusable
doAssert initialTree.nodes[1].actions ==
  (platform.actionFocus or platform.actionSetValue)

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert editorFocused and not otherFocused
var inputState = native.lastTextInput()
doAssert inputState.active and inputState.client != nil
doAssert inputState.text == "A😀B"
doAssert inputState.start == 2 and inputState.`end` == 2
doAssert inputState.caret.x == initialTree.nodes[1].bounds.x + 2
doAssert inputState.caret.y == initialTree.nodes[1].bounds.y + 3

let adapter = inputState.client
let (surrounding, actual) = adapter.textForRange(ui.TextRange(start: 0,
  `end`: 4))
doAssert surrounding == "A😀B"
doAssert actual == ui.TextRange(start: 0, `end`: 4)
let (index, indexOk) = adapter.indexForPoint(inputState.caret.x + 5,
  inputState.caret.y + 6)
doAssert indexOk and index == 7
doAssert editor.lastPointX == 7 and editor.lastPointY == 9

doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "X", replace: true, `from`: 1, to: 2))
doAssert editor.value == "AXB"
doAssert editor.hasReplacement
doAssert editor.lastReplacement == ui.TextRange(start: 1, `end`: 3)
inputState = native.lastTextInput()
doAssert inputState.text == "AXB"

doAssert native.send(platform.SurfaceEvent(kind: platform.textComposition,
  text: "e", caret: 1))
doAssert editor.value == "AXeB" and editor.hasMark
inputState = native.lastTextInput()
doAssert inputState.text == "AXB"
doAssert inputState.start == 2 and inputState.`end` == 2
discard native.send(platform.SurfaceEvent(kind: platform.textComposition))
doAssert not editor.hasMark and editor.unmarks == 1
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput, text: "é"))
doAssert editor.value == "AXéB"
doAssert editor.lastReplacement == ui.TextRange(start: 2, `end`: 3)

let (focusedTree, _) = native.accessibility()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: focusedTree.nodes[1].id, action: platform.accessSetValue, text: "value"))
doAssert editor.value == "value"
doAssert native.frame()
let (updatedTree, _) = native.accessibility()
doAssert updatedTree.nodes[1].value == "value"

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert otherFocused and not editorFocused
inputState = native.lastTextInput()
doAssert not inputState.active and inputState.client == nil
adapter.replaceText(nil, "stale")
doAssert editor.value == "value"

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab, mods: platform.modShift))
doAssert native.frame()
doAssert editorFocused and not otherFocused
discard native.send(platform.SurfaceEvent(kind: platform.surfaceBlur))
inputState = native.lastTextInput()
doAssert not inputState.active and inputState.client == nil
adapter.replaceText(nil, "blurred")
doAssert editor.value == "value"

win.destroy()
loop.shutdown()
