import std/assertions
import mynim/internal/platform as platform
import mynim/ui as ui
import mynim/ui/chart as charts

var selected = -1
var changed = false
let xs = @[0.1'f32, 0.5'f32, 0.9'f32]
let tester = ui.newTester(proc(ctx: ui.Context) =
  discard plot(ctx, charts.Axes(), proc(area: ui.Element) =
    changed = select(ctx, area, selected, xs, proc(index: int): string =
      case index
      of 0: "January: 12"
      of 1: "February: 18"
      else: "March: 24"
    )
    discard area.label("Sales chart")
  ).size(280, 160)
, 320, 200)

doAssert selected == -1
doAssert not changed
tester.keyDown(platform.keyTab)
tester.keyUp(platform.keyTab)
doAssert tester.focused("Sales chart")

tester.keyDown(platform.keyRight)
doAssert selected == 0 and changed
doAssert tester.hasText("January: 12")
doAssert tester.announcements() == @["January: 12"]

tester.keyDown(platform.keyHome)
doAssert selected == 0 and not changed
tester.keyDown(platform.keyRight)
doAssert selected == 1 and changed
doAssert tester.announcements() == @["February: 18"]
tester.keyDown(platform.keyEnd)
doAssert selected == 2 and changed
doAssert tester.announcements() == @["March: 24"]
tester.keyDown(platform.keyEscape)
doAssert selected == -1 and changed

let (areaBounds, found) = tester.find("Sales chart")
doAssert found and areaBounds.w > 0 and areaBounds.h > 0
tester.move(areaBounds.x + areaBounds.w * 0.2'f32,
  areaBounds.y + areaBounds.h / 2)
doAssert selected == 0 and changed
tester.move(areaBounds.x + areaBounds.w * 0.8'f32,
  areaBounds.y + areaBounds.h / 2)
doAssert selected == 2 and changed
doAssert tester.hasText("March: 24")
doAssert tester.announcements().len == 0

tester.move(areaBounds.x - 2, areaBounds.y + areaBounds.h / 2)
doAssert selected == -1 and changed

tester.close()
echo "chart selection tests passed"
