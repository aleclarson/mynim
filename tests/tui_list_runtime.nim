import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

doAssert ui.lightTheme().accent == ui.rgb(37, 99, 235)
doAssert ui.darkTheme().dark
doAssert ui.lightTheme().space(2) == 8

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui list test"))
app.initialized = true
app.handleReady()

let listState = ui.newListState(20, selectable = true)
var builtRows: seq[int]
let listContent = ui.newContent(proc(ctx: ui.Context) =
  builtRows.setLen(0)
  discard ctx.list(listState, 100, proc(row: int) =
    builtRows.add(row)
    let color = if row mod 2 == 0: ui.rgb(255, 0, 0) else: ui.rgb(0, 255, 0)
    discard ctx.box().size(20, 20).shrink(0).background(color)
  ).size(20, 40)
)
let listWindow = newWindow(WindowOptions(width: 20, height: 40, hidden: true,
  content: listContent))
let listSurface = fake.windows[^1].surface

doAssert listSurface.frame()
doAssert builtRows.len < 100
doAssert listState.maxOffset().y == 1960

doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 5))
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 5))
doAssert listSurface.frame()
doAssert listState.selected() == 0,
  "click should select row 0, got " & $listState.selected()

doAssert listSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert listSurface.frame()
doAssert listState.selected() == 1

doAssert listSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyHome))
doAssert listSurface.frame()
doAssert listState.selected() == 0

discard listSurface.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 5, y: 5, dy: 100))
doAssert listState.offset().y == 100
doAssert listSurface.frame()
doAssert 5 in builtRows
doAssert listSurface.pixel(5, 5) == [0'u8, 255, 0, 255]

doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 5))
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 5))
doAssert listSurface.frame()
doAssert listState.selected() == 5

doAssert listSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert listSurface.frame()
doAssert listState.selected() == 99

let headerState = ui.newListState(20, selectable = true,
  rowLabel = proc(row: int): string = $row,
  rowHeader = proc(row: int): bool = row mod 5 == 0)
let headerContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.list(headerState, 20, proc(row: int) =
    if row mod 5 == 0:
      let color = case row
        of 0: ui.rgb(255, 0, 0)
        of 5: ui.rgb(0, 255, 0)
        else: ui.rgb(0, 0, 255)
      discard ctx.box().size(40, 30).shrink(0).background(color)
    else:
      discard ctx.box().size(40, 20).shrink(0)
  ).size(40, 60)
)
discard newWindow(WindowOptions(width: 40, height: 60, hidden: true,
  content: headerContent))
let headerSurface = fake.windows[^1].surface

doAssert headerSurface.frame()
doAssert headerSurface.pixel(10, 10) == [0'u8, 0, 255, 255]
doAssert headerSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let (headerTree, _) = headerSurface.accessibility()
var foundHeaderAccessNode = false
for accessible in headerTree.nodes:
  if accessible.role == platform.roleListItem and accessible.label == "0":
    doAssert (accessible.states and platform.accessSelectable) ==
      platform.AccessStates(0)
    doAssert (accessible.actions and platform.actionPress) ==
      platform.AccessActions(0)
    foundHeaderAccessNode = true
doAssert foundHeaderAccessNode
headerState.select(0)
doAssert headerState.selected() == -1
doAssert headerSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 35))
doAssert headerSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 35))
doAssert headerSurface.frame()
doAssert headerState.selected() == 1
doAssert headerSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyHome))
doAssert headerSurface.frame()
doAssert headerState.selected() == 1
discard headerSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyUp))
doAssert headerState.selected() == 1
headerState.select(4)
doAssert headerSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert headerSurface.frame()
doAssert headerState.selected() == 6,
  "keyboard navigation should skip section headers"

