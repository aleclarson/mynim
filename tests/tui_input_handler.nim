import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

block input_handler_dispatch:
  var events: seq[ui.InputEvent]
  var shortcuts = 0
  let view: ui.View = proc(c: ui.Context) =
    let root = c.box().key("input-handler").label("Input Handler")
      .size(120, 120)
      .focusable().autoFocus()
    discard root.onShortcut(ui.modSuper, ui.keyS, proc() = inc shortcuts)
    discard root.handleInput(proc(ev: ui.InputEvent): bool =
      events.add(ev)
      case ev.kind
      of ui.InputKind.InputKeyDown:
        ev.key == ui.keyA
      of ui.InputKind.InputPointerDown, ui.InputKind.InputPointerMove,
          ui.InputKind.InputPointerUp, ui.InputKind.InputScroll,
          ui.InputKind.InputText, ui.InputKind.InputCompose:
        true
      of ui.InputKind.InputCommand:
        ev.text == "paste"
      else:
        false
    )
  let tester = ui.newTester(view, 120, 120)
  defer: tester.close()

  tester.setFocused(true)
  tester.press(10, 20)
  doAssert events[^1].kind == ui.InputKind.InputPointerDown
  doAssert events[^1].x == 10 and events[^1].y == 20
  doAssert events[^1].clicks == 1
  tester.move(140, 150)
  doAssert events[^1].kind == ui.InputKind.InputPointerMove
  doAssert events[^1].x == 140 and events[^1].y == 150
  tester.release(150, 160)
  doAssert events[^1].kind == ui.InputKind.InputPointerUp
  doAssert events[^1].x == 150 and events[^1].y == 160

  tester.keyDown(ui.keyA)
  doAssert events[^1].kind == ui.InputKind.InputKeyDown
  doAssert events[^1].key == ui.keyA
  tester.keyUp(ui.keyA)
  doAssert events[^1].kind == ui.InputKind.InputKeyUp

  tester.keyAt(ui.modCtrl, ui.keyD)
  doAssert events[^2].kind == ui.InputKind.InputKeyDown
  doAssert events[^2].key == ui.keyD and events[^2].physicalKey == ui.keyD
  doAssert events[^1].kind == ui.InputKind.InputKeyUp
  doAssert events[^1].key == ui.keyD and events[^1].physicalKey == ui.keyD

  let keyDownCount = events.countIt(it.kind == ui.InputKind.InputKeyDown)
  tester.key(ui.modSuper, ui.keyS)
  doAssert shortcuts == 1
  doAssert events.countIt(it.kind == ui.InputKind.InputKeyDown) == keyDownCount

  tester.move(15, 25)
  tester.scroll(15, 25, 2, 3)
  doAssert events[^1].kind == ui.InputKind.InputScroll
  doAssert events[^1].x == 15 and events[^1].y == 25
  doAssert events[^1].dx == 2 and events[^1].dy == 3

  tester.typeText("hello")
  doAssert events[^1].kind == ui.InputKind.InputText
  doAssert events[^1].text == "hello"
  tester.compose("かな", 1)
  doAssert events[^1].kind == ui.InputKind.InputCompose
  doAssert events[^1].text == "かな" and events[^1].caret == 1

  let commandCount = events.countIt(it.kind == ui.InputKind.InputCommand)
  tester.command("pasteAndMatchStyle")
  doAssert events.countIt(it.kind == ui.InputKind.InputCommand) == commandCount + 2
  doAssert events[^2].text == "pasteAndMatchStyle"
  doAssert events[^1].text == "paste"

  tester.press(10, 20)
  let pointerUpsBeforeBlur = events.countIt(
    it.kind == ui.InputKind.InputPointerUp)
  tester.setFocused(false)
  doAssert events.countIt(it.kind == ui.InputKind.InputPointerUp) ==
    pointerUpsBeforeBlur + 1
  tester.release(10, 20)
  doAssert events.countIt(it.kind == ui.InputKind.InputPointerUp) ==
    pointerUpsBeforeBlur + 1

block transformed_input_coordinates:
  var seen: ui.InputEvent
  let tester = ui.newTester(proc(c: ui.Context) =
    discard c.box().size(40, 30).transformOrigin(0, 0).scale(2, 2)
      .translate(30, 20).handleInput(proc(ev: ui.InputEvent): bool =
        seen = ev
        true
      )
  , 150, 100)
  defer: tester.close()

  tester.press(40, 30)
  doAssert seen.kind == ui.InputKind.InputPointerDown
  doAssert abs(seen.x - 5) < 0.001 and abs(seen.y - 5) < 0.001
  tester.scroll(40, 30, 4, 6)
  doAssert seen.kind == ui.InputKind.InputScroll
  doAssert abs(seen.dx - 2) < 0.001 and abs(seen.dy - 3) < 0.001

block disabled_input_handler:
  var calls = 0
  let tester = ui.newTester(proc(c: ui.Context) =
    discard c.box().size(60, 40).disabled().handleInput(
      proc(ev: ui.InputEvent): bool =
        inc calls
        true
    )
  , 80, 60)
  defer: tester.close()

  tester.setFocused(true)
  tester.press(10, 10)
  tester.keyDown(ui.keyA)
  doAssert calls == 0

block capture_ends_when_handler_is_removed:
  var listening = true
  var events: seq[ui.InputKind]
  let tester = ui.newTester(proc(c: ui.Context) =
    let root = c.box().key("removable-input-handler").size(60, 40)
    if listening:
      discard root.handleInput(proc(ev: ui.InputEvent): bool =
        events.add(ev.kind)
        true
      )
  , 80, 60)
  defer: tester.close()

  tester.press(10, 10)
  doAssert events == @[ui.InputKind.InputPointerDown]
  listening = false
  tester.frame()
  tester.move(12, 12)
  tester.release(12, 12)
  doAssert events == @[ui.InputKind.InputPointerDown]

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui input handler test"))
app.initialized = true
app.handleReady()

var selectedRange = (-1, -1)
let inputContent = ui.newContent(proc(c: ui.Context) =
  discard c.box().size(120, 40).label("Input select target")
    .handleInput(proc(ev: ui.InputEvent): bool =
      if ev.kind == ui.InputKind.InputSelect:
        selectedRange = (ev.start, ev.`end`)
      false
    )
)
let win = newWindow(WindowOptions(width: 140, height: 60, hidden: true,
  content: inputContent))
let native = fake.windows[^1].surface
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var selectId = 0'u64
for node in native.accessibility()[0].nodes:
  if node.label == "Input select target":
    selectId = node.id
doAssert selectId != 0
discard native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: selectId, action: platform.accessSelectText, `from`: 2, to: 5))
doAssert selectedRange == (2, 5)
doAssert native.frame()

win.destroy()
loop.shutdown()
