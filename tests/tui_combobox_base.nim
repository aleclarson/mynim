import std/[assertions, sequtils, strutils]

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

proc accessNodeById(tree: ref platform.AccessTree; id: uint64):
    platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.id == id:
        return node
  raise newException(AssertionDefect, "missing focused access node")

proc listItems(tree: ref platform.AccessTree): seq[platform.AccessNode] =
  if tree != nil:
    for node in tree.nodes:
      if node.role == platform.roleListItem:
        result.add(node)

proc matching(options: openArray[string]; query: string): seq[string] =
  var starts, contains: seq[string]
  for option in options:
    let candidate = option.toLowerAscii()
    if candidate.startsWith(query):
      starts.add(option)
    elif candidate.contains(query):
      contains.add(option)
  result = starts
  result.add(contains)

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui combobox base test"))
app.initialized = true
app.handleReady()

let comboOptions = ["Zeta", "Delta", "Taco", "Beta"]
var query = ""
var selected = ""
var choices = 0
var forceClosePopup = false
var popupOpenThisBuild = false
var filteringThisBuild = false
let comboContent = ui.newContent(proc(ctx: ui.Context) =
  var frameQuery = query
  let parts = ctx.comboboxBase(frameQuery)
  discard parts.input.label("Custom combo").width(200)
  if forceClosePopup:
    forceClosePopup = false
    parts.setOpen(false)
  popupOpenThisBuild = parts.isOpen()
  filteringThisBuild = parts.filtering()
  var shown: seq[string]
  if parts.filtering:
    shown = matching(comboOptions, frameQuery.strip().toLowerAscii())
  else:
    shown = @comboOptions
  discard parts.popup(proc(panel: ui.Element) =
    discard panel.children(proc() =
      for value in shown:
        let textValue = value
        let option = parts.item(value)
        if option.isHighlighted:
          discard option.element.background(ui.rgb(50'u8, 100'u8, 200'u8))
            .textColor(ui.rgb(255'u8, 255'u8, 255'u8))
        discard option.element.children(proc() = discard ctx.text(textValue))
    )
  )
  let (value, chosen) = parts.chosen()
  if chosen:
    frameQuery = value
    selected = value
    inc choices
  query = frameQuery
)
let comboWindow = newWindow(WindowOptions(width: 420, height: 360,
  hidden: true, content: comboContent))
let comboSurface = fake.windows[^1].surface

doAssert comboSurface.frame()
doAssert comboSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = comboSurface.accessibility()[0]
var combo = accessNode(tree, platform.roleComboBox, "Custom combo")
doAssert tree.listItems().len == 0
let initialX = combo.bounds.x + combo.bounds.w / 2
let initialY = combo.bounds.y + combo.bounds.h / 2
doAssert comboSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: initialX, y: initialY))
doAssert comboSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: initialX, y: initialY))
doAssert comboSurface.frame()
doAssert comboSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEscape))
doAssert comboSurface.frame()

# Down reopens the popup and highlights its first option.
doAssert comboSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert comboSurface.frame()
tree = comboSurface.accessibility()[0]
combo = accessNode(tree, platform.roleComboBox, "Custom combo")
doAssert (combo.states and platform.accessExpanded) != platform.AccessStates(0)
let comboItems = tree.listItems()
doAssert comboItems.len == comboOptions.len
doAssert comboItems[0].label == "Zeta" and comboItems[0].posInSet == 1
doAssert comboItems[0].setSize == comboOptions.len
doAssert (comboItems[0].states and platform.accessChecked) != platform.AccessStates(0)
doAssert tree.accessNodeById(tree.focus).label == "Zeta"
discard accessNode(tree, platform.roleList, "")

# Typing filters in the caller's order with prefix matches first.
doAssert comboSurface.send(platform.SurfaceEvent(kind: platform.textInput, text: "ta"))
doAssert comboSurface.frame()
doAssert popupOpenThisBuild and filteringThisBuild
tree = comboSurface.accessibility()[0]
let filtered = tree.listItems()
doAssert filtered.mapIt(it.label) == @["Taco", "Zeta", "Delta", "Beta"]
doAssert tree.accessNodeById(tree.focus).label == "Taco"

# Enter reports the choice once after Popup has built its options.
doAssert comboSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert comboSurface.frame()
doAssert selected == "Taco" and query == "Taco" and choices == 1
doAssert choices == 1

# The option click keeps keyboard focus in the combobox input.
tree = comboSurface.accessibility()[0]
combo = accessNode(tree, platform.roleComboBox, "Custom combo")
let fieldX = combo.bounds.x + combo.bounds.w / 2
let fieldY = combo.bounds.y + combo.bounds.h / 2
doAssert comboSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: fieldX, y: fieldY))
doAssert comboSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: fieldX, y: fieldY))
doAssert comboSurface.frame()
tree = comboSurface.accessibility()[0]
let beta = block:
  var found: platform.AccessNode
  for item in tree.listItems():
    if item.label == "Beta":
      found = item
  found
doAssert beta.id != 0
let betaX = beta.bounds.x + beta.bounds.w / 2
let betaY = beta.bounds.y + beta.bounds.h / 2
doAssert comboSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: betaX, y: betaY))
doAssert comboSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: betaX, y: betaY))
doAssert comboSurface.frame()
doAssert selected == "Beta" and choices == 2
tree = comboSurface.accessibility()[0]
combo = accessNode(tree, platform.roleComboBox, "Custom combo")
doAssert tree.focus == combo.id

# Up opens at the last option and Enter reports that choice once.
doAssert comboSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyUp))
doAssert comboSurface.frame()
doAssert popupOpenThisBuild
tree = comboSurface.accessibility()[0]
doAssert tree.accessNodeById(tree.focus).label == "Beta"
doAssert comboSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert comboSurface.frame()
doAssert selected == "Beta" and choices == 3

# A caller can close an open popup before its next build.
forceClosePopup = true
doAssert comboSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert comboSurface.frame()
doAssert not popupOpenThisBuild

comboWindow.destroy()
loop.shutdown()