headerState.scrollTo(9)
discard headerSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert headerSurface.frame()
discard headerSurface.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 5, y: 55, dy: 30))
doAssert headerSurface.frame()
doAssert headerSurface.pixel(10, 5) == [0'u8, 255, 0, 255]
doAssert headerSurface.pixel(10, 25) == [255'u8, 0, 0, 255]
doAssert headerSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 5))
doAssert headerSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 5))
doAssert headerSurface.frame()
doAssert headerState.selected() == 6

var followCount = 100
let followState = ui.newListState(20, followEnd = true)
let followContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.list(followState, followCount, proc(row: int) =
    discard ctx.box().size(20, 20).shrink(0)
  ).size(20, 40)
)
discard newWindow(WindowOptions(width: 20, height: 40, hidden: true,
  content: followContent))
let followSurface = fake.windows[^1].surface

doAssert followSurface.frame()
doAssert followSurface.frame()
doAssert followState.offset().y == followState.maxOffset().y

discard followSurface.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 5, y: 5, dy: -100))
let scrolledAway = followState.offset().y
doAssert scrolledAway < followState.maxOffset().y
doAssert followSurface.frame()

followCount = 110
discard followSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert followSurface.frame()
doAssert followState.offset().y == scrolledAway
doAssert followState.offset().y < followState.maxOffset().y

discard followSurface.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 5, y: 5, dy: 10_000))
doAssert followSurface.frame()
doAssert followState.offset().y == followState.maxOffset().y

followCount = 120
discard followSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert followSurface.frame()
doAssert followState.offset().y == followState.maxOffset().y

var animatedFollowCount = 100
let animatedFollowState = ui.newListState(20, followEnd = true)
animatedFollowState.setFollowEndAnimation(ui.Animation(
  duration: initDuration(milliseconds = 100), ease: ui.linear))
let animatedFollowContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.list(animatedFollowState, animatedFollowCount, proc(row: int) =
    discard ctx.box().size(20, 20).shrink(0)
  ).size(20, 40)
)
discard newWindow(WindowOptions(width: 20, height: 40, hidden: true,
  content: animatedFollowContent))
let animatedFollowSurface = fake.windows[^1].surface

doAssert animatedFollowSurface.frame()
doAssert animatedFollowSurface.frame()
doAssert animatedFollowState.offset().y == animatedFollowState.maxOffset().y
animatedFollowCount = 110
discard animatedFollowSurface.send(platform.SurfaceEvent(
  kind: platform.surfaceResize))
doAssert animatedFollowSurface.frame()
doAssert animatedFollowState.offset().y == animatedFollowState.maxOffset().y
doAssert not animatedFollowState.atEnd()
os.sleep(130)
doAssert animatedFollowSurface.frame()
doAssert animatedFollowState.atEnd()

animatedFollowCount = 120
discard animatedFollowSurface.send(platform.SurfaceEvent(
  kind: platform.surfaceResize))
doAssert animatedFollowSurface.frame()
doAssert not animatedFollowState.atEnd()
doAssert animatedFollowState.offset().y == animatedFollowState.maxOffset().y

discard animatedFollowSurface.send(platform.SurfaceEvent(
  kind: platform.pointerScroll, x: 5, y: 5, dy: -10))
doAssert animatedFollowSurface.frame()
let animatedFollowInterrupted = animatedFollowState.offset().y
doAssert animatedFollowInterrupted < animatedFollowState.maxOffset().y
os.sleep(130)
doAssert animatedFollowSurface.frame()
doAssert animatedFollowState.offset().y == animatedFollowInterrupted
doAssert not animatedFollowState.atEnd()

animatedFollowCount = 130
discard animatedFollowSurface.send(platform.SurfaceEvent(
  kind: platform.surfaceResize))
doAssert animatedFollowSurface.frame()
doAssert animatedFollowState.offset().y == animatedFollowInterrupted
doAssert animatedFollowState.offset().y < animatedFollowState.maxOffset().y

let multiState = ui.newListState(20, multiSelectable = true)
var multiTheme = ui.lightTheme()
multiTheme.accent = ui.rgb(255, 0, 0)
multiTheme.accentText = ui.rgb(255, 255, 255)
multiTheme.focus = ui.rgb(0, 255, 255)
when defined(macosx):
  const selectionCommand = platform.modSuper
