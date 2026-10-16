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

proc hasRole(tree: ref platform.AccessTree; role: platform.AccessRole): bool =
  if tree != nil:
    for node in tree.nodes:
      if node.role == role:
        return true

proc popupNode(tree: ref platform.AccessTree; role: platform.AccessRole;
               label: string): platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == role and node.label == label:
        var parent = node.parent
        while parent >= 0:
          if tree.nodes[parent].role == platform.rolePopup:
            return node
          parent = tree.nodes[parent].parent
  raise newException(AssertionDefect,
    "missing popup node " & $role & " labeled " & label)

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui color picker test"))
app.initialized = true
app.handleReady()

var chosen = ui.rgb(255, 0, 0)
var accent = ui.rgb(0, 0, 255)
var chosenChanges, accentChanges: int
let colorContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().fill().gap(ctx.theme.space(3)).children(proc() =
    discard ctx.colorPicker(chosen).onChange(proc() = inc(chosenChanges))
    discard ctx.colorWell(accent).label("Accent")
      .onChange(proc() = inc(accentChanges))
  )
)
let win = newWindow(WindowOptions(width: 420, height: 720, hidden: true,
  content: colorContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
var plane = accessNode(tree, platform.roleSlider, "Saturation and brightness")
doAssert plane.min == 0 and plane.max == 100 and plane.now == 100
doAssert plane.value == "100% saturation, 100% brightness"
var hue = accessNode(tree, platform.roleSlider, "Hue")
var opacityNode = accessNode(tree, platform.roleSlider, "Opacity")
doAssert hue.min == 0 and hue.max == 360 and hue.now == 0
doAssert opacityNode.min == 0 and opacityNode.max == 1 and
  opacityNode.now == 1
var well = accessNode(tree, platform.roleColorWell, "Accent")
doAssert well.value == "#0000ff" and well.description == "#0000ff"

# The square responds to its arrow keys and exposes both values.
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: plane.id, action: platform.accessFocus))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert native.frame()
doAssert chosen.r == 255 and chosen.g in 2'u8..4'u8 and
  chosen.b in 2'u8..4'u8 and chosenChanges == 1

tree = native.accessibility()[0]
plane = accessNode(tree, platform.roleSlider, "Saturation and brightness")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: plane.id, action: platform.accessSetValue, text: "50"))
doAssert native.frame()
doAssert chosen.r == 255 and chosen.g in 126'u8..130'u8 and
  chosen.b in 126'u8..130'u8 and chosenChanges == 2

# Pointer down and drag update saturation and brightness together.
tree = native.accessibility()[0]
plane = accessNode(tree, platform.roleSlider, "Saturation and brightness")
let planeX = plane.bounds.x + plane.bounds.w * 0.75
let planeY = plane.bounds.y + plane.bounds.h * 0.25
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: planeX, y: planeY))
doAssert native.frame()
doAssert chosen.r in 188'u8..195'u8 and chosen.g in 43'u8..53'u8 and
  chosen.b in 43'u8..53'u8 and chosenChanges == 3
discard native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: plane.bounds.x + plane.bounds.w * 0.25,
  y: plane.bounds.y + plane.bounds.h * 0.75))
doAssert native.frame()
doAssert chosen.r in 60'u8..68'u8 and chosen.g in 43'u8..53'u8 and
  chosen.b in 37'u8..48'u8 and chosenChanges == 4
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: plane.bounds.x + plane.bounds.w * 0.25,
  y: plane.bounds.y + plane.bounds.h * 0.75))
doAssert native.frame()

# A swatch and the accessible hex field both update the bound color.
tree = native.accessibility()[0]
let blue = accessNode(tree, platform.roleButton, "Blue")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: blue.id, action: platform.accessPress))
doAssert native.frame()
doAssert chosen == ui.rgb(59, 130, 246) and chosenChanges == 5,
  $chosen & " changes=" & $chosenChanges

tree = native.accessibility()[0]
let hex = accessNode(tree, platform.roleTextField, "Hex")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: hex.id, action: platform.accessSetValue, text: "#00ff00"))
doAssert native.frame()
tree = native.accessibility()[0]
let changedHex = accessNode(tree, platform.roleTextField, "Hex")
doAssert chosen == ui.rgb(0, 255, 0) and chosenChanges == 6,
  $chosen & " changes=" & $chosenChanges & " hex=" & changedHex.value

tree = native.accessibility()[0]
hue = accessNode(tree, platform.roleSlider, "Hue")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: hue.id, action: platform.accessFocus))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert native.frame()
doAssert chosen.b > 0 and chosenChanges == 7

tree = native.accessibility()[0]
opacityNode = accessNode(tree, platform.roleSlider, "Opacity")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: opacityNode.id, action: platform.accessFocus))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert native.frame()
doAssert chosen.a < 255 and chosenChanges == 8

# The well announces its value and opens a dismissible color picker popover.
tree = native.accessibility()[0]
well = accessNode(tree, platform.roleColorWell, "Accent")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: well.id, action: platform.accessPress))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.hasRole(platform.rolePopup)
well = accessNode(tree, platform.roleColorWell, "Accent")
doAssert well.value == "#0000ff"
doAssert (well.states and platform.accessExpanded) == platform.accessExpanded
let popupGreen = popupNode(tree, platform.roleButton, "Green")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: popupGreen.id, action: platform.accessPress))
doAssert native.frame()
tree = native.accessibility()[0]
well = accessNode(tree, platform.roleColorWell, "Accent")
doAssert accent == ui.rgb(34, 197, 94) and accentChanges == 1
doAssert well.value == "#22c55e" and well.description == "#22c55e"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEscape))
doAssert native.frame()
doAssert not native.accessibility()[0].hasRole(platform.rolePopup)
doAssert accent == ui.rgb(34, 197, 94) and accentChanges == 1

win.destroy()
loop.shutdown()
