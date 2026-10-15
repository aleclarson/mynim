import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc outlineChildren(item: string): seq[string] =
  case item
  of "src": @["a.nim", "b.nim"]
  of "a.nim": @["nested.nim"]
  else: @[]

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui outline test"))
app.initialized = true
app.handleReady()

let outlineState = ui.newOutlineState[string](
  proc(item: string): string = item)
let outlineContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.outline(outlineState, @["src", "README"], outlineChildren,
    proc(item: string) = discard ctx.text(item)).size(220, 120)
)
let outlineWin = newWindow(WindowOptions(width: 220, height: 120, hidden: true,
  content: outlineContent))
let outlineSurface = fake.windows[^1].surface

doAssert outlineSurface.frame()
doAssert outlineState.rowCount() == 2
doAssert outlineState.item(0) == "src" and outlineState.depth(0) == 0
doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let (initialTree, _) = outlineSurface.accessibility()
var treeRootId = 0'u64
var sourceRowId = 0'u64
var sourceExpandable = false
for node in initialTree.nodes:
  if node.role == platform.roleTree:
    treeRootId = node.id
  elif node.role == platform.roleTreeItem and node.label == "src":
    sourceRowId = node.id
    sourceExpandable = (node.states and platform.accessExpandable) !=
      platform.AccessStates(0)
    doAssert node.level == 1
    doAssert (node.actions and platform.actionExpand) !=
      platform.AccessActions(0)
doAssert treeRootId > 0 and sourceRowId > 0 and sourceExpandable

doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: sourceRowId, action: platform.accessExpand))
doAssert outlineSurface.frame()
doAssert outlineState.isOpen("src") and outlineState.rowCount() == 4,
  "the accessibility expand action should open its children"

outlineState.list.select(1)
doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: sourceRowId, action: platform.accessCollapse))
doAssert outlineState.list.selected() == 0,
  "closing an ancestor should move a hidden descendant choice to its parent"
doAssert outlineSurface.frame()
doAssert outlineState.rowCount() == 2

doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 12, y: 18))
doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 12, y: 18))
doAssert outlineSurface.frame()
doAssert outlineState.isOpen("src") and outlineState.rowCount() == 4,
  "clicking the disclosure control should open its children"
doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 12, y: 18))
doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 12, y: 18))
doAssert outlineSurface.frame()
doAssert outlineState.rowCount() == 2

let (collapsedTree, _) = outlineSurface.accessibility()
var collapsedSourceId = 0'u64
for node in collapsedTree.nodes:
  if node.role == platform.roleTreeItem and node.label == "src":
    collapsedSourceId = node.id
doAssert collapsedSourceId > 0
doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: collapsedSourceId, action: platform.accessFocus))
doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert outlineSurface.frame()
doAssert outlineState.rowCount() == 4,
  "Right should open the selected branch"
doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert outlineSurface.frame()
doAssert outlineState.list.selected() == 1,
  "Right on an open branch should move to its first child"
doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert outlineSurface.frame()
doAssert outlineState.list.selected() == 0,
  "Left on a child should move to its parent"
doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft, mods: platform.modShift))
doAssert outlineSurface.frame()
doAssert outlineState.rowCount() == 2,
  "Shift+Left should close the selected branch"
outlineState.setOpen("src", true, outlineChildren, all = true)
doAssert outlineState.isOpen("src") and outlineState.isOpen("a.nim")
outlineState.setOpen("src", false, outlineChildren, all = true)
doAssert not outlineState.isOpen("src") and not outlineState.isOpen("a.nim")
doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 12, y: 18, mods: platform.modAlt))
doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 12, y: 18, mods: platform.modAlt))
doAssert outlineSurface.frame()
doAssert outlineState.rowCount() == 5 and outlineState.isOpen("a.nim"),
  "Alt-click should open all descendant branches"
doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 12, y: 18, mods: platform.modAlt))
doAssert outlineSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 12, y: 18, mods: platform.modAlt))
doAssert outlineSurface.frame()
doAssert outlineState.rowCount() == 2 and not outlineState.isOpen("a.nim"),
  "Alt-click should close all descendant branches"

let outlineColumns = [
  ui.TableColumn(title: "Name", width: 110),
  ui.TableColumn(title: "Kind", width: 70)
]
let outlineTableState = ui.newOutlineState[string](
  proc(item: string): string = item,
  children = outlineChildren)
let outlineTableContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.outlineTable(outlineTableState, outlineColumns,
    @["src", "README"], outlineChildren,
    proc(item: string; column: int) =
      if column == 0:
        discard ctx.text(item)
      else:
        discard ctx.text("file")
  ).size(220, 100)
)
let outlineTableWin = newWindow(WindowOptions(width: 220, height: 100,
  hidden: true, content: outlineTableContent))
let outlineTableSurface = fake.windows[^1].surface
doAssert outlineTableSurface.frame()
doAssert outlineTableSurface.send(platform.SurfaceEvent(
  kind: platform.accessibilityOn))
let (outlineTableTree, _) = outlineTableSurface.accessibility()
var outlineTableRole, outlineTableItemRole, outlineCellRole = false
for node in outlineTableTree.nodes:
  outlineTableRole = outlineTableRole or node.role == platform.roleTree
  outlineTableItemRole = outlineTableItemRole or
    node.role == platform.roleTreeItem
  outlineCellRole = outlineCellRole or node.role == platform.roleCell
doAssert outlineTableRole and outlineTableItemRole and outlineCellRole

outlineTableWin.destroy()
outlineWin.destroy()
loop.shutdown()
