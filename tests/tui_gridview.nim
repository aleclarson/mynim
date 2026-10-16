import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui grid test"))
app.initialized = true
app.handleReady()

let gridState = ui.newGridState(selectable = true,
  itemKey = proc(item: int): string = "photo-" & $item,
  itemLabel = proc(item: int): string = "Photo " & $item)
var builtItems: seq[int]
var changedDuringBuild, submittedDuringBuild: bool
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  builtItems.setLen(0)
  let grid = ctx.gridView(gridState, 100, 100, 48, proc(item: int) =
    builtItems.add(item)
    discard ctx.box().fill().background(ui.rgb(30, 60, 90))
  ).size(320, 160)
  changedDuringBuild = grid.changed()
  submittedDuringBuild = grid.submitted()
)
let win = newWindow(WindowOptions(width: 320, height: 160, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert gridState.columns == 3
doAssert native.frame()
doAssert builtItems.len < 100, "GridView should build only visible items"
doAssert gridState.visible().first == 0

doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 250, y: 20))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 250, y: 20))
doAssert native.frame()
doAssert gridState.selected() == 2
doAssert changedDuringBuild

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert native.frame()
doAssert gridState.selected() == 5,
  "Down should preserve the column in the next grid row"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert native.frame()
doAssert gridState.selected() == 99
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert native.frame()
doAssert submittedDuringBuild

doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let (tree, _) = native.accessibility()
var selectedId = 0'u64
var visibleItems = 0
for accessible in tree.nodes:
  if accessible.role == platform.roleListItem:
    inc visibleItems
    doAssert accessible.setSize == 100
    doAssert accessible.label.startsWith("Photo ")
    if (accessible.states and platform.accessSelected) !=
        platform.AccessStates(0):
      selectedId = accessible.id
doAssert visibleItems < 100
doAssert selectedId > 0
doAssert tree.focus == selectedId,
  "the grid should expose its selected item as the active descendant"

gridState.select(-1)
doAssert gridState.selected() == -1
doAssert gridState.visible().last >= gridState.visible().first

let responsiveContext = ui.newContext()
let responsiveState = ui.newGridState()
proc buildResponsive(width: float32) =
  responsiveContext.build(proc(ctx: ui.Context) =
    discard ctx.gridView(responsiveState, 500, 100, 48,
      proc(item: int) = discard).size(width, 160)
  )
  discard responsiveContext.layout(width, 160)

buildResponsive(320)
buildResponsive(320)
doAssert responsiveState.columns == 3
responsiveState.scrollIntoView(60)
buildResponsive(320)
let beforeResize = responsiveState.visible()
doAssert beforeResize.first <= 60 and beforeResize.last >= 60
buildResponsive(240)
doAssert responsiveState.columns == 2
buildResponsive(240)
doAssert responsiveState.visible().first == beforeResize.first,
  "resizing should keep the same first visible item in view"
buildResponsive(400)
doAssert responsiveState.columns == 3
buildResponsive(400)
doAssert responsiveState.visible().first == beforeResize.first

block unkeyed_grid_shares_index_selection:
  let context = ui.newContext()
  var chosen: ui.Selection[int]
  chosen.add(1)
  let state = ui.newGridState().bindSelection(chosen)

  context.build(proc(ctx: ui.Context) =
    discard ctx.gridView(state, 4, 40, 20,
      proc(item: int) = discard).size(100, 60)
  )
  discard context.layout(100, 60)
  doAssert state.isSelected(1)

  chosen.remove(1)
  doAssert not state.isSelected(1)
  state.toggleSelection(3)
  doAssert chosen.has(3)
  state.clearSelection()
  doAssert chosen.len == 0

block grid_selection_key_type_must_match_items:
  var keyedSelection: ui.Selection[int]
  let keyedState = ui.newGridState(itemKey = proc(item: int): string = $item)
  doAssertRaises ValueError:
    discard keyedState.bindSelection(keyedSelection)

  var indexSelection: ui.Selection[string]
  let indexState = ui.newGridState()
  doAssertRaises ValueError:
    discard indexState.bindSelection(indexSelection)

var names = @[
  "Apple", "Apricot", "Banana", "Blueberry",
  "Cherry", "Clementine", "Date", "Elderberry"
]
var reorderItems: seq[int]
var reorderBefore = -1
var interactionSubmitted = false
let interactionState = ui.newGridState(multiSelectable = true,
  itemKey = proc(item: int): string = names[item],
  itemLabel = proc(item: int): string = names[item],
  reorder = proc(items: seq[int]; beforeItem: int) =
    reorderItems = items
    reorderBefore = beforeItem)
