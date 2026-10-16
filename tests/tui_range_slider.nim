import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc accessNode(tree: ref platform.AccessTree; role: platform.AccessRole;
                label: string): platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == role and node.label == label:
        return node

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui range slider test"))
app.initialized = true
app.handleReady()

var priceMin = 20.0
var priceMax = 80.0
var changes = 0
var rtlMin = 20.0
var rtlMax = 80.0
var rtlChanges = 0
let rangeContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.rangeSlider(priceMin, priceMax, 0, 100, 10)
    .width(280).label("Price")
    .onChange(proc() = inc(changes))
  let rtl = ctx.row().direction(ui.Direction.RightToLeft)
  discard rtl.children(proc() =
    discard ctx.rangeSlider(rtlMin, rtlMax, 0, 100, 10)
      .width(280).label("RTL Price")
      .onChange(proc() = inc(rtlChanges))
  )
)
let win = newWindow(WindowOptions(width: 320, height: 180, hidden: true,
  content: rangeContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
var group = tree.accessNode(platform.roleGroup, "Price")
var lower = tree.accessNode(platform.roleSlider, "Price minimum")
var upper = tree.accessNode(platform.roleSlider, "Price maximum")
doAssert group.id > 0 and lower.id > 0 and upper.id > 0
doAssert lower.min == 0 and lower.max == 100 and lower.now == 20
doAssert upper.min == 0 and upper.max == 100 and upper.now == 80
doAssert lower.step == 10 and upper.step == 10
doAssert lower.actions ==
  (platform.actionFocus or platform.actionIncrement or
    platform.actionDecrement)

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
group = tree.accessNode(platform.roleGroup, "Price")
lower = tree.accessNode(platform.roleSlider, "Price minimum")
doAssert tree.focus == lower.id
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert native.frame()
doAssert priceMin == 30 and priceMax == 80 and changes == 1
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyHome))
doAssert native.frame()
doAssert priceMin == 0 and changes == 2
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert native.frame()
doAssert priceMin == 80 and priceMax == 80 and changes == 3
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyHome))
doAssert native.frame()
doAssert priceMin == 0 and priceMax == 80 and changes == 4

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
upper = tree.accessNode(platform.roleSlider, "Price maximum")
doAssert tree.focus == upper.id
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert native.frame()
doAssert priceMax == 70 and changes == 5
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyHome))
doAssert native.frame()
doAssert priceMax == priceMin and changes == 6
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert native.frame()
doAssert priceMax == 100 and changes == 7

tree = native.accessibility()[0]
upper = tree.accessNode(platform.roleSlider, "Price maximum")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: upper.id, action: platform.accessDecrement))
doAssert native.frame()
doAssert priceMax == 90 and changes == 8

# Track presses choose the nearest thumb and drag it without crossing the pair.
tree = native.accessibility()[0]
group = tree.accessNode(platform.roleGroup, "Price")
let xAt = proc(fraction: float64): float64 =
  group.bounds.x + group.bounds.w * fraction
let y = group.bounds.y + group.bounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: xAt(0.3), y: y))
doAssert native.frame()
doAssert priceMin == 30 and priceMax == 90 and changes == 9
discard native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: xAt(0.4), y: y))
doAssert native.frame()
doAssert priceMin == 40 and priceMax == 90 and changes == 10
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: xAt(0.4), y: y, clicks: 1))
doAssert native.frame()
doAssert priceMin == 40 and priceMax == 90 and changes == 10

doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: xAt(0.8), y: y))
doAssert native.frame()
doAssert priceMax == 80 and changes == 11
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: xAt(0.8), y: y, clicks: 1))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: xAt(0.8), y: y))
doAssert native.frame()
discard native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: xAt(0.3), y: y))
doAssert native.frame()
doAssert priceMin == 40 and priceMax == 40 and changes == 12
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: xAt(0.3), y: y, clicks: 1))
doAssert native.frame()

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
let rtlLower = tree.accessNode(platform.roleSlider, "RTL Price minimum")
doAssert tree.focus == rtlLower.id
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert native.frame()
doAssert rtlMin == 10 and rtlMax == 80 and rtlChanges == 1
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert native.frame()
doAssert rtlMin == 20 and rtlMax == 80 and rtlChanges == 2

doAssertRaises ValueError:
  discard ui.newContext().rangeSlider(priceMin, priceMax, 10, 0)
doAssertRaises ValueError:
  discard ui.newContext().rangeSlider(priceMin, priceMax, 0, 10, -1)

win.destroy()
loop.shutdown()
