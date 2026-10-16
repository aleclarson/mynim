import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui progress test"))
app.initialized = true
app.handleReady()

var value = 0.4'f64
let progressContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.progress(value).label("Download")
)
let win = newWindow(WindowOptions(width: 220, height: 60, hidden: true,
  content: progressContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
doAssert tree != nil
var foundProgress = false
for node in tree.nodes:
  if node.role == platform.roleProgress and node.label == "Download":
    foundProgress = true
    doAssert node.min == 0
    doAssert node.max == 1
    doAssert node.now == 0.4
doAssert foundProgress

# A negative value marks unknown-length activity to assistive technology.
value = -1
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
tree = native.accessibility()[0]
var foundUnknown = false
for node in tree.nodes:
  if node.role == platform.roleProgress and node.label == "Download":
    foundUnknown = true
    doAssert node.now < node.min
doAssert foundUnknown

var reversedValue = 0.25'f64
let reversedContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.progress(reversedValue, reverse = true).label("Reversed")
)
let reversedWindow = newWindow(WindowOptions(width: 220, height: 60,
  hidden: true, content: reversedContent))
let reversedSurface = fake.windows[^1].surface
fake.setPreferences(platform.Preferences(reduceMotion: true))
doAssert reversedSurface.frame()
doAssert reversedSurface.send(platform.SurfaceEvent(
  kind: platform.accessibilityOn))
tree = reversedSurface.accessibility()[0]
for node in tree.nodes:
  if node.role == platform.roleProgress and node.label == "Reversed":
    doAssert node.now == 0.25

doAssertRaises ValueError:
  discard ui.newContext().progress(Inf)

reversedWindow.destroy()
win.destroy()
loop.shutdown()
