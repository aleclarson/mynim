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

proc indentKey(text: string; language: editor.Language; anchor, head: int;
               outdent = false): string =
  editorState.readOnly = false
  editorState.buffer.set(text)
  editorState.buffer.setLanguage(language)
  editorState.select(anchor, head)
  discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
  doAssert native.frame()
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keyTab,
    mods: if outdent: platform.modShift else: 0))
  doAssert native.frame()
  $editorState.buffer

proc commentKey(text: string; language: editor.Language; anchor, head: int):
    string =
  editorState.readOnly = false
  editorState.buffer.set(text)
  editorState.buffer.setLanguage(language)
  editorState.select(anchor, head)
  discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
  doAssert native.frame()
  let mods = when defined(macosx): platform.modSuper else: platform.modCtrl
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keySlash, mods: mods))
  doAssert native.frame()
  $editorState.buffer

proc lineKey(text: string; anchor, head: int; key: platform.Key;
             mods: platform.Modifiers): string =
  editorState.readOnly = false
  editorState.buffer.set(text)
  editorState.select(anchor, head)
  discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
  doAssert native.frame()
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: key, mods: mods))
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

let javascript = editor.languageNamed("javascript")
doAssert indentKey(" x", javascript, 1, 1) == "  x"
let outdent = "      x"
doAssert indentKey(outdent, editor.languageNamed("python"), 6, 6,
  outdent = true) == "    x"
doAssert editorState.cursor() == 4
doAssert editorState.undo()
doAssert $editorState.buffer == outdent
doAssert editorState.cursor() == 6
doAssert editorState.redo()
doAssert $editorState.buffer == "    x"
doAssert editorState.cursor() == 4
let selectedLines = "one\n\n  two"
let indentedLines = "  one\n\n    two"
doAssert indentKey(selectedLines, javascript, 0, selectedLines.len) ==
  indentedLines
doAssert editorState.selection() == editor.Selection(anchor: 0,
  head: indentedLines.len)
doAssert editorState.undo()
doAssert $editorState.buffer == selectedLines
doAssert editorState.selection() == editor.Selection(anchor: 0,
  head: selectedLines.len)
doAssert indentKey(indentedLines, javascript, 0, indentedLines.len,
  outdent = true) == selectedLines
doAssert editorState.selection() == editor.Selection(anchor: 0,
  head: selectedLines.len)

let commentSource = "\tif x {\n\t\ty()\n\t}"
let sourceStart = "\tif x {\n\t\t".len
let commented = "\tif x {\n\t// \ty()\n\t// }"
doAssert commentKey(commentSource, go, sourceStart, commentSource.len) ==
  commented
doAssert editorState.selection() == editor.Selection(
  anchor: sourceStart + 3, head: commentSource.len + 6)
doAssert editorState.undo()
doAssert $editorState.buffer == commentSource
doAssert editorState.selection() == editor.Selection(
  anchor: sourceStart, head: commentSource.len)
doAssert editorState.redo()
doAssert $editorState.buffer == commented
doAssert commentKey(commented, go, sourceStart + 3, commented.len) ==
  commentSource

let css = ".a { color: red; }"
let blockCommented = "/* " & css & " */"
doAssert commentKey(css, editor.languageNamed("css"), 0, css.len) ==
  blockCommented
doAssert editorState.selectedText() == blockCommented
doAssert commentKey(blockCommented, editor.languageNamed("css"), 0,
  blockCommented.len) == css
doAssert editorState.selectedText() == css

let lines = "one\ntwo\nthree"
doAssert lineKey(lines, 5, 5, platform.keyUp, platform.modAlt) ==
  "two\none\nthree"
doAssert editorState.cursor() == 1
doAssert editorState.undo()
doAssert $editorState.buffer == lines
doAssert editorState.cursor() == 5
doAssert editorState.redo()
doAssert $editorState.buffer == "two\none\nthree"
doAssert lineKey(lines, 5, 5, platform.keyDown, platform.modAlt) ==
  "one\nthree\ntwo"
doAssert editorState.cursor() == 11
doAssert lineKey(lines, 4, 7, platform.keyUp, platform.modAlt) ==
  "two\none\nthree"
doAssert editorState.selection() == editor.Selection(anchor: 0, head: 3)
doAssert lineKey(lines, 5, 5, platform.keyDown,
  platform.modAlt or platform.modShift) == "one\ntwo\ntwo\nthree"
doAssert editorState.cursor() == 9
doAssert editorState.undo()
doAssert $editorState.buffer == lines
doAssert editorState.cursor() == 5
doAssert editorState.redo()
doAssert $editorState.buffer == "one\ntwo\ntwo\nthree"
doAssert editorState.cursor() == 9
doAssert lineKey(lines, 4, 7, platform.keyDown,
  platform.modAlt or platform.modShift) == "one\ntwo\ntwo\nthree"
doAssert editorState.selection() == editor.Selection(anchor: 8, head: 11)
doAssert lineKey(lines, 5, 5, platform.keyUp,
  platform.modAlt or platform.modShift) == "one\ntwo\ntwo\nthree"
