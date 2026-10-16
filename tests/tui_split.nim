import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc splitNode(tree: ref platform.AccessTree): platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == platform.roleSplitter and node.label == "Divider":
        return node
  raise newException(AssertionDefect, "missing splitter named Divider")

proc textNode(tree: ref platform.AccessTree; label: string):
    platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == platform.roleText and node.label == label:
        return node
  raise newException(AssertionDefect, "missing text labeled " & label)

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui split test"))
app.initialized = true
app.handleReady()

var width = 120'f32
var widthChanges = 0
var widthChanged = false
let horizontalContent = ui.newContent(proc(ctx: ui.Context) =
  var frameWidth = width
  let split = ctx.split(frameWidth,
    proc() = discard ctx.text("left"),
    proc() = discard ctx.text("right")).fill()
  widthChanged = split.changed()
  discard split.onChange(proc() = inc(widthChanges))
  if widthChanged:
    width = frameWidth
)
let horizontalWindow = newWindow(WindowOptions(width: 400, height: 200,
  hidden: true, content: horizontalContent))
let horizontal = fake.windows[^1].surface

doAssert horizontal.frame()
doAssert horizontal.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = horizontal.accessibility()[0]
var divider = tree.splitNode()
doAssert divider.min == 40 and divider.max == 359
doAssert divider.now == 120 and divider.step == 10
doAssert (divider.actions and platform.actionIncrement) !=
  platform.AccessActions(0)
doAssert tree.textNode("right").bounds.x == 121

# Dragging preserves the point where the user grabbed the wide handle.
let grabX = divider.bounds.x + divider.bounds.w - 0.5
let centerY = divider.bounds.y + divider.bounds.h / 2
doAssert horizontal.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: grabX, y: centerY))
doAssert horizontal.frame()
doAssert width == 120
discard horizontal.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: grabX + 50, y: centerY))
doAssert horizontal.frame()
doAssert width == 170 and widthChanged and widthChanges == 1
doAssert horizontal.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: grabX + 50, y: centerY))
doAssert horizontal.frame()
doAssert width == 170 and not widthChanged

# Accessibility increments and pointer drags clamp to the current pane bounds.
tree = horizontal.accessibility()[0]
divider = tree.splitNode()
doAssert horizontal.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: divider.id, action: platform.accessIncrement))
doAssert horizontal.frame()
doAssert width == 180 and widthChanges == 2

tree = horizontal.accessibility()[0]
divider = tree.splitNode()
let centerX = divider.bounds.x + divider.bounds.w / 2
let dragY = divider.bounds.y + divider.bounds.h / 2
doAssert horizontal.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: centerX, y: dragY))
discard horizontal.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 0, y: dragY))
doAssert horizontal.frame()
doAssert width == 40 and widthChanges == 3
doAssert horizontal.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 0, y: dragY))
doAssert horizontal.frame()
doAssert horizontal.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert horizontal.frame()
doAssert width == 50 and widthChanges == 4

var height = 60'f32
var heightChanges = 0
let verticalContent = ui.newContent(proc(ctx: ui.Context) =
  var frameHeight = height
  let split = ctx.splitVertical(frameHeight,
    proc() = discard ctx.text("top"),
    proc() = discard ctx.text("bottom")).fill()
  if split.changed():
    height = frameHeight
    inc(heightChanges)
)
let verticalWindow = newWindow(WindowOptions(width: 300, height: 200,
  hidden: true, content: verticalContent))
let vertical = fake.windows[^1].surface

doAssert vertical.frame()
doAssert vertical.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
tree = vertical.accessibility()[0]
divider = tree.splitNode()
doAssert divider.min == 40 and divider.max == 159 and divider.now == 60
doAssert (divider.states and platform.accessVertical) !=
  platform.AccessStates(0)
doAssert tree.textNode("bottom").bounds.y == 61

let grabY = divider.bounds.y + divider.bounds.h - 0.5
let centerXVertical = divider.bounds.x + divider.bounds.w / 2
doAssert vertical.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: centerXVertical, y: grabY))
discard vertical.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: centerXVertical, y: grabY + 40))
doAssert vertical.frame()
doAssert height == 100 and heightChanges == 1
doAssert vertical.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: centerXVertical, y: grabY + 40))
doAssert vertical.frame()
doAssert vertical.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert vertical.frame()
doAssert height == 110 and heightChanges == 2
doAssert vertical.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyUp))
doAssert vertical.frame()
doAssert height == 100 and heightChanges == 3

var rtlWidth = 100'f32
let rtlContent = ui.newContent(proc(ctx: ui.Context) =
  let host = ctx.row().direction(ui.Direction.RightToLeft).fill()
  discard host.children(proc() =
    var frameWidth = rtlWidth
    let split = ctx.split(frameWidth,
      proc() = discard ctx.text("first"),
      proc() = discard ctx.text("second")).fill()
    if split.changed():
      rtlWidth = frameWidth
  )
)
let rtlWindow = newWindow(WindowOptions(width: 400, height: 120,
  hidden: true, content: rtlContent))
let rtl = fake.windows[^1].surface

doAssert rtl.frame()
doAssert rtl.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
tree = rtl.accessibility()[0]
divider = tree.splitNode()
doAssert tree.textNode("first").bounds.x >= 300
doAssert tree.textNode("second").bounds.x < 300
let rtlGrabX = divider.bounds.x + divider.bounds.w / 2
let rtlGrabY = divider.bounds.y + divider.bounds.h / 2
doAssert rtl.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: rtlGrabX, y: rtlGrabY))
discard rtl.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: rtlGrabX - 30, y: rtlGrabY))
doAssert rtl.frame()
doAssert rtlWidth == 130
doAssert rtl.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: rtlGrabX - 30, y: rtlGrabY))
doAssert rtl.frame()
doAssert rtl.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert rtl.frame()
doAssert rtlWidth == 140

horizontalWindow.destroy()
verticalWindow.destroy()
rtlWindow.destroy()
loop.shutdown()
