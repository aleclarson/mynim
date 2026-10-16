import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(
  name: "ui text input buffer undo test"))
app.initialized = true
app.handleReady()

let buffer = ui.newTextBuffer("rope")
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.textInputBuffer(buffer).label("Document")
)
let win = newWindow(WindowOptions(width: 220, height: 80, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let field = native.accessibility()[0].nodes[0]
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: field.id, action: platform.accessFocus))
doAssert native.frame()

let command = when defined(macosx): platform.modSuper else: platform.modCtrl
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "!"))
doAssert native.frame()
doAssert $buffer == "rope!"

doAssert native.send(platform.SurfaceEvent(kind: platform.surfaceCommand,
  text: "undo"))
doAssert native.frame()
doAssert $buffer == "rope"
doAssert native.send(platform.SurfaceEvent(kind: platform.surfaceCommand,
  text: "redo"))
doAssert native.frame()
doAssert $buffer == "rope!"

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyBackspace))
doAssert native.frame()
doAssert $buffer == "rope"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: command))
doAssert native.frame()
doAssert $buffer == "rope!"

win.destroy()
loop.shutdown()
