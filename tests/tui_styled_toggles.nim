import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

type SizeChoice = enum
  compactSize, comfortableSize, spaciousSize

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui styled toggle test"))
app.initialized = true
app.handleReady()

var remember, wifi: bool
var selected = comfortableSize
var checkboxChanged, radioChanged, switchChanged: int
let styledContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().size(200, 140).children(proc() =
    discard ctx.checkbox(remember, "Remember me")
      .onChange(proc() = inc checkboxChanged)
    discard ctx.radioGroup(proc() =
      let small = ctx.radio(selected, compactSize, "Compact")
        .onChange(proc() = inc radioChanged)
      let medium = ctx.radio(selected, comfortableSize, "Comfortable")
        .onChange(proc() = inc radioChanged)
      let large = ctx.radio(selected, spaciousSize, "Spacious")
        .onChange(proc() = inc radioChanged)
      discard small
      discard medium
      discard large
    ).label("Size")
    discard ctx.switch(wifi).label("Wi-Fi")
      .onChange(proc() = inc switchChanged)
  )
)
let win = newWindow(WindowOptions(width: 220, height: 160, hidden: true,
  content: styledContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
doAssert tree != nil
var hasCheckbox, hasGroup, hasSwitch, hasSelectedRadio: bool
for node in tree.nodes:
  if node.role == platform.roleCheckBox and node.label == "Remember me":
    hasCheckbox = true
  elif node.role == platform.roleRadioGroup and node.label == "Size":
    hasGroup = true
  elif node.role == platform.roleSwitch and node.label == "Wi-Fi":
    hasSwitch = true
  elif node.role == platform.roleRadio and node.label == "Comfortable" and
      (node.states and platform.accessChecked) != platform.AccessStates(0):
    hasSelectedRadio = true
doAssert hasCheckbox and hasGroup and hasSwitch and hasSelectedRadio

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert native.frame()
doAssert remember and checkboxChanged == 1

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert native.frame()
doAssert selected == spaciousSize and radioChanged == 1

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert native.frame()
doAssert wifi and switchChanged == 1
tree = native.accessibility()[0]
var checkedCheckbox, checkedRadio, checkedSwitch: bool
for node in tree.nodes:
  if node.role == platform.roleCheckBox and node.label == "Remember me":
    checkedCheckbox = (node.states and platform.accessChecked) !=
      platform.AccessStates(0)
  elif node.role == platform.roleRadio and node.label == "Spacious":
    checkedRadio = (node.states and platform.accessChecked) !=
      platform.AccessStates(0)
  elif node.role == platform.roleSwitch and node.label == "Wi-Fi":
    checkedSwitch = (node.states and platform.accessChecked) !=
      platform.AccessStates(0)
doAssert checkedCheckbox and checkedRadio and checkedSwitch

win.destroy()
loop.shutdown()
