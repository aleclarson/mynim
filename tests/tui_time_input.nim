import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc fixedWestFiveFromTime(time: Time): ZonedTime =
  ZonedTime(time: time, utcOffset: -5 * 60 * 60, isDst: false)

proc fixedWestFiveFromAdjTime(time: Time): ZonedTime =
  ZonedTime(time: time + initDuration(hours = -5),
    utcOffset: -5 * 60 * 60, isDst: false)

proc accessNode(tree: ref platform.AccessTree; role: platform.AccessRole;
                label: string): platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == role and node.label == label:
        return node
  raise newException(AssertionDefect,
    "missing access node " & $role & " labeled " & label)

proc press[T](surface: T; key: platform.Key) =
  doAssert surface.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: key))
  doAssert surface.frame()

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui time input test"))
app.initialized = true
app.handleReady()

fake.setSystemLanguages("en-GB")
fake.setSystemRegion(platform.Region(locale: "en-GB", firstWeekday: 1,
  hourCycle: 24))
let zone = newTimezone("Test/UTC-05", fixedWestFiveFromTime,
  fixedWestFiveFromAdjTime)
var alarm = dateTime(2026, mOct, 4, 7, 30, 11, 123, zone = zone)
var changes: int
var changedThisFrame: bool
let timeContent = ui.newContent(proc(ctx: ui.Context) =
  let input = ctx.timeInput(alarm).label("Alarm")
    .onChange(proc() = inc changes)
  changedThisFrame = input.changed()
)
let timeWindow = newWindow(WindowOptions(width: 320, height: 100,
  hidden: true, content: timeContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
var hours = accessNode(tree, platform.roleStepper, "Alarm hours")
var minutes = accessNode(tree, platform.roleStepper, "Alarm minutes")
doAssert hours.min == 0 and hours.max == 23 and hours.now == 7
doAssert hours.value == "07"
doAssert minutes.min == 0 and minutes.max == 59 and minutes.now == 30
doAssert minutes.value == "30"

# Arrow steps update only the selected segment and preserve date, seconds,
# nanoseconds, and timezone.
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: hours.id, action: platform.accessFocus))
doAssert native.frame()
press(native, platform.keyUp)
doAssert alarm == dateTime(2026, mOct, 4, 8, 30, 11, 123, zone = zone)
doAssert alarm.timezone.name == zone.name
doAssert changes == 1 and changedThisFrame

# Two typed digits commit the hour and move focus to minutes.
press(native, platform.key1)
press(native, platform.key5)
doAssert alarm.hour == 15, "typed hour: " & $alarm
tree = native.accessibility()[0]
hours = accessNode(tree, platform.roleStepper, "Alarm hours")
minutes = accessNode(tree, platform.roleStepper, "Alarm minutes")
doAssert tree.focus == minutes.id
press(native, platform.key4)
press(native, platform.key5)
doAssert alarm.minute == 45
doAssert alarm.second == 11 and alarm.nanosecond == 123
doAssert changes == 5

# Accessibility increment uses the same bounded segment behavior.
tree = native.accessibility()[0]
hours = accessNode(tree, platform.roleStepper, "Alarm hours")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: hours.id, action: platform.accessIncrement))
doAssert native.frame()
doAssert alarm.hour == 16 and changes == 6

timeWindow.destroy()
loop.shutdown()
