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

proc near(actual, expected: float64): bool =
  actual > expected - 0.01 and actual < expected + 0.01

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui split percent test"))
app.initialized = true
app.handleReady()

var horizontalPercent = 25'f32
var horizontalChanged = false
let horizontalContent = ui.newContent(proc(ctx: ui.Context) =
  let split = ctx.splitPercent(horizontalPercent,
    proc() = discard ctx.text("percent left"),
    proc() = discard ctx.text("percent right")).fill()
  horizontalChanged = split.changed()
)
let horizontalWindow = newWindow(WindowOptions(width: 400, height: 200,
  hidden: true, content: horizontalContent))
let horizontal = fake.windows[^1].surface

doAssert horizontal.frame()
doAssert horizontal.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = horizontal.accessibility()[0]
var divider = tree.splitNode()
doAssert divider.min == 40 and divider.max == 359
doAssert near(divider.now, 99.75)
doAssert near(tree.textNode("percent right").bounds.x, 100.75)

let grabX = divider.bounds.x + divider.bounds.w / 2
let centerY = divider.bounds.y + divider.bounds.h / 2
doAssert horizontal.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: grabX, y: centerY))
doAssert horizontal.frame()
discard horizontal.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: grabX + 50, y: centerY))
doAssert horizontal.frame()
doAssert horizontalChanged
doAssert near(horizontalPercent, 149.75 * 100 / 399)
doAssert horizontal.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: grabX + 50, y: centerY))
doAssert horizontal.frame()

doAssert horizontal.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert horizontal.frame()
doAssert near(horizontalPercent, 159.75 * 100 / 399)

var verticalPercent = 30'f32
let verticalContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.splitVerticalPercent(verticalPercent,
    proc() = discard ctx.text("percent top"),
    proc() = discard ctx.text("percent bottom")).fill()
)
let verticalWindow = newWindow(WindowOptions(width: 300, height: 200,
  hidden: true, content: verticalContent))
let vertical = fake.windows[^1].surface

doAssert vertical.frame()
doAssert vertical.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
tree = vertical.accessibility()[0]
divider = tree.splitNode()
doAssert divider.min == 40 and divider.max == 159
doAssert near(divider.now, 59.7)
doAssert (divider.states and platform.accessVertical) !=
  platform.AccessStates(0)
doAssert near(tree.textNode("percent bottom").bounds.y, 60.7)

var rtlPercent = 20'f32
let rtlContent = ui.newContent(proc(ctx: ui.Context) =
  let host = ctx.row().direction(ui.Direction.RightToLeft).fill()
  discard host.children(proc() =
    discard ctx.splitPercent(rtlPercent,
      proc() = discard ctx.text("percent rtl first"),
      proc() = discard ctx.text("percent rtl second")).fill()
  )
)
let rtlWindow = newWindow(WindowOptions(width: 400, height: 120,
  hidden: true, content: rtlContent))
let rtl = fake.windows[^1].surface

doAssert rtl.frame()
doAssert rtl.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
tree = rtl.accessibility()[0]
divider = tree.splitNode()
doAssert near(divider.now, 79.8)
doAssert tree.textNode("percent rtl first").bounds.x >= 300
doAssert tree.textNode("percent rtl second").bounds.x < 300

horizontalWindow.destroy()
verticalWindow.destroy()
rtlWindow.destroy()
loop.shutdown()