else:
  const selectionCommand = platform.modCtrl
let multiContent = ui.newContent(proc(ctx: ui.Context) =
  ctx.setTheme(multiTheme)
  discard ctx.list(multiState, 100, proc(row: int) =
    let label = ctx.text($row).size(20, 20).shrink(0)
    if row == 1:
      discard label.textColor(ui.rgb(0, 255, 0))
  ).size(20, 40)
)
discard newWindow(WindowOptions(width: 20, height: 40, hidden: true,
  content: multiContent))
let multiSurface = fake.windows[^1].surface

doAssert multiSurface.frame()
doAssert multiSurface.frame()
doAssert multiSurface.pixel(19, 19) == [255'u8, 255, 255, 255]
doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 5))
doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 5))
doAssert multiSurface.frame()
doAssert multiState.selectedRows() == @[0]
doAssert multiSurface.pixel(19, 19) == [0'u8, 0, 255, 255]
var selectedDefaultTextIsWhite = false
for y in 0..<20:
  for x in 0..<20:
    if multiSurface.pixel(x, y) == [255'u8, 255, 255, 255]:
      selectedDefaultTextIsWhite = true
doAssert selectedDefaultTextIsWhite

doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 25, mods: selectionCommand))
doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 25))
doAssert multiSurface.frame()
doAssert multiState.selected() == 1
doAssert multiState.selectedRows() == @[0, 1]
doAssert multiSurface.pixel(19, 39) == [0'u8, 0, 255, 255]
var selectedExplicitTextIsGreen = false
for y in 20..<40:
  for x in 0..<20:
    if multiSurface.pixel(x, y) == [0'u8, 255, 0, 255]:
      selectedExplicitTextIsGreen = true
doAssert selectedExplicitTextIsGreen

doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown, mods: platform.modShift))
doAssert multiSurface.frame()
when defined(macosx):
  doAssert multiState.selectedRows() == @[0, 1, 2]
else:
  doAssert multiState.selectedRows() == @[1, 2]

doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown, mods: selectionCommand or platform.modShift))
doAssert multiSurface.frame()
when defined(macosx):
  doAssert multiState.selectedRows() == @[0, 1, 2, 3]
else:
  doAssert multiState.selectedRows() == @[1, 2, 3]
  doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keyUp, mods: platform.modCtrl))
  doAssert multiSurface.frame()
  doAssert multiState.selected() == 2
  doAssert multiState.selectedRows() == @[1, 2, 3]

  doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keySpace, mods: platform.modCtrl))
  doAssert multiSurface.frame()
  doAssert multiState.selectedRows() == @[1, 3]
  doAssert multiSurface.pixel(10, 40) == [255'u8, 255, 0, 255]

doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyA, mods: selectionCommand))
doAssert multiSurface.frame()
doAssert multiState.selectedRows().len == 100
doAssert multiState.isSelected(99)
doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let (multiAccessTree, _) = multiSurface.accessibility()
doAssert multiAccessTree != nil
var foundMultiList = false
var foundMultiItem = false
for accessible in multiAccessTree.nodes:
  if accessible.role == platform.roleList:
    foundMultiList = true
    doAssert (accessible.states and platform.accessMultiselectable) !=
      platform.AccessStates(0)
  elif accessible.role == platform.roleListItem and
      (accessible.states and platform.accessSelected) != platform.AccessStates(0):
    doAssert (accessible.states and platform.accessSelectable) !=
      platform.AccessStates(0)
    foundMultiItem = true
doAssert foundMultiList and foundMultiItem

let systemThemeState = ui.newListState(20, selectable = true)
let systemThemeContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.list(systemThemeState, 1, proc(row: int) =
    discard ctx.text($row).size(20, 20).shrink(0)
  ).size(20, 20)
)
discard newWindow(WindowOptions(width: 20, height: 20, hidden: true,
  content: systemThemeContent))
