import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui
import mynim/ui/editor as editor

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "editor view test"))
app.initialized = true
app.handleReady()

let editorState = editor.newState("a😀b")
editorState.label = "Source"
editorState.buffer.setLanguage(editor.languageNamed("go"))
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  discard editor.view(ctx, editorState).size(240, 100)
)
let win = newWindow(WindowOptions(width: 260, height: 130, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var fieldId = 0'u64
for node in native.accessibility()[0].nodes:
  if node.role == platform.roleTextField and node.label == "Source":
    fieldId = node.id
    doAssert node.value == $editorState.buffer
doAssert fieldId != 0
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: fieldId, action: platform.accessFocus))
doAssert native.frame()

editorState.select(5, 1)
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
let reversed = native.lastTextInput().client.selection()
doAssert reversed.`range`.start == 1 and reversed.`range`.`end` == 3
doAssert reversed.reversed
doAssert editorState.selection() == editor.Selection(anchor: 5, head: 1)
doAssert editorState.selectedText() == "😀"

editorState.select(1, 5)
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "Z"))
doAssert $editorState.buffer == "aZb"
doAssert editorState.buffer.modified()
doAssert native.frame()
doAssert editorState.selection() == editor.Selection(anchor: 2, head: 2)
doAssert editorState.buffer.canUndo() and not editorState.buffer.canRedo()
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "!"))
doAssert $editorState.buffer == "aZ!b"
doAssert native.frame()

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: platform.modSuper))
doAssert native.frame()
doAssert $editorState.buffer == "a😀b"
doAssert not editorState.buffer.modified()
doAssert editorState.selection() == editor.Selection(anchor: 1, head: 5)
doAssert not editorState.buffer.canUndo() and editorState.buffer.canRedo()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: platform.modSuper or platform.modShift))
doAssert native.frame()
doAssert $editorState.buffer == "aZ!b"
doAssert editorState.buffer.modified()
doAssert editorState.selection() == editor.Selection(anchor: 3, head: 3)

editorState.select(1, 3)
editorState.insert("Q")
doAssert $editorState.buffer == "aQb"
doAssert editorState.selection() == editor.Selection(anchor: 2, head: 2)
doAssert editorState.undo()
doAssert $editorState.buffer == "aZ!b"
doAssert editorState.selection() == editor.Selection(anchor: 1, head: 3)
doAssert editorState.redo()
doAssert $editorState.buffer == "aQb"

editorState.readOnly = true
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "ignored"))
doAssert native.frame()
doAssert $editorState.buffer == "aQb"

proc enter(text: string; language: editor.Language; caret: int;
           mods: platform.Modifiers = 0): string =
  editorState.readOnly = false
  editorState.buffer.set(text)
  editorState.buffer.setLanguage(language)
  editorState.select(caret, caret)
  discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
  doAssert native.frame()
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keyEnter, mods: mods))
  doAssert native.frame()
  $editorState.buffer

let go = editor.languageNamed("go")
let emptyPair = "func main() {}"
doAssert enter(emptyPair, go, emptyPair.len - 1) == "func main() {\n\t\n}"
doAssert editorState.cursorPos() == editor.Pos(line: 1, column: 1)
doAssert editorState.undo()
doAssert $editorState.buffer == emptyPair,
  "the automatic newline and indentation should be one undo step"

let indented = "  value"
doAssert enter(indented, go, indented.len) == "  value\n  "
let comment = "\t// note"
doAssert enter(comment, go, comment.len) == "\t// note\n\t// "
let python = "def f():"
doAssert enter(python, editor.languageNamed("python"), python.len) ==
  "def f():\n    "
doAssert enter("<", editor.languageNamed("xml"), 1) == "<\n"
doAssert enter("", nil, 0, platform.modShift) == "\n"

win.destroy()
loop.shutdown()
