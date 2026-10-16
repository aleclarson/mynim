import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui text area test"))
app.initialized = true
app.handleReady()

var areaText = "abc\ndef\nxyz"
var baseText = "base\nvalue"
var emptyText = ""
var changeActions = 0
var changedValues: seq[string]
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.textArea(areaText).size(180, 70).label("Document")
    .placeholder("Document hint")
    .onChange(proc() =
      inc changeActions
      changedValues.add(areaText)
    )
  discard ctx.textAreaBase(baseText).size(180, 50).label("Base")
  discard ctx.textArea(emptyText).size(180, 50).label("Empty")
    .placeholder("Write something")
)
let win = newWindow(WindowOptions(width: 220, height: 150, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var fieldId = 0'u64
for node in native.accessibility()[0].nodes:
  if node.role == platform.roleTextField and node.label == "Document":
    fieldId = node.id
    doAssert node.value == areaText
    doAssert node.placeholder == "Document hint"
  if node.role == platform.roleTextField and node.label == "Empty":
    doAssert node.value.len == 0
    doAssert node.placeholder == "Write something"
doAssert fieldId != 0
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: fieldId, action: platform.accessFocus))
doAssert native.frame()

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput, text: "Q"))
doAssert areaText == "abc\ndef\nxyz"
doAssert changeActions == 0
doAssert native.frame()
doAssert areaText == "abc\ndef\nxyQz"
doAssert changeActions == 1 and changedValues[^1] == areaText

doAssert native.send(platform.SurfaceEvent(kind: platform.textComposition,
  text: "é", caret: 1))
doAssert areaText == "abc\ndef\nxyQz"
doAssert native.frame()
doAssert areaText == "abc\ndef\nxyQz"
doAssert changeActions == 1
doAssert native.send(platform.SurfaceEvent(kind: platform.textComposition))
doAssert native.frame()
doAssert areaText == "abc\ndef\nxyQéz"
doAssert changeActions == 2 and changedValues[^1] == areaText

areaText = "external\nreplacement"
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
let textState = native.lastTextInput()
doAssert textState.text == areaText
doAssert changeActions == 2
doAssert baseText == "base\nvalue"

win.destroy()
loop.shutdown()
