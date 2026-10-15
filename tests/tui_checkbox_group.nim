import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui checkbox group test"))
app.initialized = true
app.handleReady()

var email, calendar: bool
var parentChanged, childChanged: int
var groupChanged: bool
let checkboxGroupContent = ui.newContent(proc(ctx: ui.Context) =
  let group = ctx.checkboxGroup("Notifications", proc() =
    discard ctx.checkbox(email, "Email")
      .onChange(proc() = inc childChanged)
    discard ctx.checkbox(calendar, "Calendar")
      .onChange(proc() = inc childChanged)
  ).onChange(proc() = inc parentChanged)
  groupChanged = group.changed()
)
let win = newWindow(WindowOptions(width: 240, height: 160, hidden: true,
  content: checkboxGroupContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
doAssert tree != nil
var parentId: uint64
var headerFound, groupFound, emailFound, calendarFound: bool
for node in tree.nodes:
  if node.role == platform.roleCheckBox and node.label == "Notifications":
    headerFound = true
    parentId = node.id
    doAssert (node.states and (platform.accessChecked or platform.accessMixed)) ==
      platform.AccessStates(0)
  elif node.role == platform.roleGroup and node.label == "Notifications":
    groupFound = true
  elif node.role == platform.roleCheckBox and node.label == "Email":
    emailFound = true
  elif node.role == platform.roleCheckBox and node.label == "Calendar":
    calendarFound = true
doAssert headerFound and groupFound and emailFound and calendarFound

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert native.frame()
doAssert email and not calendar and childChanged == 1
doAssert not groupChanged and parentChanged == 0

tree = native.accessibility()[0]
var headerMixed, headerChecked: bool
for node in tree.nodes:
  if node.id == parentId:
    headerMixed = (node.states and platform.accessMixed) !=
      platform.AccessStates(0)
    headerChecked = (node.states and platform.accessChecked) !=
      platform.AccessStates(0)
doAssert headerMixed and not headerChecked

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab, mods: platform.modShift))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert native.frame()
doAssert email and calendar and parentChanged == 1
doAssert groupChanged
doAssert native.frame()

tree = native.accessibility()[0]
var headerFullyChecked: bool
for node in tree.nodes:
  if node.id == parentId:
    headerFullyChecked = (node.states and platform.accessChecked) !=
      platform.AccessStates(0) and
      (node.states and platform.accessMixed) == platform.AccessStates(0)
doAssert headerFullyChecked

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert native.frame()
doAssert not email and not calendar and parentChanged == 2 and groupChanged
doAssert native.frame()
tree = native.accessibility()[0]
var headerUnchecked: bool
for node in tree.nodes:
  if node.id == parentId:
    headerUnchecked = (node.states and
      (platform.accessChecked or platform.accessMixed)) ==
      platform.AccessStates(0)
doAssert headerUnchecked

win.destroy()
loop.shutdown()
