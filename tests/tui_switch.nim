import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui switch test"))
app.initialized = true
app.handleReady()

var on = true
var didFocus, didChange, valueSeen: bool
var changes: int
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().size(140, 50).children(proc() =
    let toggle = ctx.switchBase(on).size(120, 32).label("Wi-Fi")
      .onChange(proc() = inc changes)
    didFocus = toggle.focused()
    didChange = toggle.changed()
    valueSeen = on
  )
)
let win = newWindow(WindowOptions(width: 160, height: 70, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var (tree, _) = native.accessibility()
doAssert tree != nil and tree.nodes.len == 1
doAssert tree.nodes[0].role == platform.roleSwitch
doAssert tree.nodes[0].label == "Wi-Fi"
doAssert (tree.nodes[0].states and platform.accessChecked) ==
  platform.accessChecked

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert didFocus and on

discard native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
discard native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keyEnter))
doAssert on and changes == 0

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert native.frame()
doAssert on and not didChange
doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert not on and changes == 1
doAssert native.frame()
doAssert didChange and not valueSeen
tree = native.accessibility()[0]
doAssert (tree.nodes[0].states and platform.accessChecked) ==
  platform.AccessStates(0)

doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: tree.nodes[0].id, action: platform.accessPress))
doAssert on and changes == 2
doAssert native.frame()
doAssert didChange and valueSeen

tree = native.accessibility()[0]
let accessBounds = tree.nodes[0].bounds
let x = accessBounds.x + accessBounds.w / 2
let y = accessBounds.y + accessBounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: x, y: y))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: x, y: y))
doAssert not on and changes == 3
doAssert native.frame()
doAssert didChange and not valueSeen

win.destroy()
loop.shutdown()
