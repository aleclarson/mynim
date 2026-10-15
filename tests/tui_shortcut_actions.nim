import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui shortcut actions test"))
app.initialized = true
app.handleReady()

var controlHandle: ui.Handle
var outsideHandle: ui.Handle
var showPanel = true
var rootCalls, panelCalls, elementCalls, handleCalls, contextCalls: int
var handleContext: ui.Context
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  handleContext = ctx
  controlHandle.onShortcut(ctx, platform.modSuper, platform.keyK,
    proc() = inc handleCalls)
  ctx.onShortcut(platform.modSuper, platform.keyK,
    proc() = inc rootCalls)
  if showPanel:
    let panel = ctx.key("panel").column().size(80, 60)
      .onShortcut(platform.modSuper, platform.keyK,
        proc() = inc panelCalls)
    discard panel.children(proc() =
      ctx.onShortcut(platform.modSuper, platform.keyL,
        proc() = inc contextCalls)
      let control = ctx.key("control").box().size(40, 20)
        .onClick(proc() = discard)
        .onShortcut(platform.modSuper, platform.keyJ,
          proc() = inc elementCalls)
      discard control.bindHandle(controlHandle)
    )
  let outside = ctx.key("outside").box().size(20, 20)
    .onClick(proc() = discard)
  discard outside.bindHandle(outsideHandle)
)
let win = newWindow(WindowOptions(width: 100, height: 80, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyK, mods: platform.modSuper))
doAssert rootCalls == 1 and panelCalls == 0 and handleCalls == 0

controlHandle.focus(handleContext)
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyK, mods: platform.modSuper))
doAssert handleCalls == 1 and panelCalls == 0 and rootCalls == 1
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyJ, mods: platform.modSuper))
doAssert elementCalls == 1
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyL, mods: platform.modSuper))
doAssert contextCalls == 1
doAssert not native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyJ, mods: platform.modSuper or platform.modShift))
doAssert elementCalls == 1

outsideHandle.focus(handleContext)
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyK, mods: platform.modSuper))
doAssert rootCalls == 2 and panelCalls == 0 and handleCalls == 1

showPanel = false
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert not native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyL, mods: platform.modSuper))
doAssert contextCalls == 1

win.destroy()
loop.shutdown()
