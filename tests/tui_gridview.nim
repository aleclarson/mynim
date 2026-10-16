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

win.destroy()
loop.shutdown()
