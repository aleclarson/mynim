import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui text key test"))
app.initialized = true
app.handleReady()

var value = "draft"
var buffer = ui.newTextBuffer("buffered")
var areaValue = "area draft"
var textKeyCalls, changeActions, submitActions, shortcutActions: int
var bufferChanges, areaChanges: int
var seenText = ""
var seenKey = platform.keyUnknown
var seenMods: platform.Modifiers
var savedKey: ui.TextKey
var handledEnter = true
let command = when defined(macosx): platform.modSuper else: platform.modCtrl
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  let input = ctx.textInput(value).label("Draft").size(160, 34)
  discard input.onChange(proc() = inc changeActions)
  discard input.onSubmit(proc() = inc submitActions)
  discard input.onShortcut(command, platform.keyS,
    proc() = inc shortcutActions)
  discard input.onTextKey(proc(key: ui.TextKey): bool =
    inc textKeyCalls
    savedKey = key
    seenKey = key.key
    seenMods = key.mods
    seenText = key.text()
    if key.key == platform.keyEnter and handledEnter:
      key.setText("")
      return true
    false
  )
  let bufferInput = ctx.textInputBuffer(buffer).label("Buffer")
    .size(160, 34)
  discard bufferInput.onChange(proc() = inc bufferChanges)
  discard bufferInput.onTextKey(proc(key: ui.TextKey): bool =
    if key.key == platform.keyEnter:
      key.setText("buffer changed")
      return true
    false
  )
  let areaInput = ctx.textArea(areaValue).label("Area").size(160, 70)
  discard areaInput.onChange(proc() = inc areaChanges)
  discard areaInput.onTextKey(proc(key: ui.TextKey): bool =
    if key.key == platform.keyEnter:
      key.setText("area changed")
      return true
    false
  )
)
let win = newWindow(WindowOptions(width: 200, height: 80, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

proc textFieldId(label: string): uint64 =
  for node in native.accessibility()[0].nodes:
    if node.label == label and node.role == platform.roleTextField:
      return node.id

proc focusTextField(label: string) =
  let id = textFieldId(label)
  doAssert id != 0
  doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
    id: id, action: platform.accessFocus))
  doAssert native.frame()

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
doAssert textFieldId("Draft") != 0
doAssert textFieldId("Buffer") != 0
doAssert textFieldId("Area") != 0
focusTextField("Draft")

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert seenText == "draft"
doAssert seenKey == platform.keyEnter and seenMods == 0
doAssert textKeyCalls == 1
doAssert native.frame()
doAssert value == ""
doAssert changeActions == 1 and submitActions == 0
doAssertRaises(ValueError):
  discard savedKey.text()
doAssertRaises(ValueError):
  savedKey.setText("late")

discard native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyA))
doAssert textKeyCalls == 1
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput, text: "abc"))
doAssert native.frame()
doAssert value == "abc"
doAssert changeActions == 2

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyBackspace))
doAssert textKeyCalls == 2
doAssert seenKey == platform.keyBackspace and seenText == "abc"
doAssert native.frame()
doAssert value == "ab"
doAssert changeActions == 3

discard native.send(platform.SurfaceEvent(kind: platform.surfaceFocus))
doAssert native.frame()
discard native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyS, mods: command))
doAssert shortcutActions == 1
doAssert textKeyCalls == 2

handledEnter = false
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert textKeyCalls == 3
doAssert native.frame()
doAssert value == "ab"
doAssert submitActions == 1

focusTextField("Buffer")
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert native.frame()
doAssert buffer.slice(0, buffer.len()) == "buffer changed"
doAssert bufferChanges == 1

focusTextField("Area")
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert native.frame()
doAssert areaValue == "area changed"
doAssert areaChanges == 1

win.destroy()
loop.shutdown()
