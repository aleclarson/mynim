import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc stepperNode(tree: ref platform.AccessTree; label: string):
    platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == platform.roleStepper and node.label == label:
        return node

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui stepper test"))
app.initialized = true
app.handleReady()

var quantity = 4.5
var changes = 0
var rightToLeftQuantity = 2.0
var rightToLeftChanges = 0
let stepperContent = ui.newContent(proc(ctx: ui.Context) =
  let row = ctx.row().gap(ctx.theme.space(2))
  discard row.children(proc() =
    discard ctx.stepper(quantity, 0, 10, 0.5).label("Quantity")
      .onChange(proc() = inc(changes))
    let rtl = ctx.row().direction(ui.Direction.RightToLeft)
    discard rtl.children(proc() =
      discard ctx.stepper(rightToLeftQuantity, 0, 4, 1).label("RTL")
        .onChange(proc() = inc(rightToLeftChanges))
    )
  )
)
let win = newWindow(WindowOptions(width: 120, height: 80, hidden: true,
  content: stepperContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
var control = tree.stepperNode("Quantity")
doAssert control.id > 0
doAssert control.min == 0 and control.max == 10
doAssert control.now == 4.5 and control.step == 0.5
doAssert control.actions ==
  (platform.actionFocus or platform.actionIncrement or
    platform.actionDecrement)

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
control = tree.stepperNode("Quantity")
doAssert tree.focus == control.id

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyUp))
doAssert native.frame()
doAssert quantity == 5 and changes == 1
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert native.frame()
doAssert quantity == 5.5 and changes == 2
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert native.frame()
doAssert quantity == 5 and changes == 3
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert native.frame()
doAssert quantity == 4.5 and changes == 4

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyHome))
doAssert native.frame()
doAssert quantity == 0 and changes == 5
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert native.frame()
doAssert quantity == 10 and changes == 6

tree = native.accessibility()[0]
control = tree.stepperNode("Quantity")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: control.id, action: platform.accessDecrement))
doAssert native.frame()
doAssert quantity == 9.5 and changes == 7
tree = native.accessibility()[0]
control = tree.stepperNode("Quantity")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: control.id, action: platform.accessIncrement))
doAssert native.frame()
doAssert quantity == 10 and changes == 8

# Pointer presses step on the pressed arrow and do not repeat on release.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyHome))
doAssert native.frame()
tree = native.accessibility()[0]
control = tree.stepperNode("Quantity")
let x = control.bounds.x + control.bounds.w / 2
let upperY = control.bounds.y + control.bounds.h / 4
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: x, y: upperY))
doAssert native.frame()
doAssert quantity == 0.5 and changes == 10
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: x, y: upperY, clicks: 1))
doAssert native.frame()
doAssert quantity == 0.5 and changes == 10

tree = native.accessibility()[0]
control = tree.stepperNode("Quantity")
let lowerY = control.bounds.y + control.bounds.h * 0.75
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: x, y: lowerY))
doAssert native.frame()
doAssert quantity == 0 and changes == 11
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: x, y: lowerY, clicks: 1))
doAssert native.frame()
doAssert quantity == 0 and changes == 11

# A held arrow repeats after 400 ms and then every 80 ms.
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: x, y: upperY))
doAssert native.frame()
doAssert quantity == 0.5 and changes == 12
sleep(500)
doAssert native.frame()
doAssert quantity == 1 and changes == 13
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: x, y: upperY, clicks: 1))
doAssert native.frame()
doAssert quantity == 1 and changes == 13

# Horizontal arrows follow the active layout direction.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
let rtlControl = tree.stepperNode("RTL")
doAssert tree.focus == rtlControl.id
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert native.frame()
doAssert rightToLeftQuantity == 1 and rightToLeftChanges == 1
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert native.frame()
doAssert rightToLeftQuantity == 2 and rightToLeftChanges == 2

doAssertRaises ValueError:
  discard ui.newContext().stepper(quantity, 10, 0, 1)
doAssertRaises ValueError:
  discard ui.newContext().stepper(quantity, 0, 10, 0)

win.destroy()
loop.shutdown()