doAssert editorState.cursor() == 5
doAssert lineKey(lines, 1, 1, platform.keyUp, platform.modAlt) == lines
doAssert lineKey(lines, 11, 11, platform.keyDown, platform.modAlt) == lines
let unicodeLines = "😀x\néy\nz"
doAssert lineKey(unicodeLines, "😀x\né".len, "😀x\né".len,
  platform.keyUp, platform.modAlt) == "éy\n😀x\nz"
doAssert editorState.cursor() == "é".len
let deleteModifier = when defined(macosx): platform.modSuper
  else: platform.modCtrl
doAssert lineKey(lines, 5, 5, platform.keyK,
  deleteModifier or platform.modShift) == "one\nthree"
doAssert editorState.cursor() == 5
doAssert editorState.undo()
doAssert $editorState.buffer == lines
doAssert editorState.cursor() == 5
doAssert editorState.redo()
doAssert $editorState.buffer == "one\nthree"
doAssert lineKey(lines, 10, 10, platform.keyK,
  deleteModifier or platform.modShift) == "one\ntwo"
doAssert editorState.cursor() == 6
doAssert lineKey("only line", 4, 4, platform.keyK,
  deleteModifier or platform.modShift) == ""
doAssert editorState.cursor() == 0
let unicodeDelete = "αβ\n😀z\nq"
let afterEmoji = "αβ\n😀".len
doAssert lineKey(unicodeDelete, afterEmoji, afterEmoji, platform.keyK,
  deleteModifier or platform.modShift) == "αβ\nq"
doAssert editorState.cursor() == "αβ\nq".len
let joinModifier = platform.modCtrl
let joinSource = "a  \n  b\nc"
doAssert lineKey(joinSource, 1, 1, platform.keyJ, joinModifier) == "a b\nc"
doAssert editorState.cursor() == 1
doAssert editorState.undo()
doAssert $editorState.buffer == joinSource
let bracketLines = "call(\n  value\n)"
doAssert lineKey(bracketLines, 0, bracketLines.len, platform.keyJ,
  joinModifier) == "call(value)"
doAssert editorState.selection() == editor.Selection(anchor: 0, head: 11)
editorState.buffer.setLanguage(go)
doAssert lineKey("// one\n// two", 1, 1, platform.keyJ,
  joinModifier) == "// one two"
let blankJoin = "a\n  \nb"
doAssert lineKey(blankJoin, 0, blankJoin.len, platform.keyJ,
  joinModifier) == "a b"
doAssert editorState.selection() == editor.Selection(anchor: 0, head: 3)
doAssert lineKey("a\nb", 2, 2, platform.keyJ, joinModifier) == "a\nb"
doAssert lineKey("  value", 3, 3, platform.keyEnter,
  deleteModifier) == "  value\n  "
doAssert editorState.cursor() == "  value\n  ".len
doAssert editorState.undo()
doAssert $editorState.buffer == "  value"
doAssert lineKey("  value", 3, 3, platform.keyEnter,
  deleteModifier or platform.modShift) == "  \n  value"
doAssert editorState.cursor() == 2
let goBlock = "func main() {"
doAssert lineKey(goBlock, goBlock.len, goBlock.len, platform.keyEnter,
  deleteModifier) == "func main() {\n\t"
let pythonBlock = "def f():"
editorState.buffer.setLanguage(editor.languageNamed("python"))
doAssert lineKey(pythonBlock, pythonBlock.len, pythonBlock.len,
  platform.keyEnter, deleteModifier) == "def f():\n    "
editorState.buffer.setLanguage(javascript)
doAssert lineKey("  x", 1, 1, platform.keyBracketRight,
  deleteModifier) == "    x"
doAssert editorState.cursor() == 3
doAssert editorState.undo()
doAssert $editorState.buffer == "  x"
doAssert lineKey("    x", 3, 3, platform.keyBracketLeft,
  deleteModifier) == "  x"
doAssert editorState.cursor() == 1
doAssert lineKey(lines, 5, 5, platform.keyL, deleteModifier) == lines
doAssert editorState.selection() == editor.Selection(anchor: 4, head: 8)
doAssert editorState.selectedText() == "two\n"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyL, mods: deleteModifier))
doAssert native.frame()
doAssert editorState.selection() == editor.Selection(anchor: 4, head: 13)
doAssert editorState.selectedText() == "two\nthree"

let namedCommand = editor.commandNamed("toggleComment")
doAssert namedCommand.found and namedCommand.command == editor.Command.toggleComment
doAssert editor.commandName(editor.Command.noCommand) == "none"
doAssert editor.commandNamed("none").found
doAssert editor.commandNamed("notACommand").found == false
doAssert editor.defaultBindings().len > 0

