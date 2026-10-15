import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui toggle group test"))
app.initialized = true
app.handleReady()

var bold, italic, underline: bool
var view = 1
var boldChanged, italicChanged, underlineChanged, viewChanged: int
let toggleContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().size(240, 180).children(proc() =
    discard ctx.toggle(bold, "Bold")
      .onChange(proc() = inc boldChanged)
    discard ctx.toggleGroup(proc() =
      discard ctx.toggle(italic, "Italic")
        .onChange(proc() = inc italicChanged)
      discard ctx.toggle(underline, "Underline")
        .onChange(proc() = inc underlineChanged)
    ).label("Format")
    discard ctx.segmented(view, ["List", "Grid", "Columns"])
      .label("View").onChange(proc() = inc viewChanged)
  )
)
let win = newWindow(WindowOptions(width: 260, height: 200, hidden: true,
  content: toggleContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
doAssert tree != nil
var boldFound, groupFound, italicFound, underlineFound: bool
var radioGroupFound, selectedGridFound: bool
for node in tree.nodes:
  if node.role == platform.roleToggleButton and node.label == "Bold":
    boldFound = true
  elif node.role == platform.roleGroup and node.label == "Format":
    groupFound = true
  elif node.role == platform.roleToggleButton and node.label == "Italic":
    italicFound = true
  elif node.role == platform.roleToggleButton and node.label == "Underline":
    underlineFound = true
  elif node.role == platform.roleRadioGroup and node.label == "View":
    radioGroupFound = true
  elif node.role == platform.roleRadio and node.label == "Grid" and
      (node.states and platform.accessChecked) != platform.AccessStates(0):
    selectedGridFound = true
doAssert boldFound and groupFound and italicFound and underlineFound
doAssert radioGroupFound and selectedGridFound

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert native.frame()
doAssert bold and boldChanged == 1

tree = native.accessibility()[0]
var pressedBold: bool
for node in tree.nodes:
  if node.role == platform.roleToggleButton and node.label == "Bold":
    pressedBold = (node.states and platform.accessChecked) !=
      platform.AccessStates(0)
doAssert pressedBold

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert native.frame()
doAssert underline and not italic and underlineChanged == 1
doAssert italicChanged == 0

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert native.frame()
doAssert view == 2 and viewChanged == 1

win.destroy()
loop.shutdown()
