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
var springTarget = 0'f32
var springValue: float32
var springSettled: bool
var delayedTarget = 0'f32
var delayedValue: float32
var delayedSettled: bool
var dragging = true
var dragPosition = 0'f32
var dragValue: float32
var dragVelocity: float32
var playFinite = false
var finiteRun = 0'u64
var finiteValue: float32
var finiteSettled: bool
var playLoop = false
var loopValue: float32
var loopSettled: bool
var colorTarget = ui.rgba(255, 0, 0, 1)
var colorValue: ui.Color
var colorSettled: bool
var finiteFrames = @[
  ui.Keyframe(value: 0),
  ui.Keyframe(at: initDuration(milliseconds = 100), value: 10)]
let loopFrames = [
  ui.Keyframe(value: 0),
  ui.Keyframe(at: initDuration(milliseconds = 100), value: 10)]
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  let box = ctx.box()
  animatedValue = box.animate("probe", target,
    initDuration(milliseconds = 200))
  springValue = box.animate("spring", springTarget, ui.Snappy)
  springSettled = box.settled("spring")
  delayedValue = box.animate("delay", delayedTarget,
    ui.Animation(duration: initDuration(milliseconds = 120),
      delay: initDuration(milliseconds = 100)))
  delayedSettled = box.settled("delay")
  if dragging:
    dragValue = box.jump("drag", dragPosition)
  else:
    dragValue = box.spring("drag", 1, ui.SpringOptions(
      stiffness: 120, damping: 16))
    dragVelocity = box.velocity("drag")
  if playFinite:
    finiteValue = box.keyframes("finite", finiteFrames,
      ui.KeyframeOptions(run: finiteRun, repeat: 1, alternate: true,
        delay: initDuration(milliseconds = 50),
        repeatDelay: initDuration(milliseconds = 40)))
    finiteSettled = box.settled("finite")
  if playLoop:
    loopValue = box.keyframes("loop", loopFrames,
      ui.KeyframeOptions(repeat: ui.RepeatForever, alternate: true))
    loopSettled = box.settled("loop")
  colorValue = box.animateColor("color", colorTarget,
    ui.Animation(duration: initDuration(milliseconds = 180)))
  colorSettled = box.settled("color")
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

fake.setPreferences(platform.Preferences(reduceMotion: false))
springTarget = 1
delayedTarget = 1
doAssert native.frame()
doAssert springValue == 0
doAssert not springSettled
doAssert delayedValue == 0
doAssert not delayedSettled
sleep(40)
doAssert native.frame()
doAssert springValue > 0 and springValue < 1, $springValue
doAssert delayedValue == 0, $delayedValue

dragPosition = 0.5
sleep(40)
doAssert native.frame()
doAssert dragValue == 0.5
dragging = false
doAssert native.frame()
doAssert dragValue == 0.5
doAssert dragVelocity > 0, $dragVelocity

sleep(80)
doAssert native.frame()
doAssert delayedValue > 0 and delayedValue < 1, $delayedValue
sleep(180)
doAssert native.frame()
doAssert delayedValue == 1
doAssert delayedSettled

sleep(700)
doAssert native.frame()
doAssert springValue == 1
doAssert springSettled
doAssert dragValue == 1

playFinite = true
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert finiteValue == 0
doAssert not finiteSettled
sleep(70)
doAssert native.frame()
doAssert finiteValue > 0 and finiteValue < 10, $finiteValue
sleep(130)
doAssert native.frame()
doAssert finiteValue > 0 and finiteValue < 10, $finiteValue
sleep(130)
doAssert native.frame()
doAssert finiteValue == 0
doAssert finiteSettled

finiteFrames[^1].value = 20
inc finiteRun
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert finiteValue == 0
doAssert not finiteSettled
sleep(50)
doAssert native.frame()
doAssert finiteValue > 0 and finiteValue < 20, $finiteValue

playLoop = true
doAssert native.frame()
doAssert loopValue == 0
doAssert not loopSettled
sleep(80)
doAssert native.frame()
let forwardValue = loopValue
doAssert forwardValue > 0 and forwardValue < 10, $forwardValue
sleep(50)
doAssert native.frame()
doAssert loopValue < forwardValue, $loopValue
doAssert not loopSettled
fake.setPreferences(platform.Preferences(reduceMotion: true))
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert loopValue == 0
doAssert loopSettled

colorTarget = ui.rgba(0, 0, 255, 0)
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert colorValue == ui.rgba(255, 0, 0, 1)
doAssert not colorSettled
sleep(100)
doAssert native.frame()
doAssert colorValue.r >= 250 and colorValue.b <= 1
doAssert colorValue.a > 0 and colorValue.a < 255
doAssert not colorSettled
sleep(120)
doAssert native.frame()
doAssert colorValue == colorTarget
doAssert colorSettled

win.destroy()
loop.shutdown()
