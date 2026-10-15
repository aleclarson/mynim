import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui slider test"))
app.initialized = true
app.handleReady()

var horizontal = 10.0
var vertical = 25.0
var horizontalChanged, verticalChanged: bool
var horizontalChanges, verticalChanges: int
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  let panel = ctx.column().size(180, 140)
    .direction(ui.Direction.RightToLeft)
  discard panel.children(proc() =
    let slider = ctx.slider(horizontal, 0, 100, 5).size(120, 24)
      .label("Horizontal")
    horizontalChanged = slider.changed()
    discard slider.onChange(proc() = inc horizontalChanges)

    let sliderV = ctx.sliderBase(vertical, 0, 100).size(24, 100)
      .paddingY(10).step(0.1).vertical().label("Vertical")
    verticalChanged = sliderV.changed()
    discard sliderV.onChange(proc() = inc verticalChanges)
  )
)
let win = newWindow(WindowOptions(width: 200, height: 150, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
doAssert tree != nil and tree.nodes.len == 2
doAssert tree.nodes[0].role == platform.roleSlider
doAssert tree.nodes[0].label == "Horizontal"
doAssert tree.nodes[0].min == 0 and tree.nodes[0].max == 100
doAssert tree.nodes[0].now == 10 and tree.nodes[0].step == 5
doAssert tree.nodes[0].actions ==
  (platform.actionFocus or platform.actionIncrement or
    platform.actionDecrement)
doAssert tree.nodes[1].step == 0.1
doAssert (tree.nodes[1].states and platform.accessVertical) ==
  platform.accessVertical

doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: tree.nodes[0].id, action: platform.accessFocus))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert horizontal == 10
doAssert native.frame()
doAssert horizontal == 15 and horizontalChanged and horizontalChanges == 1

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyPageUp))
doAssert native.frame()
doAssert horizontal == 25 and horizontalChanges == 2
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyHome))
doAssert native.frame()
doAssert horizontal == 0 and horizontalChanges == 3
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert native.frame()
doAssert horizontal == 100 and horizontalChanges == 4

tree = native.accessibility()[0]
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: tree.nodes[0].id, action: platform.accessDecrement))
doAssert horizontal == 100
doAssert native.frame()
doAssert horizontal == 95 and horizontalChanges == 5

tree = native.accessibility()[0]
let horizontalBounds = tree.nodes[0].bounds
let horizontalY = horizontalBounds.y + horizontalBounds.h / 2
let horizontalLeft = horizontalBounds.x + 10
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: horizontalLeft + 20, y: horizontalY))
doAssert horizontal == 95
doAssert native.frame()
doAssert horizontal == 80 and horizontalChanges == 6
discard native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: horizontalLeft + 70, y: horizontalY))
doAssert native.frame()
doAssert horizontal == 30 and horizontalChanges == 7
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: horizontalLeft + 80, y: horizontalY))
doAssert native.frame()
doAssert horizontal == 20 and horizontalChanges == 8

tree = native.accessibility()[0]
let verticalBounds = tree.nodes[1].bounds
let verticalX = verticalBounds.x + verticalBounds.w / 2
let verticalTop = verticalBounds.y + 10
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: verticalX, y: verticalTop))
doAssert native.frame()
doAssert vertical == 100 and verticalChanged and verticalChanges == 1
let verticalBottom = verticalBounds.y + verticalBounds.h - 10
discard native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: verticalX, y: verticalBottom))
doAssert native.frame()
doAssert vertical == 0 and verticalChanges == 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: verticalX, y: verticalBottom))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: tree.nodes[1].id, action: platform.accessIncrement))
doAssert native.frame()
doAssert abs(vertical - 0.1) < 1e-9 and verticalChanges == 3

win.destroy()
loop.shutdown()
