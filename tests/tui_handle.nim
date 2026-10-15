import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui handle test"))
app.initialized = true
app.handleReady()

var controlHandle: ui.Handle
var panelHandle: ui.Ref
var outsideHandle: ui.Handle
var showControl = true
var focusedDuringBuild, focusWithinDuringBuild, resolvedDuringBuild: bool
var handleContext: ui.Context
var controlShortcuts, panelShortcuts: int
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  handleContext = ctx
  controlHandle.onShortcut(ctx, platform.modSuper, platform.keyK,
    proc() = inc controlShortcuts)
  if showControl:
    let panel = ctx.key("panel").column().size(80, 60)
    panelHandle.onShortcut(ctx, platform.modSuper, platform.keyK,
      proc() = inc panelShortcuts)
    panelHandle.onShortcut(ctx, platform.modSuper, platform.keyJ,
      proc() = inc panelShortcuts)
    discard panel.bindHandle(panelHandle)
    discard panel.children(proc() =
      let control = ctx.key("control").box().size(40, 20).label("Control")
        .onClick(proc() = discard)
      discard control.bindHandle(controlHandle)
      focusedDuringBuild = controlHandle.focused(ctx)
      focusWithinDuringBuild = panelHandle.focusWithin(ctx)
      resolvedDuringBuild = ctx.resolve(controlHandle).valid()
    )
    let outside = ctx.key("outside").box().size(20, 20).label("Outside")
      .onClick(proc() = discard)
    discard outside.bindHandle(outsideHandle)
)
controlHandle.focus()
let win = newWindow(WindowOptions(width: 100, height: 80, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.frame()
doAssert focusedDuringBuild
doAssert focusWithinDuringBuild
doAssert resolvedDuringBuild
let firstBounds = controlHandle.bounds(handleContext)
doAssert firstBounds.w == 40 and firstBounds.h == 20
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyK, mods: platform.modSuper))
doAssert controlShortcuts == 1 and panelShortcuts == 0
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyJ, mods: platform.modSuper))
doAssert panelShortcuts == 1
doAssert not native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyK, mods: platform.modShift or platform.modSuper))
doAssert controlShortcuts == 1 and panelShortcuts == 1
outsideHandle.focus(handleContext)
doAssert native.frame()
doAssert outsideHandle.focused(handleContext)
doAssert not native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyK, mods: platform.modSuper))
doAssert controlShortcuts == 1 and panelShortcuts == 1
controlHandle.focus(handleContext)
doAssert native.frame()
discard native.send(platform.SurfaceEvent(kind: platform.surfaceBlur))
doAssert not controlHandle.focused(handleContext)
doAssert panelHandle.focusWithin(handleContext)
doAssert not native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyK, mods: platform.modSuper))
doAssert controlShortcuts == 1 and panelShortcuts == 1
discard native.send(platform.SurfaceEvent(kind: platform.surfaceFocus))
doAssert controlHandle.focused(handleContext)

showControl = false
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert not controlHandle.focused(handleContext)
doAssert controlHandle.bounds(handleContext) == ui.Rect()
doAssert not native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyK, mods: platform.modSuper))
doAssert controlShortcuts == 1 and panelShortcuts == 1

controlHandle.focus(handleContext)
doAssert native.frame()
showControl = true
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.frame()
doAssert controlHandle.focused(handleContext)
doAssert panelHandle.focusWithin(handleContext)

let secondContent = ui.newContent(proc(ctx: ui.Context) =
  let panel = ctx.key("panel").column().size(80, 60)
  discard panel.bindHandle(panelHandle)
  discard panel.children(proc() =
    let control = ctx.key("control").box().size(40, 20).label("Control")
      .onClick(proc() = discard)
    discard control.bindHandle(controlHandle)
  )
)
let secondWin = newWindow(WindowOptions(width: 100, height: 80, hidden: true,
  content: secondContent))
let secondNative = fake.windows[^1].surface
doAssert secondNative.frame()
doAssertRaises ValueError:
  controlHandle.focus()

secondWin.destroy()
controlHandle.focus()
doAssert native.frame()
win.destroy()
loop.shutdown()
