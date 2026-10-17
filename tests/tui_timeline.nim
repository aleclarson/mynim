import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui timeline test"))
app.initialized = true
app.handleReady()

var timelineOptions = ui.TimelineOptions()
var requestDuplicate = false
var extendTimeline = false
var primary, secondary, labeled, colocated: float32
var sequenceFirst, sequenceSecond: float32
var growthValue: float32
var growthSettled: bool
var delayedValue, repeatDelayValue: float32
var repeatDelaySettled: bool
var alternateReducedValue: float32
var alternateReducedSettled: bool
var instantValue: float32
var instantSettled, instantArrived: bool
var builtDuration, playhead: Duration
var timelineProgress: float32
var timelineSettled, timelineArrived: bool
var elementSettled: bool
var firstSeekValue: float32
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  let box = ctx.box()
  let timeline = box.timeline("intro", timelineOptions)
  if requestDuplicate:
    discard box.timeline("intro", timelineOptions)
  primary = timeline.tween(ui.Tween(fromValue: 0, to: 10,
    duration: initDuration(milliseconds = 250)))
  timeline.label("middle", ui.atTime(initDuration(milliseconds = 50)))
  secondary = timeline.tween(ui.Tween(fromValue: 0, to: 20,
    duration: initDuration(milliseconds = 125)),
    ui.afterPrevious(initDuration(milliseconds = -125)))
  labeled = timeline.tween(ui.Tween(fromValue: 0, to: 1,
    duration: initDuration(milliseconds = 175)),
    ui.atLabel("middle", initDuration(milliseconds = 25)))
  colocated = timeline.tween(ui.Tween(fromValue: 0, to: 1,
    duration: initDuration(milliseconds = 170)),
    ui.withPrevious(initDuration(milliseconds = 5)))
  builtDuration = timeline.duration
  playhead = timeline.time
  timelineProgress = timeline.progress
  timelineSettled = timeline.settled
  timelineArrived = timeline.arrived
  elementSettled = box.settled("intro")
  let firstSeek = box.timeline("first-seek", ui.TimelineOptions(
    seek: some(initDuration(milliseconds = 50))))
  firstSeekValue = firstSeek.tween(ui.Tween(fromValue: 0, to: 10,
    duration: initDuration(milliseconds = 200), ease: ui.linear))
  let growth = box.timeline("growth")
  let growthDuration = if extendTimeline: 400 else: 200
  growthValue = growth.tween(ui.Tween(fromValue: 0, to: 100,
    duration: initDuration(milliseconds = growthDuration), ease: ui.linear))
  growthSettled = growth.settled
  let delayed = box.timeline("delay", ui.TimelineOptions(
    delay: initDuration(milliseconds = 100)))
  delayedValue = delayed.tween(ui.Tween(fromValue: 0, to: 1,
    duration: initDuration(milliseconds = 300), ease: ui.linear))
  let repeated = box.timeline("repeat-delay", ui.TimelineOptions(
    repeat: 1, repeatDelay: initDuration(milliseconds = 400)))
  repeatDelayValue = repeated.tween(ui.Tween(fromValue: 0, to: 1,
    duration: initDuration(milliseconds = 100), ease: ui.linear))
  repeatDelaySettled = repeated.settled
  let alternateReduced = box.timeline("alternate-reduced",
    ui.TimelineOptions(repeat: 1, alternate: true))
  alternateReducedValue = alternateReduced.tween(ui.Tween(fromValue: 0, to: 1,
    duration: initDuration(milliseconds = 100), ease: ui.linear))
  alternateReducedSettled = alternateReduced.settled
  let sequence = box.timeline("sequence")
  sequenceFirst = sequence.tween(ui.Tween(fromValue: 0, to: 1,
    duration: initDuration(milliseconds = 100), ease: ui.linear))
  sequenceSecond = sequence.tween(ui.Tween(fromValue: 0, to: 1,
    duration: initDuration(milliseconds = 100), ease: ui.linear))
  let instant = box.timeline("instant")
  instantValue = instant.tween(ui.Tween(fromValue: 0, to: 1))
  instantSettled = instant.settled
  instantArrived = instant.arrived
)
let win = newWindow(WindowOptions(width: 200, height: 80, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface
proc frame() =
  discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
  doAssert native.frame()

frame()
doAssert builtDuration == initDuration(milliseconds = 250)
doAssert playhead == DurationZero
doAssert not timelineSettled
doAssert primary == 0
doAssert secondary == 0
doAssert firstSeekValue == 2.5'f32
doAssert sequenceFirst == 0 and sequenceSecond == 0
doAssert instantValue == 1
doAssert not instantSettled
doAssert delayedValue == 0

sleep(60)
frame()
doAssert primary > 0 and primary < 10
doAssert secondary == 0
doAssert firstSeekValue == 2.5'f32
doAssert instantSettled
doAssert instantArrived

sleep(100)
frame()
doAssert secondary > 0 and secondary < 20
doAssert labeled > 0 and labeled < 1,
  "labeled=" & $labeled & " at " & $playhead
doAssert colocated > 0 and colocated < 1,
  "colocated=" & $colocated & " at " & $playhead
doAssert sequenceFirst == 1
doAssert sequenceSecond > 0 and sequenceSecond < 1
doAssert delayedValue > 0 and delayedValue < 1
doAssert repeatDelayValue == 1
doAssert not repeatDelaySettled

timelineOptions.seek = some(initDuration(milliseconds = 125))
frame()
doAssert playhead == initDuration(milliseconds = 125)
doAssert timelineProgress == 0.5'f32
doAssert secondary == 0

timelineOptions.seek = none(Duration)
timelineOptions.paused = true
frame()
sleep(40)
frame()
doAssert playhead == initDuration(milliseconds = 125)

timelineOptions.paused = false
timelineOptions.reverse = true
frame()
sleep(60)
frame()
doAssert playhead < initDuration(milliseconds = 125)
sleep(80)
frame()
doAssert playhead == DurationZero
doAssert timelineSettled
doAssert timelineArrived
doAssert elementSettled

timelineOptions.reverse = false
timelineOptions.run = 1
frame()
doAssert playhead == DurationZero
doAssert not timelineSettled
sleep(300)
frame()
doAssert playhead == initDuration(milliseconds = 250)
doAssert timelineSettled
doAssert elementSettled
doAssert timelineArrived

extendTimeline = true
frame()
doAssert growthValue > 49 and growthValue < 51
doAssert not growthSettled
doAssert not timelineArrived
sleep(80)
frame()
doAssert growthValue > 50 and growthValue < 100
doAssert not growthSettled

timelineOptions.run = 2
timelineOptions.repeat = 1
timelineOptions.alternate = true
frame()
sleep(170)
frame()
let beforeAlternate = primary
sleep(180)
frame()
doAssert primary < beforeAlternate
doAssert not timelineSettled

fake.setPreferences(platform.Preferences(reduceMotion: true))
timelineOptions.run = 3
timelineOptions.repeat = 0
timelineOptions.alternate = false
frame()
doAssert primary == 10
doAssert timelineSettled
doAssert alternateReducedValue == 0
doAssert alternateReducedSettled

timelineOptions.run = 4
timelineOptions.seek = some(initDuration(milliseconds = 50))
frame()
doAssert playhead == initDuration(milliseconds = 50)
doAssert primary > 0 and primary < 10
doAssert not timelineSettled

timelineOptions.seek = none(Duration)
frame()
doAssert primary == 10
doAssert timelineSettled

doAssertRaises ValueError:
  discard ui.timeline(default(ui.Element), "invalid",
    ui.TimelineOptions(repeat: -2))
doAssertRaises ValueError:
  discard ui.timeline(default(ui.Element), "invalid", ui.TimelineOptions(
    seek: some(DurationZero), progress: some(0'f32)))
doAssertRaises ValueError:
  discard ui.tween(nil, ui.Tween(fromValue: 0, to: 1,
    duration: initDuration(milliseconds = -1)))

requestDuplicate = true
doAssertRaises ValueError:
  frame()

win.destroy()
loop.shutdown()