editorState.buffer.set("one\ntwo")
editorState.select(5, 5)
doAssert editorState.run(editor.Command.selectLine)
doAssert editorState.selectedText() == "two"
editorState.select(5, 5)
editorState.bindings = @[
  editor.Binding(mods: deleteModifier, key: platform.keyL,
    command: editor.Command.noCommand),
  editor.Binding(key: platform.keyF1, command: editor.Command.selectLine),
  editor.Binding(key: platform.keyF2, thenKey: platform.keyF3,
    command: editor.Command.selectLine)
]
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyL, mods: deleteModifier))
doAssert native.frame()
doAssert editorState.selection() == editor.Selection(anchor: 5, head: 5),
  "NoCommand should let an app reserve a default shortcut"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyF1))
doAssert native.frame()
doAssert editorState.selectedText() == "two",
  "app bindings should run commands before platform defaults"
editorState.select(5, 5)
discard native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyF2))
doAssert native.frame()
doAssert editorState.selection() == editor.Selection(anchor: 5, head: 5),
  "the first key of a chord should wait for its second key"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyF3))
doAssert native.frame()
doAssert editorState.selectedText() == "two",
  "the second key should run the chord command"

editorState.bindings.setLen(0)
editorState.select(0, 0)
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyA, mods: deleteModifier))
doAssert native.frame()
doAssert editorState.selectedText() == "one\ntwo",
  "the platform select-all binding should select the document"

let graphemeText = "A👩‍💻e\u0301Z"
editorState.buffer.set(graphemeText)
editorState.select(graphemeText.len, graphemeText.len)
doAssert editorState.run(editor.Command.moveLeft)
doAssert editorState.cursor() == "A👩‍💻e\u0301".len
doAssert editorState.run(editor.Command.moveLeft)
doAssert editorState.cursor() == "A👩‍💻".len,
  "horizontal movement should keep emoji and combining sequences intact"
editorState.select(1, 1)
doAssert editorState.run(editor.Command.selectRight)
doAssert editorState.selectedText() == "👩‍💻"
editorState.buffer.set("one, two")
editorState.select("one, two".len, "one, two".len)
doAssert editorState.run(editor.Command.moveWordLeft)
doAssert editorState.cursor() == 5
editorState.select(0, 0)
doAssert editorState.run(editor.Command.selectWordRight)
doAssert editorState.selectedText() == "one"
editorState.select(3, 3)
doAssert editorState.run(editor.Command.moveWordRight)
doAssert editorState.cursor() == 4,
  "word navigation should stop at punctuation class boundaries"
editorState.buffer.set("first\nsecond")
editorState.select("first\nsec".len, "first\nsec".len)
doAssert editorState.run(editor.Command.moveLineStart)
doAssert editorState.cursor() == "first\n".len
doAssert editorState.run(editor.Command.selectLineEnd)
doAssert editorState.selectedText() == "second"
doAssert editorState.run(editor.Command.moveDocStart)
doAssert editorState.cursor() == 0
doAssert editorState.run(editor.Command.selectDocEnd)
doAssert editorState.selectedText() == "first\nsecond"
editorState.buffer.set("A👩‍💻e\u0301Z")
editorState.select(editorState.buffer.len(), editorState.buffer.len())
doAssert editorState.run(editor.Command.backspace)
doAssert $editorState.buffer == "A👩‍💻e\u0301"
doAssert editorState.cursor() == "A👩‍💻e\u0301".len
doAssert editorState.undo()
doAssert $editorState.buffer == "A👩‍💻e\u0301Z"
editorState.buffer.set("one, two")
editorState.select("one, two".len, "one, two".len)
doAssert editorState.run(editor.Command.deleteWordLeft)
doAssert $editorState.buffer == "one, "
editorState.buffer.set("one, two")
editorState.select(0, 0)
doAssert editorState.run(editor.Command.deleteWordRight)
doAssert $editorState.buffer == ", two"
editorState.buffer.set("first\nsecond")
editorState.select("first\nsec".len, "first\nsec".len)
doAssert editorState.run(editor.Command.deleteToLineStart)
doAssert $editorState.buffer == "first\nond"
doAssert editorState.cursor() == "first\n".len
doAssert editorState.undo()
doAssert $editorState.buffer == "first\nsecond"
editorState.select("first\nsec".len, "first\nsec".len)
doAssert editorState.run(editor.Command.deleteToLineEnd)
doAssert $editorState.buffer == "first\nsec"
editorState.buffer.set("  value")
editorState.select(2, 2)
doAssert editorState.run(editor.Command.deleteToLineStart)
doAssert $editorState.buffer == "value"
editorState.buffer.set("a\nb")
editorState.select(2, 2)
doAssert editorState.run(editor.Command.deleteToLineStart)
doAssert $editorState.buffer == "ab"
editorState.buffer.set("a\nb")
editorState.select(1, 1)
doAssert editorState.run(editor.Command.deleteToLineEnd)
doAssert $editorState.buffer == "ab"

editorState.readOnly = true
editorState.buffer.set("one\ntwo")
editorState.select(0, 0)
doAssert not editorState.run(editor.Command.deleteLine)
doAssert not editorState.run(editor.Command.backspace)
doAssert $editorState.buffer == "one\ntwo"
editorState.readOnly = false

win.destroy()
loop.shutdown()
