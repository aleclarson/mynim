import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(
  name: "ui text area clipboard test"))
app.initialized = true
app.handleReady()

var text = "hello world"
var pasted: seq[string]
var intercepted = 0
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.textArea(text).size(180, 70).label("Document").onPaste(
    proc(value: string): bool =
      pasted.add(value)
      if value.len > 5:
        inc intercepted
        true
      else:
        false
  )
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

let command = when defined(macosx): platform.modSuper else: platform.modCtrl
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
fake.clipboardData = transfer.textData("!")
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyV, mods: command))
doAssert native.frame()
doAssert text == "hello world!"

fake.clipboardData = transfer.textData("a large block")
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyV, mods: command))
doAssert native.frame()
doAssert text == "hello world!"
doAssert intercepted == 1

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyA, mods: command))
doAssert native.frame()
let selected = native.lastTextInput().client.selection().`range`
doAssert selected.start == 0 and selected.`end` == platform.utf16Len(text)
doAssert native.send(platform.SurfaceEvent(kind: platform.surfaceCommand,
  text: "paste"))
doAssert native.frame()
doAssert text == "hello world!"
doAssert intercepted == 2
let stillSelected = native.lastTextInput().client.selection().`range`
doAssert stillSelected == selected

doAssert native.send(platform.SurfaceEvent(kind: platform.surfaceCommand,
  text: "delete"))
doAssert native.frame()
doAssert text == ""
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: command))
doAssert native.frame()
doAssert text == "hello world!"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: command))
doAssert native.frame()
doAssert text == "hello world"

fake.clipboardData = transfer.textData("")
doAssert native.send(platform.SurfaceEvent(kind: platform.surfaceCommand,
  text: "paste"))
doAssert native.frame()
doAssert text == "hello world"
doAssert pasted == @["!", "a large block", "a large block", ""]

doAssert native.send(platform.SurfaceEvent(kind: platform.surfaceCommand,
  text: "selectAll"))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyC, mods: command))
let copied = fake.clipboardData.read(transfer.Text)
doAssert copied.err == nil and transfer.bytesToString(copied.data) == text
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyX, mods: command))
doAssert native.frame()
doAssert text == ""
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: command))
doAssert native.frame()
doAssert text == "hello world"

win.destroy()
loop.shutdown()
