import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui keyed state test"))
app.initialized = true
app.handleReady()

var showLeading = false
var targetFocused = false
var targetClicks = 0
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().size(80, 100).children(proc() =
    if showLeading:
      discard ctx.box().size(80, 20).label("Leading")
        .onClick(proc() = discard)
    let panel = ctx.box().key("panel").size(80, 30)
    discard panel.children(proc() =
      let target = ctx.key(7).box().size(80, 20).label("Target")
        .onClick(proc() = inc targetClicks)
      targetFocused = target.focused()
    )
  )
)
let win = newWindow(WindowOptions(width: 100, height: 100, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert targetFocused

showLeading = true
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert targetFocused

showLeading = false
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 5))
showLeading = true
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 25))
doAssert targetClicks == 1

win.destroy()
loop.shutdown()

block duplicate_context_keys:
  let context = ui.newContext()
  doAssertRaises ValueError:
    context.build(proc(ctx: ui.Context) =
      discard ctx.key("duplicate").box()
      discard ctx.key("duplicate").box()
    )
  context.close()
