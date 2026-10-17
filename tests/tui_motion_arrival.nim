import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui motion arrival test"))
app.initialized = true
app.handleReady()

var target = 0'f32
var colorTarget = ui.rgba(255, 0, 0, 1)
var sequenceBuilt = false
var sequenceRun = 0'u64
var scalarValue, sequenceValue, timelineValue: float32
var shownColor: ui.Color
var scalarSettled, scalarArrived, colorSettled, colorArrived: bool
var sequenceSettled, sequenceArrived: bool
var timelineArrived, elementTimelineArrived: bool
var scalarArrivals: int
let sequenceFrames = [
  ui.Keyframe(value: 0),
  ui.Keyframe(at: initDuration(milliseconds = 100), value: 1)]
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  let box = ctx.box()
  scalarValue = box.animate("scalar", target, ui.Animation(
    duration: initDuration(milliseconds = 100), ease: ui.linear,
    delay: initDuration(milliseconds = 50)))
  scalarSettled = box.settled("scalar")
  scalarArrived = box.arrived("scalar")
  if scalarArrived:
    inc scalarArrivals
  shownColor = box.animateColor("color", colorTarget, ui.Animation(
    duration: initDuration(milliseconds = 200), ease: ui.linear))
  colorSettled = box.settled("color")
  colorArrived = box.arrived("color")
  if sequenceBuilt:
    sequenceValue = box.keyframes("sequence", sequenceFrames,
      ui.KeyframeOptions(run: sequenceRun,
        delay: initDuration(milliseconds = 50)))
    sequenceSettled = box.settled("sequence")
    sequenceArrived = box.arrived("sequence")
  let timeline = box.timeline("timeline")
  timelineValue = timeline.tween(ui.Tween(fromValue: 0, to: 1,
    duration: initDuration(milliseconds = 100), ease: ui.linear))
  timelineArrived = timeline.arrived
  elementTimelineArrived = box.arrived("timeline")
)
let win = newWindow(WindowOptions(width: 200, height: 80, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface
proc frame() =
  discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
  doAssert native.frame()

frame()
doAssert scalarSettled and not scalarArrived
doAssert colorSettled and not colorArrived
doAssert not timelineArrived and not elementTimelineArrived

target = 10
colorTarget = ui.rgba(0, 0, 255, 1)
sequenceBuilt = true
frame()
doAssert scalarValue == 0 and not scalarSettled and not scalarArrived
doAssert not colorSettled and not colorArrived
doAssert not sequenceSettled and not sequenceArrived

sleep(40)
frame()
doAssert scalarValue < 10 and not scalarArrived
doAssert not sequenceArrived

sleep(60)
frame()
doAssert scalarValue > 0 and scalarValue < 10
doAssert sequenceValue > 0 and sequenceValue < 1
doAssert not scalarArrived and not sequenceArrived
doAssert timelineArrived and elementTimelineArrived

sleep(60)
frame()
doAssert scalarValue == 10 and scalarSettled and scalarArrived
doAssert sequenceValue == 1 and sequenceSettled and sequenceArrived
doAssert not colorArrived
doAssert scalarArrivals == 1

frame()
doAssert not scalarArrived and not sequenceArrived
doAssert not timelineArrived and not elementTimelineArrived
doAssert scalarArrivals == 1

sleep(60)
frame()
doAssert shownColor == colorTarget and colorSettled and colorArrived

fake.setPreferences(platform.Preferences(reduceMotion: true))
target = 20
colorTarget = ui.rgba(0, 255, 0, 1)
inc sequenceRun
frame()
doAssert scalarValue == 20 and scalarSettled and scalarArrived
doAssert sequenceValue == 1 and sequenceSettled and sequenceArrived
doAssert not colorArrived

sleep(220)
frame()
doAssert shownColor == colorTarget and colorSettled and colorArrived
frame()
doAssert not colorArrived

win.destroy()
loop.shutdown()
