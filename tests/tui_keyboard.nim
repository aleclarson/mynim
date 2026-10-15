import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui keyboard test"))
app.initialized = true
app.handleReady()

var firstFocused, firstVisible, firstPressed, firstClicked: bool
var secondFocused, secondVisible, secondPressed: bool
var customFocused, customVisible: bool
var firstActivations, secondActivations: int
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().size(80, 80).children(proc() =
    let first = ctx.box().size(60, 30).label("First")
      .onClick(proc() = inc firstActivations)
    firstFocused = first.focused()
    firstVisible = first.focusVisible()
    firstPressed = first.pressed()
    firstClicked = first.clicked()
    let second = ctx.box().size(60, 30).label("Second")
      .onClick(proc() = inc secondActivations)
    secondFocused = second.focused()
    secondVisible = second.focusVisible()
    secondPressed = second.pressed()
    let custom = ctx.box().size(60, 30).label("Custom focus")
      .focusable()
    customFocused = custom.focused()
    customVisible = custom.focusVisible()
  )
)
let win = newWindow(WindowOptions(width: 100, height: 100, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let (initialTree, _) = native.accessibility()
doAssert initialTree != nil and initialTree.focus == 0
doAssert initialTree.nodes.len == 3
doAssert initialTree.nodes[2].role == platform.roleGroup
doAssert initialTree.nodes[2].states == platform.accessFocusable
doAssert initialTree.nodes[2].actions == platform.actionFocus

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert firstFocused and firstVisible and not secondFocused
let (firstTree, _) = native.accessibility()
doAssert firstTree.focus == firstTree.nodes[0].id

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace, repeat: true))
doAssert native.frame()
doAssert firstPressed and not firstClicked and firstActivations == 0
doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert native.frame()
doAssert firstClicked and not firstPressed and firstActivations == 1

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert secondFocused and secondVisible and not firstFocused
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab, mods: platform.modShift))
doAssert native.frame()
doAssert firstFocused and firstVisible and not secondFocused

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert secondFocused and secondVisible
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert native.frame()
doAssert secondPressed and secondVisible
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 10, y: 40))
doAssert native.frame()
doAssert secondFocused and secondPressed and not secondVisible
doAssert not native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert secondActivations == 0
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 10, y: 40))
doAssert native.frame()
doAssert secondActivations == 1

let (focusedTree, _) = native.accessibility()
doAssert focusedTree.focus == focusedTree.nodes[1].id
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: focusedTree.nodes[0].id, action: platform.accessFocus))
doAssert native.frame()
doAssert firstFocused and not firstVisible
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert secondFocused and secondVisible
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert customFocused and customVisible

win.destroy()
loop.shutdown()
