import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

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
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui 12-hour input test"))
app.initialized = true
app.handleReady()

var alarm = dateTime(2026, mOct, 4, 7, 30, zone = utc())
var changes: int
let timeContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.timeInput(alarm).label("Alarm")
    .onChange(proc() = inc changes)
)
let win = newWindow(WindowOptions(width: 340, height: 100,
  hidden: true, content: timeContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
var hours = accessNode(tree, platform.roleStepper, "Alarm hours")
var minutes = accessNode(tree, platform.roleStepper, "Alarm minutes")
var period = accessNode(tree, platform.roleStepper, "Alarm AM/PM")
doAssert hours.min == 1 and hours.max == 12 and hours.now == 7
doAssert hours.value == "7" and minutes.value == "30"
doAssert period.value == "AM"

# The day-period segment toggles the hour while preserving its displayed value.
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: period.id, action: platform.accessFocus))
doAssert native.frame()
press(native, platform.keyUp)
doAssert alarm.hour == 19 and changes == 1
tree = native.accessibility()[0]
period = accessNode(tree, platform.roleStepper, "Alarm AM/PM")
doAssert period.value == "PM"
press(native, platform.keyA)
doAssert alarm.hour == 7 and changes == 2

# Typed 12 selects midnight and moves focus to the minutes.
tree = native.accessibility()[0]
hours = accessNode(tree, platform.roleStepper, "Alarm hours")
minutes = accessNode(tree, platform.roleStepper, "Alarm minutes")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: hours.id, action: platform.accessFocus))
doAssert native.frame()
press(native, platform.key1)
press(native, platform.key2)
doAssert alarm.hour == 0 and changes == 4
tree = native.accessibility()[0]
minutes = accessNode(tree, platform.roleStepper, "Alarm minutes")
doAssert tree.focus == minutes.id

win.destroy()
loop.shutdown()
