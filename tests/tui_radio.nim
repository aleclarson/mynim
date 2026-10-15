import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

type Choice = enum
  firstChoice, secondChoice

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui radio test"))
app.initialized = true
app.handleReady()

var selected = firstChoice
var firstChanged, secondChanged: bool
var firstValueSeen, secondValueSeen: bool
var firstChanges, secondChanges: int
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().size(140, 80).children(proc() =
    let first = ctx.radioBase(selected, firstChoice).size(120, 30)
      .label("First").onChange(proc() = inc firstChanges)
    firstChanged = first.changed()
    firstValueSeen = selected == firstChoice
    let second = ctx.radioBase(selected, secondChoice).size(120, 30)
      .label("Second").onChange(proc() = inc secondChanges)
    secondChanged = second.changed()
    secondValueSeen = selected == secondChoice
  )
)
let win = newWindow(WindowOptions(width: 160, height: 100, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var (tree, _) = native.accessibility()
doAssert tree != nil and tree.nodes.len == 2
doAssert tree.nodes[0].role == platform.roleRadio
doAssert tree.nodes[1].role == platform.roleRadio
doAssert (tree.nodes[0].states and platform.accessChecked) ==
  platform.accessChecked
doAssert (tree.nodes[1].states and platform.accessChecked) ==
  platform.AccessStates(0)

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
discard native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
discard native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keyEnter))
doAssert selected == firstChoice and secondChanges == 0

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert selected == secondChoice and secondChanges == 1
doAssert native.frame()
doAssert secondChanged and secondValueSeen and not firstChanged
tree = native.accessibility()[0]
doAssert (tree.nodes[1].states and platform.accessChecked) ==
  platform.accessChecked

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert selected == secondChoice and secondChanges == 1
doAssert native.frame()
doAssert not secondChanged

tree = native.accessibility()[0]
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: tree.nodes[0].id, action: platform.accessPress))
doAssert selected == firstChoice and firstChanges == 1
doAssert native.frame()
doAssert firstChanged and firstValueSeen
tree = native.accessibility()[0]
doAssert (tree.nodes[0].states and platform.accessChecked) ==
  platform.accessChecked
doAssert (tree.nodes[1].states and platform.accessChecked) ==
  platform.AccessStates(0)

win.destroy()
loop.shutdown()
