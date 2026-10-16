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

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui search field test"))
app.initialized = true
app.handleReady()

var query = ""
var changes, submits: int
var dialogOpen = true
var changedThisFrame = false
let searchContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().size(300, 180).children(proc() =
    discard ctx.button("Before")
    let search = ctx.searchField(query).label("Search mail").width(240)
      .onChange(proc() = inc changes)
      .onSubmit(proc() = inc submits)
    changedThisFrame = search.changed()
    discard ctx.button("After")
  )
  ctx.onShortcut(0, platform.keyEscape, proc() = dialogOpen = false)
)
let searchWindow = newWindow(WindowOptions(width: 320, height: 200,
  hidden: true, content: searchContent))
let native = fake.windows[^1].surface
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
doAssert tree != nil
let searchNode = accessNode(tree, platform.roleTextField, "Search mail")
doAssert (searchNode.states and platform.accessSearch) !=
  platform.AccessStates(0)

# The clear action is absent when empty, and the input is the second Tab stop.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.focus == searchNode.id

doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "invoice"))
doAssert native.frame()
doAssert query == "invoice" and changes > 0 and changedThisFrame
tree = native.accessibility()[0]
let clearNode = accessNode(tree, platform.roleButton, "Clear")
let afterNode = accessNode(tree, platform.roleButton, "After")

# The clear action stays out of Tab order while remaining accessible.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.focus == afterNode.id
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab, mods: platform.modShift))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.focus == searchNode.id

# Clicking Clear empties the query, reports a change, and retains input focus.
let clearX = clearNode.bounds.x + clearNode.bounds.w / 2
let clearY = clearNode.bounds.y + clearNode.bounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: clearX, y: clearY))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: clearX, y: clearY))
doAssert native.frame()
doAssert query == "" and changes >= 2 and changedThisFrame
tree = native.accessibility()[0]
doAssert tree.focus == searchNode.id

# Escape clears nonempty text first, then reaches the root shortcut when empty.
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput, text: "x"))
doAssert native.frame()
doAssert query == "x"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEscape))
doAssert native.frame()
doAssert query == "" and dialogOpen

doAssert native.send(platform.SurfaceEvent(kind: platform.textInput, text: "q"))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
discard native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keyEnter))
doAssert native.frame()
doAssert submits == 1

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEscape))
doAssert native.frame()
doAssert query == "" and dialogOpen
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEscape))
doAssert native.frame()
doAssert not dialogOpen

searchWindow.destroy()
loop.shutdown()
