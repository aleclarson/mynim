import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc fixedEastFiveFromTime(time: Time): ZonedTime =
  ZonedTime(time: time, utcOffset: -5 * 60 * 60, isDst: false)

proc fixedEastFiveFromAdjTime(time: Time): ZonedTime =
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

proc focusedNode(tree: ref platform.AccessTree): platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.id == tree.focus:
        return node
  raise newException(AssertionDefect, "missing focused access node")

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui date test"))
app.initialized = true
app.handleReady()

let testZone = newTimezone("Test/UTC+05", fixedEastFiveFromTime,
  fixedEastFiveFromAdjTime)
var inputDate = dateTime(2025, mJan, 15, 14, 25, zone = testZone)
var calendarDateValue = dateTime(2025, mJan, 31, 14, 25, zone = utc())
var inputChanges, calendarChanges: int
let inputContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.dateInput(inputDate).onChange(proc() = inc inputChanges)
)
let inputWindow = newWindow(WindowOptions(width: 340, height: 140,
  hidden: true, content: inputContent))
let inputSurface = fake.windows[^1].surface

doAssert inputSurface.frame()
doAssert inputSurface.send(platform.SurfaceEvent(
    kind: platform.accessibilityOn))
var tree = inputSurface.accessibility()[0]
let dateButton = accessNode(tree, platform.rolePopUpButton, "Date")
doAssert dateButton.value.len > 0
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: dateButton.id, action: platform.accessPress))
doAssert inputSurface.frame()
tree = inputSurface.accessibility()[0]
discard accessNode(tree, platform.rolePopup, "")
let selectedDay = focusedNode(tree)
doAssert selectedDay.role == platform.roleButton
let initialFocus = tree.focus

# Arrow keys move the DateInput cursor without changing its value.
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert inputSurface.frame()
tree = inputSurface.accessibility()[0]
doAssert tree.focus != initialFocus
doAssert inputDate == dateTime(2025, mJan, 15, 14, 25, zone = testZone)
doAssert inputChanges == 0

# Enter chooses the focused day, keeps its time and zone, and closes the popup.
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keyEnter))
doAssert inputSurface.frame()
doAssert inputDate == dateTime(2025, mJan, 16, 14, 25, zone = testZone)
doAssert inputDate.timezone.name == testZone.name
doAssert inputChanges == 1
tree = inputSurface.accessibility()[0]
doAssert tree.focus == accessNode(tree, platform.rolePopUpButton, "Date").id
for node in tree.nodes:
  doAssert node.role != platform.rolePopup

# The date cells accept accessibility activation as well as Enter and Space.
let reopenedDateButton = accessNode(tree, platform.rolePopUpButton, "Date")
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: reopenedDateButton.id, action: platform.accessPress))
doAssert inputSurface.frame()
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert inputSurface.frame()
tree = inputSurface.accessibility()[0]
let nextDay = focusedNode(tree)
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: nextDay.id, action: platform.accessPress))
doAssert inputSurface.frame()
doAssert inputDate == dateTime(2025, mJan, 17, 14, 25, zone = testZone)
doAssert inputChanges == 2

tree = inputSurface.accessibility()[0]
let dateButtonForSpace = accessNode(tree, platform.rolePopUpButton, "Date")
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: dateButtonForSpace.id, action: platform.accessPress))
doAssert inputSurface.frame()
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert inputSurface.frame()
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert inputSurface.frame()
doAssert inputDate == dateTime(2025, mJan, 18, 14, 25, zone = testZone)
doAssert inputChanges == 3

# A pointer activation chooses the cursor day as well.
tree = inputSurface.accessibility()[0]
let dateButtonForPointer = accessNode(tree, platform.rolePopUpButton, "Date")
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: dateButtonForPointer.id, action: platform.accessPress))
doAssert inputSurface.frame()
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert inputSurface.frame()
tree = inputSurface.accessibility()[0]
let pointerDay = focusedNode(tree)
let pointerX = pointerDay.bounds.x + pointerDay.bounds.w / 2
let pointerY = pointerDay.bounds.y + pointerDay.bounds.h / 2
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: pointerX, y: pointerY))
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: pointerX, y: pointerY))
doAssert inputSurface.frame()
doAssert inputDate == dateTime(2025, mJan, 19, 14, 25, zone = testZone)
doAssert inputChanges == 4

# Escape dismisses the anchored calendar.
tree = inputSurface.accessibility()[0]
let dateButtonAgain = accessNode(tree, platform.rolePopUpButton, "Date")
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: dateButtonAgain.id, action: platform.accessPress))
doAssert inputSurface.frame()
doAssert inputSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEscape))
doAssert inputSurface.frame()
tree = inputSurface.accessibility()[0]
for node in tree.nodes:
  doAssert node.role != platform.rolePopup
doAssert tree.focus == accessNode(tree, platform.rolePopUpButton, "Date").id

let calendarContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.calendar(calendarDateValue)
    .onChange(proc() = inc calendarChanges)
)
let calendarWindow = newWindow(WindowOptions(width: 320, height: 520,
  hidden: true, content: calendarContent))
let calendarSurface = fake.windows[^1].surface
doAssert calendarSurface.frame()
doAssert calendarSurface.send(platform.SurfaceEvent(
    kind: platform.accessibilityOn))
tree = calendarSurface.accessibility()[0]
var tableFound: bool
var weekdayHeaders, dayButtons: int
for node in tree.nodes:
  if node.role == platform.roleTable:
    tableFound = node.label.len > 0
  elif node.role == platform.roleColumnHeader:
    inc weekdayHeaders
  elif node.role == platform.roleButton and node.label.len > 0:
    inc dayButtons
doAssert tableFound
doAssert weekdayHeaders == 7
doAssert dayButtons == 44
doAssert calendarSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert calendarSurface.frame()

# Month paging follows Go AddDate normalization: January 31 plus one month
# lands on March 3.
doAssert calendarSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyPageDown))
doAssert calendarSurface.frame()
doAssert calendarDateValue == dateTime(2025, mMar, 3, 14, 25, zone = utc())
doAssert calendarChanges == 1

# Home and End select the first and last days of the displayed month.
doAssert calendarSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyHome))
doAssert calendarSurface.frame()
doAssert calendarDateValue == dateTime(2025, mMar, 1, 14, 25, zone = utc())
doAssert calendarSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert calendarSurface.frame()
doAssert calendarDateValue == dateTime(2025, mMar, 31, 14, 25, zone = utc())
doAssert calendarChanges == 3

# The next-month button uses the same month arithmetic as Page Down.
tree = calendarSurface.accessibility()[0]
let nextMonth = accessNode(tree, platform.roleButton, "Next month")
doAssert calendarSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: nextMonth.id, action: platform.accessPress))
doAssert calendarSurface.frame()
doAssert calendarDateValue == dateTime(2025, mMay, 1, 14, 25, zone = utc())
doAssert calendarChanges == 4

calendarWindow.destroy()
inputWindow.destroy()
loop.shutdown()
