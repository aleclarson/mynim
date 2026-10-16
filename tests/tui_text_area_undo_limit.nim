import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(
  name: "ui text area undo limit test"))
app.initialized = true
app.handleReady()

var value = ""
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.textArea(value).size(180, 70).label("Document")
)
let win = newWindow(WindowOptions(width: 220, height: 100, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var fieldId = 0'u64
for node in native.accessibility()[0].nodes:
  if node.role == platform.roleTextField and node.label == "Document":
    fieldId = node.id
doAssert fieldId != 0
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: fieldId, action: platform.accessFocus))
doAssert native.frame()

for i in 0 .. 200:
  doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
    text: "x"))
  doAssert native.frame()
  if i < 200:
    doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
      key: platform.keyEnd))
    doAssert native.frame()
doAssert value.len == 201

let undoMods = when defined(macosx): platform.modSuper else: platform.modCtrl
for _ in 0 ..< 200:
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keyZ, mods: undoMods))
  doAssert native.frame()
doAssert value == "x"

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: undoMods))
discard native.frame()
doAssert value == "x"

win.destroy()
loop.shutdown()
