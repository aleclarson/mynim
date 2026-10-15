import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui list reorder test"))
app.initialized = true
app.handleReady()

var reorderedRows: seq[int]
var reorderedBefore = -1
var rowClicks = 0
let reorderState = ui.newListState(20, selectable = true,
  reorder = proc(rows: seq[int]; beforeRow: int) =
    reorderedRows = rows
    reorderedBefore = beforeRow
)
var reorderTheme = ui.lightTheme()
reorderTheme.accent = ui.rgb(255, 0, 0)
let reorderContent = ui.newContent(proc(ctx: ui.Context) =
  ctx.setTheme(reorderTheme)
  doAssert ctx.theme().accent == reorderTheme.accent
  discard ctx.list(reorderState, 5, proc(row: int) =
    discard ctx.box().size(100, 20).shrink(0)
      .onClick(proc() = inc rowClicks)
  ).size(100, 100)
)
let reorderWindow = newWindow(WindowOptions(width: 100, height: 100,
  hidden: true, content: reorderContent))
let reorderSurface = fake.windows[^1].surface

doAssert reorderSurface.frame()

# A press that stays below the drag threshold remains a normal button click.
doAssert reorderSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 10))
doAssert reorderSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 10))
doAssert reorderSurface.frame()
doAssert rowClicks == 1
doAssert reorderedRows.len == 0

# Moving a row shows an insertion marker and reports its original index.
doAssert reorderSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 10))
doAssert not reorderSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 5, y: 45))
doAssert reorderSurface.frame()
doAssert reorderSurface.pixel(50, 39) == [0'u8, 0, 255, 255]
doAssert reorderSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 45))
doAssert reorderSurface.frame()
doAssert reorderedRows == @[0]
doAssert reorderedBefore == 2
doAssert rowClicks == 1, "dragging a button row must suppress its click"

# Dropping immediately after a single row is a no-op.
reorderedRows.setLen(0)
reorderedBefore = -1
doAssert reorderSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 10))
discard reorderSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 5, y: 19))
doAssert reorderSurface.frame()
doAssert reorderSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 19))
doAssert reorderSurface.frame()
doAssert reorderedRows.len == 0

# An off-center destination after row 2 is still before row 3.
doAssert reorderSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 90))
doAssert not reorderSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 5, y: 55))
doAssert reorderSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 55))
doAssert reorderSurface.frame()
doAssert reorderedRows == @[4]
doAssert reorderedBefore == 3
doAssert rowClicks == 1

reorderWindow.destroy()

# Dragging a selected row moves the whole selection in list order.
var groupRows: seq[int]
var groupBefore = -1
let groupState = ui.newListState(20, multiSelectable = true,
  reorder = proc(rows: seq[int]; beforeRow: int) =
    groupRows = rows
    groupBefore = beforeRow
)
let groupContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.list(groupState, 5, proc(row: int) =
    discard ctx.box().size(100, 20).shrink(0)
  ).size(100, 100)
)
discard newWindow(WindowOptions(width: 100, height: 100, hidden: true,
  content: groupContent))
let groupSurface = fake.windows[^1].surface
doAssert groupSurface.frame()
when defined(macosx):
  const selectionCommand = platform.modSuper
else:
  const selectionCommand = platform.modCtrl
doAssert groupSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 50))
doAssert groupSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 50))
doAssert groupSurface.frame()
doAssert groupSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 10, mods: selectionCommand))
doAssert groupSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 10))
doAssert groupSurface.frame()
doAssert groupState.selectedRows() == @[2, 0]
doAssert groupSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 10))
doAssert not groupSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 5, y: 95))
doAssert groupSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 95))
doAssert groupSurface.frame()
doAssert groupRows == @[0, 2]
doAssert groupBefore == 5

# Section headers cannot begin a drag and are skipped while choosing a target.
var headerRows: seq[int]
var headerBefore = -1
let headerState = ui.newListState(20,
  rowHeader = proc(row: int): bool = row == 0,
  reorder = proc(rows: seq[int]; beforeRow: int) =
    headerRows = rows
    headerBefore = beforeRow
)
let headerContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.list(headerState, 5, proc(row: int) =
    discard ctx.box().size(100, 20).shrink(0)
  ).size(100, 100)
)
discard newWindow(WindowOptions(width: 100, height: 100, hidden: true,
  content: headerContent))
let headerSurface = fake.windows[^1].surface
doAssert headerSurface.frame()
doAssert headerSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 10))
doAssert not headerSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 5, y: 70))
discard headerSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 70))
doAssert headerSurface.frame()
doAssert headerRows.len == 0
doAssert headerSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 90))
doAssert not headerSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 5, y: 10))
doAssert headerSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 10))
doAssert headerSurface.frame()
doAssert headerRows == @[4]
doAssert headerBefore == 1

# A destination outside an ancestor clip is canceled even if it is within the
# list's own rectangle.
var clippedRows: seq[int]
let clippedState = ui.newListState(20,
  reorder = proc(rows: seq[int]; beforeRow: int) =
    clippedRows = rows
)
let clippedContent = ui.newContent(proc(ctx: ui.Context) =
  let clipper = ctx.box().size(100, 40).clip()
  discard clipper.children(proc() =
    discard ctx.list(clippedState, 5, proc(row: int) =
      discard ctx.box().size(100, 20).shrink(0)
    ).size(100, 100)
  )
)
discard newWindow(WindowOptions(width: 100, height: 100, hidden: true,
  content: clippedContent))
let clippedSurface = fake.windows[^1].surface
doAssert clippedSurface.frame()
doAssert clippedSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 10))
discard clippedSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 5, y: 70))
doAssert clippedSurface.frame()
doAssert clippedSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 70))
doAssert clippedSurface.frame()
doAssert clippedRows.len == 0

# Holding a dragged row at the viewport edge advances the virtual list.
var scrollRows: seq[int]
let scrollState = ui.newListState(20,
  reorder = proc(rows: seq[int]; beforeRow: int) =
    scrollRows = rows
)
let scrollContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.list(scrollState, 100, proc(row: int) =
    discard ctx.box().size(100, 20).shrink(0)
  ).size(100, 100)
)
discard newWindow(WindowOptions(width: 100, height: 100, hidden: true,
  content: scrollContent))
let scrollSurface = fake.windows[^1].surface
doAssert scrollSurface.frame()
doAssert scrollSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 30))
doAssert not scrollSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 5, y: 98))
doAssert scrollState.offset().y > 0
doAssert scrollSurface.frame()
discard scrollSurface.send(platform.SurfaceEvent(kind: platform.surfaceBlur))
doAssert scrollSurface.frame()
doAssert scrollRows.len == 0

loop.shutdown()
