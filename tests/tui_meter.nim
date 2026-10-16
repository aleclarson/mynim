import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui meter test"))
app.initialized = true
app.handleReady()

var shownValue = 75'f64
let meterContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.meter(shownValue, 0, 100,
    ui.MeterLevels(warning: 70, critical: 90)).label("Disk usage")
)
let win = newWindow(WindowOptions(width: 220, height: 60, hidden: true,
  content: meterContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let tree = native.accessibility()[0]
doAssert tree != nil
var foundMeter = false
for node in tree.nodes:
  if node.role == platform.roleMeter and node.label == "Disk usage":
    foundMeter = true
    doAssert node.min == 0
    doAssert node.max == 100
    doAssert node.now == 75
doAssert foundMeter

doAssertRaises ValueError:
  discard ui.newContext().meter(0, 10, 0)
doAssertRaises ValueError:
  discard ui.newContext().meter(Inf, 0, 10)

win.destroy()
loop.shutdown()
