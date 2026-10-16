import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(
  name: "ui text input undo test"))
app.initialized = true
app.handleReady()

var value = "abc"
var uppercaseOnChange: bool
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.textInput(value).label("Name").onChange(proc() =
    if uppercaseOnChange:
      value = value.toUpperAscii()
  )
)
let win = newWindow(WindowOptions(width: 200, height: 80, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let node = native.accessibility()[0].nodes[0]
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: node.id, action: platform.accessFocus))
doAssert native.frame()

let command = when defined(macosx): platform.modSuper else: platform.modCtrl
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "d"))
doAssert native.frame()
doAssert value == "abcd"
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "e"))
doAssert native.frame()
doAssert value == "abcde"

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: command))
doAssert native.frame()
doAssert value == "abc"
doAssert native.lastTextInput().start == 3
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: command or platform.modShift))
doAssert native.frame()
doAssert value == "abcde"
doAssert native.lastTextInput().start == 5

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyBackspace))
doAssert native.frame()
doAssert value == "abcd"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: command))
doAssert native.frame()
doAssert value == "abcde"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: command or platform.modShift))
doAssert native.frame()
doAssert value == "abcd"

uppercaseOnChange = true
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "f"))
doAssert native.frame()
doAssert value == "ABCDF"
uppercaseOnChange = false
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: command))
doAssert native.frame()
doAssert value == "abcd"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: command or platform.modShift))
doAssert native.frame()
doAssert value == "ABCDF"

doAssert native.send(platform.SurfaceEvent(kind: platform.textComposition,
  text: "é"))
doAssert native.frame()
doAssert value == "ABCDFé"
discard native.send(platform.SurfaceEvent(kind: platform.textComposition))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: command))
doAssert native.frame()
doAssert value == "ABCDF"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: command or platform.modShift))
doAssert native.frame()
doAssert value == "ABCDFé"

win.destroy()
loop.shutdown()
