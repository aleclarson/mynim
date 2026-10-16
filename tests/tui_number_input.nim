import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc numberNode(tree: ref platform.AccessTree; label: string):
    platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == platform.roleStepper and node.label == label:
        return node
  raise newException(AssertionDefect,
    "missing spin button labeled " & label)

proc buttonNode(tree: ref platform.AccessTree; label: string):
    platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == platform.roleButton and node.label == label:
        return node
  raise newException(AssertionDefect, "missing button labeled " & label)

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui number input test"))
app.initialized = true
app.handleReady()

var quantity = 5.0
var changes = 0
var changedThisFrame = false
let numberContent = ui.newContent(proc(ctx: ui.Context) =
  var frameQuantity = quantity
  let number = ctx.numberInput(frameQuantity, 0, 9.75, 0.5).label("Count")
    .onChange(proc() = inc(changes))
  changedThisFrame = number.changed()
  if changedThisFrame:
    quantity = frameQuantity
)
let numberWindow = newWindow(WindowOptions(width: 360, height: 100,
  hidden: true, content: numberContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
var control = tree.numberNode("Count")
doAssert control.min == 0 and control.max == 9.75
doAssert control.now == 5 and control.step == 0.5
doAssert control.value == "5.0"
doAssert (control.actions and platform.actionIncrement) !=
  platform.AccessActions(0)
discard tree.buttonNode("Increase")
discard tree.buttonNode("Decrease")

# Up and Down step the value and invoke the wrapper callback once per change.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
control = tree.numberNode("Count")
doAssert tree.focus == control.id
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyUp))
doAssert native.frame()
doAssert quantity == 5.5 and changedThisFrame and changes == 1
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert native.frame()
doAssert quantity == 5 and changedThisFrame and changes == 2

# Accessibility increment and text entry use the same bounded value contract.
tree = native.accessibility()[0]
control = tree.numberNode("Count")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: control.id, action: platform.accessIncrement))
doAssert native.frame()
doAssert quantity == 5.5 and changedThisFrame and changes == 3

tree = native.accessibility()[0]
control = tree.numberNode("Count")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: control.id, action: platform.accessSetValue, text: "7.5"))
doAssert native.frame()
doAssert quantity == 7.5 and changedThisFrame and changes == 4

# Out-of-range text stays visible but does not change the numeric value.
tree = native.accessibility()[0]
control = tree.numberNode("Count")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: control.id, action: platform.accessSetValue, text: "12"))
doAssert native.frame()
doAssert quantity == 7.5 and not changedThisFrame and changes == 4

# A valid step after invalid text restores a formatted value and clamps at hi.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyUp))
doAssert native.frame()
doAssert quantity == 8 and changedThisFrame and changes == 5
tree = native.accessibility()[0]
let increaseButton = tree.buttonNode("Increase")
let x = increaseButton.bounds.x + increaseButton.bounds.w / 2
let y = increaseButton.bounds.y + increaseButton.bounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: x, y: y))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: x, y: y))
doAssert native.frame()
doAssert quantity == 8.5 and changedThisFrame and changes == 6

# Stepping reaches a non-aligned upper bound exactly, then stops.
for expected in [9.0, 9.5, 9.75]:
  tree = native.accessibility()[0]
  control = tree.numberNode("Count")
  doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
    id: control.id, action: platform.accessIncrement))
  doAssert native.frame()
  doAssert quantity == expected and changedThisFrame
doAssert changes == 9
tree = native.accessibility()[0]
control = tree.numberNode("Count")
doAssert (tree.buttonNode("Increase").states and platform.accessDisabled) !=
  platform.AccessStates(0)
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: control.id, action: platform.accessIncrement))
doAssert native.frame()
doAssert quantity == 9.75 and not changedThisFrame and changes == 9

doAssertRaises ValueError:
  discard ui.newContext().numberInput(quantity, 10, 0, 1)
doAssertRaises ValueError:
  discard ui.newContext().numberInput(quantity, 0, 10, 0)

numberWindow.destroy()
loop.shutdown()
