import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc accessPeriod(tree: ref platform.AccessTree;
                  value: string): platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == platform.roleStepper and node.value == value:
        return node
  raise newException(AssertionDefect,
    "missing day-period stepper with value " & value)

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "localized time input"))
app.initialized = true
app.handleReady()
fake.setSystemLanguages("zh-Hans")
fake.setSystemRegion(platform.Region(locale: "zh-Hans", firstWeekday: 1,
  hourCycle: 12))
app.setLanguages("zh-Hans")
fake.step()

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
var period = accessPeriod(tree, "上午")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: period.id, action: platform.accessFocus))
doAssert native.frame()

# The first rune of the localized PM label changes the half of the day.
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput, text: "下"))
doAssert native.frame()
doAssert alarm.hour == 19 and changes == 1
tree = native.accessibility()[0]
period = accessPeriod(tree, "下午")
doAssert period.value == "下午"

win.destroy()
loop.shutdown()
