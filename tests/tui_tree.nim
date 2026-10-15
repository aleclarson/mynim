import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui tree test"))
app.initialized = true
app.handleReady()

let treeState = ui.newTreeState()
let sourceItem = ui.newTreeItemState("src")
let nested = ui.newTreeItemState("nested")
let mainFile = ui.newTreeItemState("main")
let readme = ui.newTreeItemState("readme")
let rootFile = ui.newTreeItemState("go.mod")
let treeContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.tree(treeState, proc() =
    discard ctx.treeItem(sourceItem, "src", proc() =
      discard ctx.treeItem(nested, "nested", proc() =
        discard ctx.treeItem(mainFile, "main.nim")
      )
      discard ctx.treeItem(readme, "README")
    )
    discard ctx.treeItem(rootFile, "go.mod", selected = true)
  ).size(220, 140)
)
let treeWindow = newWindow(WindowOptions(width: 220, height: 140,
  hidden: true, content: treeContent))
let treeSurface = fake.windows[^1].surface
doAssert treeSurface.frame()
doAssert treeSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let (initialTree, _) = treeSurface.accessibility()
var treeRootId = 0'u64
var sourceId = 0'u64
var rootFileId = 0'u64
var nestedHidden = true
for node in initialTree.nodes:
  if node.role == platform.roleTree:
    treeRootId = node.id
  if node.role == platform.roleTreeItem and node.label == "src":
    sourceId = node.id
    doAssert node.level == 1
    doAssert (node.states and platform.accessExpandable) !=
      platform.AccessStates(0)
  if node.role == platform.roleTreeItem and node.label == "nested":
    nestedHidden = false
  if node.role == platform.roleTreeItem and node.label == "go.mod":
    rootFileId = node.id
    doAssert (node.states and platform.accessSelected) !=
      platform.AccessStates(0)
doAssert treeRootId > 0 and sourceId > 0 and nestedHidden
doAssert rootFileId > 0

doAssert treeSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert treeSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert treeState.activeKey == "go.mod",
  "Down should move from a Tab-focused row to the next visible item"
doAssert treeSurface.frame()
let (tabFocusedTree, _) = treeSurface.accessibility()
doAssert tabFocusedTree.focus == rootFileId

doAssert treeSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 12, y: 14))
doAssert treeSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 12, y: 14))
doAssert treeSurface.frame()
doAssert sourceItem.open
let (openedTree, _) = treeSurface.accessibility()
sourceId = 0'u64
var nestedId = 0'u64
for node in openedTree.nodes:
  if node.role == platform.roleTreeItem and node.label == "src":
    sourceId = node.id
    doAssert (node.states and platform.accessExpanded) !=
      platform.AccessStates(0)
  if node.role == platform.roleTreeItem and node.label == "nested":
    nestedId = node.id
    doAssert node.level == 2
doAssert sourceId > 0 and nestedId > 0

doAssert treeSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: nestedId, action: platform.accessExpand))
doAssert treeSurface.frame()
doAssert nested.open
doAssert treeState.activeKey == "nested"
doAssert treeSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: nestedId, action: platform.accessCollapse))
doAssert treeSurface.frame()
doAssert not nested.open
let (nestedTree, _) = treeSurface.accessibility()
var sourceFocusId = 0'u64
for node in nestedTree.nodes:
  if node.role == platform.roleTreeItem and node.label == "src":
    sourceFocusId = node.id
doAssert sourceFocusId > 0
doAssert treeSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: sourceFocusId, action: platform.accessFocus))
doAssert treeSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert treeState.activeKey == "nested",
  "Right on an open item should focus its first child"
doAssert treeSurface.frame()
let (focusedTree, _) = treeSurface.accessibility()
doAssert focusedTree.focus == nestedId,
  "Right should move the platform keyboard focus to the child"
doAssert treeSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert nested.open and treeState.activeKey == "nested",
  "Right on a closed branch should open it"
doAssert treeSurface.frame()
doAssert treeState.activeKey == "nested"
doAssert treeSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert not nested.open,
  "Left on an open branch should close it"
doAssert treeSurface.frame()
doAssert treeSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert treeState.activeKey == "src",
  "Left on a closed child should focus its parent"
doAssert treeSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert treeState.activeKey == "nested",
  "Down should move through visible items in tree order"

treeWindow.destroy()
loop.shutdown()
