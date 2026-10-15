import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui pointer state test"))
app.initialized = true
app.handleReady()

var hoveredState, pressedState, clickedState: bool
var activations = 0
let content = ui.newContent(proc(ctx: ui.Context) =
  let control = ctx.box().size(40, 40)
    .onClick(proc() = inc activations)
  hoveredState = control.hovered()
  pressedState = control.pressed()
  clickedState = control.clicked()
)
let win = newWindow(WindowOptions(width: 64, height: 64, hidden: true,
  content: content))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert not hoveredState and not pressedState and not clickedState

discard native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 10, y: 10))
doAssert native.frame()
doAssert hoveredState and not pressedState

doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 10, y: 10))
doAssert native.frame()
doAssert hoveredState and pressedState and not clickedState

discard native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 50, y: 50))
doAssert native.frame()
doAssert not hoveredState and not pressedState

discard native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 10, y: 10))
doAssert native.frame()
doAssert hoveredState and pressedState

doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 10, y: 10))
doAssert native.frame()
doAssert clickedState and not pressedState
doAssert activations == 1

discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert not clickedState

discard native.send(platform.SurfaceEvent(kind: platform.pointerLeave))
doAssert native.frame()
doAssert not hoveredState and not pressedState

win.destroy()
loop.shutdown()