var appChosenItems: ui.Selection[string]
discard interactionState.bindSelection(appChosenItems)
let interactionContent = ui.newContent(proc(ctx: ui.Context) =
  let grid = ctx.gridView(interactionState, Natural(names.len), 100, 60,
    proc(item: int) =
      discard ctx.box().fill().background(ui.rgb(30, 60, 90))
  ).size(448, 180)
  interactionSubmitted = grid.submitted()
)
let interactionWin = newWindow(WindowOptions(width: 448, height: 180,
  hidden: true, content: interactionContent))
let interactionNative = fake.windows[^1].surface
doAssert interactionNative.frame()
doAssert interactionNative.frame()
doAssert interactionState.columns == 4

proc interactionPoint(item: int): tuple[x, y: float32] =
  let col = item mod interactionState.columns
  let row = item div interactionState.columns
  (x: float32(col * 114 + 53), y: float32(row * 68 + 34))

proc clickGrid(item: int; mods: platform.Modifiers = 0; clicks = 1) =
  let point = interactionPoint(item)
  doAssert interactionNative.send(platform.SurfaceEvent(
    kind: platform.pointerDown, x: point.x, y: point.y, mods: mods))
  doAssert interactionNative.send(platform.SurfaceEvent(
    kind: platform.pointerUp, x: point.x, y: point.y, mods: mods,
    clicks: clicks))
  doAssert interactionNative.frame()

when defined(macosx):
  const commandModifier = platform.modSuper
else:
  const commandModifier = platform.modCtrl

clickGrid(1)
doAssert appChosenItems.has("Apricot")
clickGrid(3, commandModifier)
doAssert appChosenItems.has("Blueberry")
doAssert interactionState.isSelected(1)
doAssert interactionState.isSelected(3)
clickGrid(6, platform.modShift)
doAssert interactionState.selectedItems() == @[3, 4, 5, 6]
doAssert appChosenItems.len == 4
doAssert interactionNative.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyUp, mods: platform.modShift))
doAssert interactionNative.frame()
doAssert interactionState.selected() == 2
doAssert interactionState.selectedItems() == @[2, 3]
doAssert interactionNative.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyA, mods: commandModifier))
doAssert interactionNative.frame()
doAssert interactionState.selectedItems().len == names.len
doAssert appChosenItems.len == names.len
doAssert interactionNative.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let (interactionTree, _) = interactionNative.accessibility()
var hasMultiSelectableList = false
var checkedGridItems = 0
for accessible in interactionTree.nodes:
  if accessible.role == platform.roleList and
      (accessible.states and platform.accessMultiselectable) !=
        platform.AccessStates(0):
    hasMultiSelectableList = true
  if accessible.role == platform.roleListItem and
      (accessible.states and platform.accessChecked) !=
        platform.AccessStates(0):
    inc checkedGridItems
doAssert hasMultiSelectableList
doAssert checkedGridItems == names.len

appChosenItems.clear()
appChosenItems.add("Apple")
interactionNative.requestFrame()
doAssert interactionNative.frame()
doAssert interactionState.selectedItems() == @[0],
  "app-side selection changes should update the grid"

doAssert interactionNative.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "c"))
doAssert interactionNative.frame()
doAssert interactionState.selected() == 4
doAssert interactionNative.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "c"))
doAssert interactionNative.frame()
doAssert interactionState.selected() == 5,
  "repeating a type-ahead character should cycle through matching labels"

clickGrid(5, clicks = 2)
doAssert interactionSubmitted,
  "double-clicking a grid item should submit it"

interactionState.select(5)
swap(names[1], names[5])
interactionNative.requestFrame()
doAssert interactionNative.frame()
doAssert interactionState.selected() == 1,
  "active selection should follow the item key when data is reordered"
doAssert interactionState.isSelected(1)

let dragStart = interactionPoint(1)
let dragEnd = (x: 40'f32, y: dragStart.y)
doAssert interactionNative.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: dragStart.x, y: dragStart.y))
discard interactionNative.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: dragEnd.x, y: dragEnd.y))
doAssert interactionNative.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: dragEnd.x, y: dragEnd.y))
doAssert reorderItems == @[1]
doAssert reorderBefore == 0,
  "dragging an item left of its neighbor should request insertion before it"

win.destroy()
interactionWin.destroy()
loop.shutdown()
