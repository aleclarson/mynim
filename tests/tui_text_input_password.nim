import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(
  name: "ui text input password test"))
app.initialized = true
app.handleReady()

var value = "páss🔑"
var areaValue = "private note"
var secure = true
var changes = 0
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  let input = ctx.textInput(value).label("Password").onChange(proc() =
    inc changes
  )
  if secure:
    discard input.password()
  discard ctx.textArea(areaValue).label("Area").size(180, 60).password()
)
let win = newWindow(WindowOptions(width: 220, height: 180, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var passwordId = 0'u64
for node in native.accessibility()[0].nodes:
  if node.label == "Password":
    passwordId = node.id
    let mask = repeat("•", platform.utf16Len(value))
    doAssert node.value == mask
    doAssert (node.states and platform.accessPassword) !=
      platform.AccessStates(0)
  if node.label == "Area":
    doAssert node.value == areaValue
    doAssert (node.states and platform.accessPassword) ==
      platform.AccessStates(0)
doAssert passwordId != 0

doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: passwordId, action: platform.accessFocus))
doAssert native.frame()
let mask = repeat("•", platform.utf16Len(value))
doAssert native.lastTextInput().text == mask

let command = when defined(macosx): platform.modSuper else: platform.modCtrl
fake.clipboardData = transfer.textData("keep this")
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyA, mods: command))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyC, mods: command))
doAssert native.send(platform.SurfaceEvent(kind: platform.surfaceCommand,
  text: "copy"))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyX, mods: command))
doAssert native.send(platform.SurfaceEvent(kind: platform.surfaceCommand,
  text: "cut"))
doAssert native.frame()
doAssert value == "páss🔑"
let copied = fake.clipboardData.read(transfer.Text)
doAssert copied.err == nil and
  transfer.bytesToString(copied.data) == "keep this"

doAssert native.send(platform.SurfaceEvent(kind: platform.textComposition,
  text: "x"))
doAssert native.frame()
doAssert changes == 0
doAssert not (value in native.lastTextInput().text)
discard native.send(platform.SurfaceEvent(kind: platform.textComposition))
doAssert native.frame()
doAssert changes == 1
doAssert not (value in native.lastTextInput().text)

secure = false
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
for node in native.accessibility()[0].nodes:
  if node.label == "Password":
    doAssert node.value == value
    doAssert (node.states and platform.accessPassword) ==
      platform.AccessStates(0)
doAssert value in native.lastTextInput().text

win.destroy()
loop.shutdown()
