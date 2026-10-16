import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(
  name: "ui text area word navigation test"))
app.initialized = true
app.handleReady()

var text = "alpha, βeta_٢!\nnext"
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.textArea(text).size(180, 70).label("Document")
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

let wordMods = when defined(macosx): platform.modAlt else: platform.modCtrl
let command = when defined(macosx): platform.modSuper else: platform.modCtrl
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft, mods: wordMods))
var selection = native.lastTextInput().client.selection().`range`
doAssert selection.start == platform.utf16Len("alpha, βeta_٢!\n")
doAssert selection.start == selection.`end`

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft, mods: wordMods))
selection = native.lastTextInput().client.selection().`range`
doAssert selection.start == platform.utf16Len("alpha, ")

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight, mods: wordMods))
selection = native.lastTextInput().client.selection().`range`
doAssert selection.start == platform.utf16Len("alpha, βeta_٢")

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight, mods: wordMods or platform.modShift))
selection = native.lastTextInput().client.selection().`range`
doAssert selection.start == platform.utf16Len("alpha, βeta_٢")
doAssert selection.`end` == platform.utf16Len(text)
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyBackspace))
doAssert native.frame()
doAssert text == "alpha, βeta_٢"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: command))
doAssert native.frame()
doAssert text == "alpha, βeta_٢!\nnext"

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyBackspace, mods: wordMods))
doAssert native.frame()
doAssert text == "alpha, !\nnext"

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDelete, mods: wordMods))
doAssert native.frame()
doAssert text == "alpha, !"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyZ, mods: command))
doAssert native.frame()
doAssert text == "alpha, !\nnext"

when defined(macosx):
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keyA, mods: platform.modCtrl))
  selection = native.lastTextInput().client.selection().`range`
  doAssert selection.start == 0 and selection.`end` == 0
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keyE, mods: platform.modCtrl))
  selection = native.lastTextInput().client.selection().`range`
  doAssert selection.start == platform.utf16Len("alpha, !")
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keyA, mods: platform.modCtrl))
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keyK, mods: platform.modCtrl))
  doAssert native.frame()
  doAssert text == "\nnext"
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keyZ, mods: command))
  doAssert native.frame()
  doAssert text == "alpha, !\nnext"

text = repeat(" ", 130) & repeat("x", 300) & " end"
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft, mods: wordMods))
selection = native.lastTextInput().client.selection().`range`
doAssert selection.start == platform.utf16Len(repeat(" ", 130) &
  repeat("x", 300) & " ")
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft, mods: wordMods))
selection = native.lastTextInput().client.selection().`range`
doAssert selection.start == 130

win.destroy()
loop.shutdown()
