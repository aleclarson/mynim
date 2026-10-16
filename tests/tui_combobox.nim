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

proc listItems(tree: ref platform.AccessTree): seq[platform.AccessNode] =
  if tree != nil:
    for node in tree.nodes:
      if node.role == platform.roleListItem:
        result.add(node)

proc accessNodeById(tree: ref platform.AccessTree; id: uint64):
    platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.id == id:
        return node
  raise newException(AssertionDefect, "missing focused access node")

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui combobox test"))
app.initialized = true
app.handleReady()

const comboOptions = ["Arial", "Helvetica", "Times", "Courier", "Optima"]
var selected = "Arial"
var changes = 0
var changedThisFrame = false
let comboContent = ui.newContent(proc(ctx: ui.Context) =
  var frameSelected = selected
  let combo = ctx.combobox(frameSelected, comboOptions).label("Font")
    .onChange(proc() = inc changes)
  changedThisFrame = combo.changed()
  if changedThisFrame:
    selected = frameSelected
  discard ctx.button("After")
)
let comboWindow = newWindow(WindowOptions(width: 360, height: 240,
  hidden: true, content: comboContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
var combo = accessNode(tree, platform.roleComboBox, "Font")
doAssert combo.value == "Arial"
doAssert (combo.states and platform.accessExpanded) == platform.AccessStates(0)
doAssert tree.listItems().len == 0

# Opening the field shows all options; typing filters, with prefixes first.
let fieldX = combo.bounds.x + combo.bounds.w / 2
let fieldY = combo.bounds.y + combo.bounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: fieldX, y: fieldY))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: fieldX, y: fieldY))
doAssert native.frame()
tree = native.accessibility()[0]
combo = accessNode(tree, platform.roleComboBox, "Font")
doAssert (combo.states and platform.accessExpanded) != platform.AccessStates(0)
doAssert tree.listItems().len == comboOptions.len
discard accessNode(tree, platform.roleList, "")

doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "ti"))
doAssert native.frame()
tree = native.accessibility()[0]
combo = accessNode(tree, platform.roleComboBox, "Font")
doAssert combo.value == "ti"
var itemNodes = tree.listItems()
doAssert itemNodes.len == 3
doAssert itemNodes[0].label == "Times"
doAssert itemNodes[1].label == "Helvetica"
doAssert itemNodes[2].label == "Optima"
doAssert itemNodes[0].posInSet == 1 and itemNodes[0].setSize == 3
doAssert tree.accessNodeById(tree.focus).label == "Times"

# Enter selects the highlighted prefix once and reports the selected value.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert native.frame()
doAssert selected == "Times" and changedThisFrame and changes == 1
tree = native.accessibility()[0]
combo = accessNode(tree, platform.roleComboBox, "Font")
doAssert combo.value == "Times"
doAssert tree.focus == combo.id

# Down reopens the full list. Clicking an option selects it and keeps focus.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert native.frame()
tree = native.accessibility()[0]
itemNodes = tree.listItems()
doAssert itemNodes.len == comboOptions.len
var courier: platform.AccessNode
for item in itemNodes:
  if item.label == "Courier":
    courier = item
doAssert courier.id != 0
let itemX = courier.bounds.x + courier.bounds.w / 2
let itemY = courier.bounds.y + courier.bounds.h / 2
discard native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: itemX, y: itemY))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.accessNodeById(tree.focus).label == "Courier"
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: itemX, y: itemY))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: itemX, y: itemY))
doAssert native.frame()
doAssert selected == "Courier" and changedThisFrame and changes == 2
tree = native.accessibility()[0]
combo = accessNode(tree, platform.roleComboBox, "Font")
doAssert tree.focus == combo.id

# The disclosure button reopens every option and selects the current text.
let showOptions = accessNode(tree, platform.roleButton, "Show options")
let arrowX = showOptions.bounds.x + showOptions.bounds.w / 2
let arrowY = showOptions.bounds.y + showOptions.bounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: arrowX, y: arrowY))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: arrowX, y: arrowY))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.listItems().len == comboOptions.len

# Escape closes unmatched text; leaving the field restores the last choice.
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "zzz"))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.listItems().len == 0
combo = accessNode(tree, platform.roleComboBox, "Font")
doAssert (combo.states and platform.accessExpanded) != platform.AccessStates(0)
for node in tree.nodes:
  doAssert node.role != platform.rolePopup
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEscape))
doAssert native.frame()
tree = native.accessibility()[0]
combo = accessNode(tree, platform.roleComboBox, "Font")
doAssert (combo.states and platform.accessExpanded) == platform.AccessStates(0)
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
combo = accessNode(tree, platform.roleComboBox, "Font")
doAssert combo.value == "Courier" and selected == "Courier"
doAssert not changedThisFrame and changes == 2

comboWindow.destroy()

# Scrolling past a pointer-highlighted option does not pull it back into view.
var manyChoice = ""
var manyOptions: seq[string]
for index in 0..<60:
  manyOptions.add("Option " & align($index, 2, '0'))
let manyContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.combobox(manyChoice, manyOptions).label("Pick")
)
let manyWindow = newWindow(WindowOptions(width: 400, height: 600,
  hidden: true, content: manyContent))
let manySurface = fake.windows[^1].surface
doAssert manySurface.frame()
doAssert manySurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
tree = manySurface.accessibility()[0]
let pick = accessNode(tree, platform.roleComboBox, "Pick")
let pickX = pick.bounds.x + pick.bounds.w / 2
let pickY = pick.bounds.y + pick.bounds.h / 2
doAssert manySurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: pickX, y: pickY))
doAssert manySurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: pickX, y: pickY))
doAssert manySurface.frame()
tree = manySurface.accessibility()[0]
itemNodes = tree.listItems()
doAssert itemNodes.len == manyOptions.len
let firstY = itemNodes[0].bounds.y + itemNodes[0].bounds.h / 2
discard manySurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: itemNodes[0].bounds.x + itemNodes[0].bounds.w / 2, y: firstY))
doAssert manySurface.frame()
for _ in 0..<30:
  discard manySurface.send(platform.SurfaceEvent(
    kind: platform.pointerScroll, x: itemNodes[0].bounds.x + 10,
    y: firstY, dy: 120))
  discard manySurface.frame()
tree = manySurface.accessibility()[0]
itemNodes = tree.listItems()
var lastOption: platform.AccessNode
for item in itemNodes:
  if item.label == "Option 59":
    lastOption = item
doAssert lastOption.id != 0 and lastOption.bounds.y < firstY + 400
doAssert tree.accessNodeById(tree.focus).label == "Option 00"

# Arrow navigation moves the active option and scrolls it into view once.
doAssert manySurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert manySurface.frame()
tree = manySurface.accessibility()[0]
let active = tree.accessNodeById(tree.focus)
let popupList = accessNode(tree, platform.roleList, "")
doAssert active.label == "Option 01"
doAssert active.bounds.y >= popupList.bounds.y and
  active.bounds.y + active.bounds.h <= popupList.bounds.y + popupList.bounds.h

manyWindow.destroy()
loop.shutdown()
