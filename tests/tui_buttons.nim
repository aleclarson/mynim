import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui button test"))
app.initialized = true
app.handleReady()

var regularClicks, baseClicks, primaryClicks: int
var regularClicked, baseClicked, primaryClicked: bool
let buttonContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().size(220, 140).children(proc() =
    let regular = ctx.button("Run")
      .onClick(proc() = inc regularClicks)
    regularClicked = regular.clicked()
    let base = ctx.buttonBase().label("Raw action")
      .onClick(proc() = inc baseClicks)
    baseClicked = base.clicked()
    let primary = ctx.primaryButton("Save")
      .onClick(proc() = inc primaryClicks)
    primaryClicked = primary.clicked()
  )
)
let win = newWindow(WindowOptions(width: 240, height: 160, hidden: true,
  content: buttonContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let tree = native.accessibility()[0]
doAssert tree != nil
var runFound, rawFound, saveFound: bool
for node in tree.nodes:
  if node.role == platform.roleButton and node.label == "Run":
    runFound = true
  elif node.role == platform.roleButton and node.label == "Raw action":
    rawFound = true
  elif node.role == platform.roleButton and node.label == "Save":
    saveFound = true
doAssert runFound and rawFound and saveFound

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert native.frame()
doAssert regularClicks == 1 and regularClicked

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keyEnter))
doAssert native.frame()
doAssert baseClicks == 1 and baseClicked

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert native.frame()
doAssert primaryClicks == 1 and primaryClicked

win.destroy()
loop.shutdown()
