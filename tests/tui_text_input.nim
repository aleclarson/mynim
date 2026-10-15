import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui text input test"))
app.initialized = true
app.handleReady()

var value = "A😀B"
var locked: bool
var textChanged, textSubmitted, composing: bool
var changeActions, submitActions: int
var changedValues, submittedValues: seq[string]
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  let input = ctx.textInput(value).placeholder("Name").readOnly(locked)
    .label("Name")
    .size(160, 34)
  textChanged = input.changed()
  textSubmitted = input.submitted()
  composing = input.composing()
  discard input.onChange(proc() =
    inc changeActions
    changedValues.add(value)
  )
  discard input.onSubmit(proc() =
    inc submitActions
    submittedValues.add(value)
  )
)
let win = newWindow(WindowOptions(width: 200, height: 80, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
doAssert tree != nil and tree.nodes.len == 1
doAssert tree.nodes[0].role == platform.roleTextField
doAssert tree.nodes[0].label == "Name"
doAssert tree.nodes[0].value == "A😀B"
doAssert tree.nodes[0].actions == (platform.actionFocus or platform.actionSetValue)

doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: tree.nodes[0].id, action: platform.accessFocus))
doAssert native.frame()
var textState = native.lastTextInput()
doAssert textState.active and textState.client != nil
doAssert textState.text == "A😀B"
doAssert textState.start == 3 and textState.`end` == 3

doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "X", replace: true, `from`: 1, to: 2))
doAssert value == "A😀B"
doAssert changeActions == 0
doAssert native.frame()
doAssert value == "AXB" and textChanged and not composing
doAssert changeActions == 1 and changedValues[^1] == "AXB"
textState = native.lastTextInput()
doAssert textState.text == "AXB"

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert native.frame()
textState = native.lastTextInput()
doAssert textState.start == 1 and textState.`end` == 1
doAssert not textChanged

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyBackspace))
doAssert value == "AXB"
doAssert native.frame()
doAssert value == "XB" and textChanged and changeActions == 2
doAssert changedValues[^1] == "XB"

let selectAllMods = when defined(macosx): platform.modSuper else: platform.modCtrl
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyA, mods: selectAllMods))
doAssert native.frame()
textState = native.lastTextInput()
doAssert textState.start == 0 and textState.`end` == 2
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "👍"))
doAssert native.frame()
doAssert value == "👍" and textChanged and changeActions == 3
doAssert changedValues[^1] == "👍"

doAssert native.send(platform.SurfaceEvent(kind: platform.textComposition,
  text: "é", caret: 1))
doAssert native.frame()
doAssert value == "👍é" and not textChanged and composing and changeActions == 3
discard native.send(platform.SurfaceEvent(kind: platform.textComposition))
doAssert changeActions == 3
doAssert native.frame()
doAssert value == "👍é" and textChanged and not composing and changeActions == 4
doAssert changedValues[^1] == "👍é"

tree = native.accessibility()[0]
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: tree.nodes[0].id, action: platform.accessSetValue, text: "value"))
doAssert changeActions == 4
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert submitActions == 0
doAssert native.frame()
doAssert value == "value" and textChanged and changeActions == 5
doAssert textSubmitted and submitActions == 1
doAssert submittedValues[^1] == "value"
doAssert changedValues[^1] == "value"
tree = native.accessibility()[0]
doAssert tree.nodes[0].value == "value"

let inputBounds = tree.nodes[0].bounds
let textX = inputBounds.x + 12
let textY = inputBounds.y + inputBounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: textX, y: textY))
doAssert native.frame()
textState = native.lastTextInput()
doAssert textState.start == 0 and textState.`end` == 0
discard native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: textX + 45, y: textY))
doAssert native.frame()
textState = native.lastTextInput()
doAssert textState.start == 0 and textState.`end` > 0
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: textX + 45, y: textY))
doAssert native.frame()

locked = true
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert (tree.nodes[0].states and platform.accessReadOnly) ==
  platform.accessReadOnly
doAssert (tree.nodes[0].actions and platform.actionSetValue) ==
  platform.AccessActions(0)
doAssert not native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: tree.nodes[0].id, action: platform.accessSetValue, text: "ignored"))
doAssert value == "value"

win.destroy()
loop.shutdown()
