import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui text buffer input test"))
app.initialized = true
app.handleReady()

let buffer = ui.newTextBuffer("A😀B")
var textChanged, isComposing: bool
var changeActions = 0
var changedValues: seq[string]
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  let input = ctx.textInputBuffer(buffer).label("Document")
    .size(180, 34)
  textChanged = input.changed()
  isComposing = input.composing()
  discard input.onChange(proc() =
    inc changeActions
    changedValues.add($buffer)
  )
)
let win = newWindow(WindowOptions(width: 220, height: 80, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
doAssert tree != nil and tree.nodes.len == 1
doAssert tree.nodes[0].role == platform.roleTextField
doAssert tree.nodes[0].value == "A😀B"
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: tree.nodes[0].id, action: platform.accessFocus))
doAssert native.frame()

doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "X", replace: true, `from`: 1, to: 2))
doAssert $buffer == "A😀B"
doAssert changeActions == 0
doAssert native.frame()
doAssert $buffer == "AXB", "buffer after edit: " & $buffer
doAssert textChanged and not isComposing
doAssert changeActions == 1 and changedValues[^1] == "AXB"
var textState = native.lastTextInput()
doAssert textState.text == "AXB"

doAssert native.send(platform.SurfaceEvent(kind: platform.textComposition,
  text: "é", caret: 1))
doAssert native.frame()
doAssert $buffer == "AXB"
doAssert not textChanged and isComposing and changeActions == 1
discard native.send(platform.SurfaceEvent(kind: platform.textComposition))
doAssert native.frame()
doAssert $buffer == "AXéB"
doAssert textChanged and not isComposing
doAssert changeActions == 2 and changedValues[^1] == "AXéB"

buffer.replace(0, 1, "🌍")
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert native.frame()
doAssert $buffer == "🌍XéB"
textState = native.lastTextInput()
doAssert textState.text == "🌍XéB"
tree = native.accessibility()[0]
doAssert tree.nodes[0].value == "🌍XéB"

tree = native.accessibility()[0]
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: tree.nodes[0].id, action: platform.accessSetValue, text: "from access"))
doAssert $buffer == "🌍XéB"
doAssert native.frame()
doAssert $buffer == "from access"
doAssert textChanged and changeActions == 3
doAssert changedValues[^1] == "from access"

# A document edit before the next frame wins over a pending field edit.
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "pending"))
buffer.set("external")
doAssert native.frame()
doAssert $buffer == "external"
textState = native.lastTextInput()
doAssert textState.text == "external"
doAssert changedValues[^1] == "external"

win.destroy()
loop.shutdown()