let systemThemeSurface = fake.windows[^1].surface
fake.setPreferences(platform.Preferences(
  accent: platform.Color(r: 255, a: 255), textScale: 1))
doAssert systemThemeSurface.frame()
doAssert systemThemeSurface.send(platform.SurfaceEvent(
  kind: platform.pointerDown, x: 5, y: 5))
doAssert systemThemeSurface.send(platform.SurfaceEvent(
  kind: platform.pointerUp, x: 5, y: 5))
doAssert systemThemeSurface.frame()
doAssert systemThemeState.selected() == 0
doAssert systemThemeSurface.pixel(19, 19) == [0'u8, 0, 255, 255]
var systemAccentTextIsWhite = false
for y in 0..<20:
  for x in 0..<20:
    if systemThemeSurface.pixel(x, y) == [255'u8, 255, 255, 255]:
      systemAccentTextIsWhite = true
doAssert systemAccentTextIsWhite

fake.setPreferences(platform.Preferences(
  accent: platform.Color(r: 255, g: 255, a: 255), textScale: 1))
doAssert systemThemeSurface.frame()
doAssert systemThemeSurface.pixel(19, 19) == [0'u8, 255, 255, 255]
var systemAccentTextIsDark = false
for y in 0..<20:
  for x in 0..<20:
    if systemThemeSurface.pixel(x, y) == [27'u8, 24, 24, 255]:
      systemAccentTextIsDark = true
doAssert systemAccentTextIsDark

let searchState = ui.newListState(20, rowLabel = proc(row: int): string =
  case row
  of 10: "Folder"
  of 11: "File"
  else: "Row " & $row
)
let searchContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.list(searchState, 100, proc(row: int) =
    discard ctx.box().size(20, 20).shrink(0)
  ).size(20, 40)
)
discard newWindow(WindowOptions(width: 20, height: 40, hidden: true,
  content: searchContent))
let searchSurface = fake.windows[^1].surface

doAssert searchSurface.frame()
doAssert searchSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 5))
doAssert searchSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 5))
doAssert searchSurface.frame()
doAssert searchSurface.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "f"))
doAssert searchSurface.frame()
doAssert searchState.selected() == 10
doAssert searchSurface.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "f"))
doAssert searchSurface.frame()
doAssert searchState.selected() == 11

let unicodeSearchState = ui.newListState(20,
  rowLabel = proc(row: int): string =
    case row
    of 10: "Éclair"
    of 11: "École"
    else: "Row " & $row
)
let unicodeSearchContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.list(unicodeSearchState, 100, proc(row: int) =
    discard ctx.box().size(20, 20).shrink(0)
  ).size(20, 40)
)
discard newWindow(WindowOptions(width: 20, height: 40, hidden: true,
  content: unicodeSearchContent))
let unicodeSearchSurface = fake.windows[^1].surface

doAssert unicodeSearchSurface.frame()
doAssert unicodeSearchSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 5))
doAssert unicodeSearchSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 5))
doAssert unicodeSearchSurface.frame()
doAssert unicodeSearchSurface.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "É"))
doAssert unicodeSearchSurface.frame()
doAssert unicodeSearchState.selected() == 10
doAssert unicodeSearchSurface.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "c"))
doAssert unicodeSearchSurface.frame()
doAssert unicodeSearchState.selected() == 10
doAssert unicodeSearchSurface.send(
  platform.SurfaceEvent(kind: platform.accessibilityOn))
let (unicodeSearchTree, _) = unicodeSearchSurface.accessibility()
var foundLabeledSelectedRow = false
for accessible in unicodeSearchTree.nodes:
  if accessible.label == "Éclair":
    doAssert accessible.role == platform.roleListItem
    doAssert (accessible.states and platform.accessSelected) !=
      platform.AccessStates(0)
    foundLabeledSelectedRow = true
doAssert foundLabeledSelectedRow
