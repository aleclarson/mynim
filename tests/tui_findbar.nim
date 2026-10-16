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
    "missing accessibility node " & $role & " labeled " & label)

proc pressKey(native: fakeBackend.FakeSurface; key: platform.Key;
              mods: platform.Modifiers = 0) =
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: key, mods: mods))
  doAssert native.frame()
  if native.send(platform.SurfaceEvent(kind: platform.keyReleased,
      key: key, mods: mods)):
    discard native.frame()

proc pressAccess(native: fakeBackend.FakeSurface;
                 node: platform.AccessNode) =
  doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
    id: node.id, action: platform.accessPress))
  doAssert native.frame()

proc countMatches(query: string): int =
  let text = "the cat sat on the mat with the hat"
  if query.len == 0 or query.len > text.len:
    return
  var start = 0
  while start + query.len <= text.len:
    if text[start ..< start + query.len] == query:
      inc result
    inc start

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui find bar test"))
app.initialized = true
app.handleReady()

var barOpen = true
var query = "the"
var current = 0
var moves = 0
var changedThisFrame = false
let findContent = ui.newContent(proc(c: ui.Context) =
  discard c.column().size(620, 200).children(proc() =
    let matches = countMatches(query)
    let bar = c.findBar(barOpen, query, matches, current)
    changedThisFrame = bar.changed()
    if changedThisFrame:
      inc moves
    discard c.text("the cat sat on the mat with the hat")
  )
)
let win = newWindow(WindowOptions(width: 640, height: 220,
  hidden: true, content: findContent))
let native = fake.windows[^1].fakeSurface()

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
let toolbar = accessNode(tree, platform.roleToolbar, "Find")
let field = accessNode(tree, platform.roleTextField, "Find")
doAssert tree.focus == field.id
let findStatus = accessNode(tree, platform.roleStatus, "1 of 3")
doAssert toolbar.id != field.id and findStatus.id != field.id
let inputState = native.lastTextInput()
doAssert inputState.active and inputState.start == 0 and inputState.`end` == 3

# Opening selects the existing query, so typing replaces it.
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput, text: "x"))
doAssert native.frame()
doAssert query == "x"
doAssert native.frame()
tree = native.accessibility()[0]
discard accessNode(tree, platform.roleStatus, "No matches")
doAssert not changedThisFrame

# With no matches, navigation shortcuts are consumed without reporting a move.
when defined(macosx):
  pressKey(native, platform.keyG, platform.modSuper)
else:
  pressKey(native, platform.keyF3)
doAssert current == 0 and moves == 0

# The application can update the search query and match count between builds.
query = "the"
when defined(macosx):
  pressKey(native, platform.keyG, platform.modSuper)
else:
  pressKey(native, platform.keyF3)
tree = native.accessibility()[0]
discard accessNode(tree, platform.roleStatus, "1 of 3")

pressKey(native, platform.keyEnter)
doAssert current == 1 and changedThisFrame
pressKey(native, platform.keyEnter)
doAssert current == 2
pressKey(native, platform.keyEnter)
doAssert current == 0
pressKey(native, platform.keyEnter, platform.modShift)
doAssert current == 2
when defined(macosx):
  pressKey(native, platform.keyG, platform.modSuper)
  doAssert current == 0
  pressKey(native, platform.keyG, platform.modSuper or platform.modShift)
  doAssert current == 2
else:
  pressKey(native, platform.keyF3)
  doAssert current == 0
  pressKey(native, platform.keyF3, platform.modShift)
  doAssert current == 2

tree = native.accessibility()[0]
pressAccess(native, accessNode(tree, platform.roleButton, "Next"))
doAssert current == 0 and changedThisFrame
tree = native.accessibility()[0]
discard accessNode(tree, platform.roleStatus, "1 of 3")
pressAccess(native, accessNode(tree, platform.roleButton, "Previous"))
doAssert current == 2 and changedThisFrame
tree = native.accessibility()[0]
discard accessNode(tree, platform.roleStatus, "3 of 3")
pressAccess(native, accessNode(tree, platform.roleButton, "Done"))
doAssert not barOpen
doAssert native.frame()
tree = native.accessibility()[0]
for node in tree.nodes:
  doAssert node.role != platform.roleToolbar or node.label != "Find"

win.destroy()

var escapeOpen = true
var escapeQuery = "the"
var escapeCurrent = 0
let escapeContent = ui.newContent(proc(c: ui.Context) =
  discard c.findBar(escapeOpen, escapeQuery, countMatches(escapeQuery),
    escapeCurrent)
)
let escapeWin = newWindow(WindowOptions(width: 640, height: 120,
  hidden: true, content: escapeContent))
let escapeNative = fake.windows[^1].fakeSurface()
doAssert escapeNative.frame()
doAssert escapeNative.lastTextInput().active
pressKey(escapeNative, platform.keyEscape)
doAssert not escapeOpen
escapeWin.destroy()
loop.shutdown()
