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
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui autocomplete test"))
app.initialized = true
app.handleReady()

const citySuggestions = ["Paris", "Parma", "Lyon", "Comparis"]
var city = ""
var changes, submits: int
var changedThisFrame, submittedThisFrame: bool
let autocompleteContent = ui.newContent(proc(ctx: ui.Context) =
  var frameCity = city
  let field = ctx.autocomplete(frameCity, citySuggestions).label("City")
    .onChange(proc() = inc changes)
    .onSubmit(proc() = inc submits)
  changedThisFrame = field.changed()
  submittedThisFrame = field.submitted()
  if changedThisFrame:
    city = frameCity
  discard ctx.button("Next")
)
let autocompleteWindow = newWindow(WindowOptions(width: 360, height: 220,
  hidden: true, content: autocompleteContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
var field = accessNode(tree, platform.roleComboBox, "City")
doAssert field.value == ""

# Clicking an empty autocomplete does not show suggestions.
let fieldX = field.bounds.x + field.bounds.w / 2
let fieldY = field.bounds.y + field.bounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: fieldX, y: fieldY))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: fieldX, y: fieldY))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.listItems().len == 0
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "par"))
doAssert native.frame()
doAssert city == "par" and changedThisFrame and changes > 0
tree = native.accessibility()[0]
field = accessNode(tree, platform.roleComboBox, "City")
doAssert field.value == "par"
var itemNodes = tree.listItems()
doAssert itemNodes.len == 3
doAssert itemNodes[0].label == "Paris"
doAssert itemNodes[1].label == "Parma"
doAssert itemNodes[2].label == "Comparis"
doAssert tree.focus == field.id

# Enter with no active suggestion submits the typed value unchanged.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert native.frame()
doAssert city == "par" and submittedThisFrame and submits == 1

# Typing narrows the suggestions; arrows choose one, but exact matches are
# excluded from the popup to avoid suggesting the current value.
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "i"))
doAssert native.frame()
doAssert city == "pari" and changedThisFrame
tree = native.accessibility()[0]
itemNodes = tree.listItems()
doAssert itemNodes.len == 2
doAssert itemNodes[0].label == "Paris"
doAssert itemNodes[1].label == "Comparis"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.accessNodeById(tree.focus).label == "Paris"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert native.frame()
doAssert city == "Paris" and changedThisFrame and changes >= 2
doAssert not submittedThisFrame and submits == 1
tree = native.accessibility()[0]
field = accessNode(tree, platform.roleComboBox, "City")
doAssert field.value == "Paris" and tree.focus == field.id
doAssert tree.listItems().len == 0

# Typing a complete suggestion removes that exact suggestion from the list.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  mods: platform.modSuper, key: platform.keyA))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "Paris"))
doAssert native.frame()
tree = native.accessibility()[0]
for item in tree.listItems():
  doAssert item.label != "Paris"

autocompleteWindow.destroy()
loop.shutdown()
