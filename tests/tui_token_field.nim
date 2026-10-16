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
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui token field test"))
app.initialized = true
app.handleReady()

const tokenSuggestions = ["typescript", "python", "rust"]
var tags = @["go"]
var changes = 0
var changedThisFrame = false
let tokenContent = ui.newContent(proc(ctx: ui.Context) =
  var frameTags = tags
  let field = ctx.tokenField(frameTags, tokenSuggestions).label("Tags")
    .width(360).onChange(proc() = inc changes)
  changedThisFrame = field.changed()
  if changedThisFrame:
    tags = frameTags
)
let tokenWindow = newWindow(WindowOptions(width: 400, height: 180,
  hidden: true, content: tokenContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
var input = accessNode(tree, platform.roleComboBox, "Tags")
discard accessNode(tree, platform.roleButton, "Remove go")

# Commas add tokens and keep the keyed input focused as chips grow before it.
let inputX = input.bounds.x + input.bounds.w / 2
let inputY = input.bounds.y + input.bounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: inputX, y: inputY))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: inputX, y: inputY))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "zig,"))
doAssert native.frame()
doAssert tags == @["go", "zig"] and changedThisFrame and changes == 1
tree = native.accessibility()[0]
input = accessNode(tree, platform.roleComboBox, "Tags")
doAssert tree.focus == input.id

# Enter adds plain text when no suggestion is active.
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "lua"))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert native.frame()
doAssert tags == @["go", "zig", "lua"] and changedThisFrame

# Backspace in an empty query removes the final chip.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyBackspace))
doAssert native.frame()
doAssert tags == @["go", "zig"] and changedThisFrame

# Suggestions filter, arrow keys highlight them, and Enter adds the option.
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "ty"))
doAssert native.frame()
tree = native.accessibility()[0]
var suggestions = tree.listItems()
doAssert suggestions.len == 1 and suggestions[0].label == "typescript"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.accessNodeById(tree.focus).label == "typescript"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert native.frame()
doAssert tags == @["go", "zig", "typescript"] and changedThisFrame
tree = native.accessibility()[0]
input = accessNode(tree, platform.roleComboBox, "Tags")
doAssert tree.focus == input.id

# Removing a chip also keeps the insertion point focused.
let removeGo = accessNode(tree, platform.roleButton, "Remove go")
let removeX = removeGo.bounds.x + removeGo.bounds.w / 2
let removeY = removeGo.bounds.y + removeGo.bounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: removeX, y: removeY))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: removeX, y: removeY))
doAssert native.frame()
doAssert tags == @["zig", "typescript"] and changedThisFrame
tree = native.accessibility()[0]
input = accessNode(tree, platform.roleComboBox, "Tags")
doAssert tree.focus == input.id
doAssert changes == 5

tokenWindow.destroy()
loop.shutdown()
