import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui animation test"))
app.initialized = true
app.handleReady()

var target = 0'f32
var animatedValue: float32
var on = false
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  animatedValue = ctx.box().animate("probe", target,
    initDuration(milliseconds = 200))
  discard ctx.switch(on).label("Enabled")
)
let win = newWindow(WindowOptions(width: 200, height: 80, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert animatedValue == 0

target = 1
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert animatedValue >= 0 and animatedValue < 1, $animatedValue
sleep(50)
doAssert native.frame()
doAssert animatedValue > 0 and animatedValue < 1
sleep(220)
doAssert native.frame()
doAssert animatedValue == 1

fake.setPreferences(platform.Preferences(reduceMotion: true))
target = 0
doAssert native.frame()
doAssert animatedValue == 0

win.destroy()
loop.shutdown()
