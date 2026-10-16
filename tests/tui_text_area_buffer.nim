import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui text area buffer test"))
app.initialized = true
app.handleReady()

let buffer = ui.newTextBuffer("abc\ndef\nxyz")
var changeActions = 0
var changedValues: seq[string]
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.textAreaBuffer(buffer).size(180, 70).label("Document")
    .onChange(proc() =
      inc changeActions
      changedValues.add($buffer)
    )
)
let win = newWindow(WindowOptions(width: 220, height: 100, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
var fieldId = 0'u64
for node in tree.nodes:
  if node.role == platform.roleTextField:
    fieldId = node.id
    doAssert node.label == "Document"
    doAssert node.value == $buffer
doAssert fieldId != 0
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: fieldId, action: platform.accessFocus))
doAssert native.frame()

var textState = native.lastTextInput()
doAssert textState.active and textState.client != nil
let (allText, actual) = textState.client.textForRange(platform.TextRange(
  start: 0, `end`: high(int)))
doAssert allText == $buffer
doAssert actual.start == 0 and actual.`end` == platform.utf16Len($buffer)
let (topBounds, _, topOk) = textState.client.boundsForRange(
  platform.TextRange(start: 0, `end`: 0))
let (bottomBounds, _, bottomOk) = textState.client.boundsForRange(
  platform.TextRange(start: platform.utf16Len($buffer),
                     `end`: platform.utf16Len($buffer)))
doAssert topOk and bottomOk and bottomBounds.y > topBounds.y
let (globalTop, _, globalTopOk) = textState.client.boundsForRange(
  platform.TextRange(start: 0, `end`: 0))
doAssert globalTopOk
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  button: 0, x: globalTop.x, y: globalTop.y + globalTop.h / 2))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  button: 0, x: globalTop.x, y: globalTop.y + globalTop.h / 2))
let clickSelection = native.lastTextInput().client.selection().`range`
doAssert clickSelection.start == 0 and clickSelection.`end` == 0

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
let selection = native.lastTextInput().client.selection().`range`
doAssert selection.start == 7 and selection.`end` == 7

doAssert native.send(platform.SurfaceEvent(kind: platform.textInput, text: "Q"))
doAssert $buffer == "abc\ndefQ\nxyz"
doAssert changeActions == 0
doAssert native.frame()
doAssert changeActions == 1 and changedValues[^1] == $buffer

doAssert native.send(platform.SurfaceEvent(kind: platform.textComposition,
  text: "é", caret: 1))
doAssert $buffer == "abc\ndefQé\nxyz"
doAssert native.frame()
doAssert changeActions == 1
let (_, marked) = native.lastTextInput().client.markedRange()
doAssert marked
doAssert native.send(platform.SurfaceEvent(kind: platform.textComposition))
doAssert native.frame()
doAssert changeActions == 2

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert $buffer == "abc\ndefQé\n\nxyz"
doAssert native.frame()
doAssert changeActions == 3

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyBackspace))
doAssert $buffer == "abc\ndefQé\nxyz"
doAssert native.frame()
doAssert changeActions == 4

let selectAllMods = when defined(macosx): platform.modSuper
  else: platform.modCtrl
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyA, mods: selectAllMods))
let selected = native.lastTextInput().client.selection().`range`
doAssert selected.start == 0 and
  selected.`end` == platform.utf16Len($buffer)
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyBackspace))
doAssert $buffer == ""
doAssert native.frame()
doAssert changeActions == 5 and changedValues[^1] == ""

tree = native.accessibility()[0]
for node in tree.nodes:
  if node.id == fieldId:
    doAssert node.value == ""

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: platform.modSuper))
doAssert native.frame()
doAssert $buffer == "abc\ndefQé\nxyz"
doAssert changeActions == 6
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: platform.modSuper or platform.modShift))
doAssert native.frame()
doAssert $buffer == ""
doAssert changeActions == 7

doAssert native.send(platform.SurfaceEvent(kind: platform.textComposition,
  text: "é", caret: 1))
doAssert native.frame()
doAssert $buffer == "é"
doAssert changeActions == 7
doAssert native.send(platform.SurfaceEvent(kind: platform.textComposition))
doAssert native.frame()
doAssert changeActions == 8
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: platform.modSuper))
doAssert native.frame()
doAssert $buffer == ""
doAssert changeActions == 9
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: platform.modSuper or platform.modShift))
doAssert native.frame()
doAssert $buffer == "é"
doAssert changeActions == 10

win.destroy()
loop.shutdown()
