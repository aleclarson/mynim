import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui editable text test"))
app.initialized = true
app.handleReady()

var fileTitle = "report.md"
var titleValueChanged: bool
let titleContent = ui.newContent(proc(ctx: ui.Context) =
  let titleElement = ctx.editableText(fileTitle)
  titleValueChanged = titleElement.changed()
  discard ctx.text("Other").focusable()
)
discard newWindow(WindowOptions(width: 220, height: 90, hidden: true,
  content: titleContent))
let titleSurface = fake.windows[^1].surface

doAssert titleSurface.frame()
doAssert titleSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 5, button: 0))
doAssert titleSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 5, button: 0, clicks: 2))
doAssert titleSurface.frame()
var textState = titleSurface.lastTextInput()
doAssert textState.active and textState.text == "report.md"
doAssert textState.start == 0 and textState.`end` == 6

doAssert titleSurface.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "notes", replace: true, `from`: 0, to: 6))
doAssert titleSurface.frame()
doAssert fileTitle == "report.md" and not titleValueChanged
doAssert titleSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert titleSurface.frame()
doAssert fileTitle == "notes.md" and titleValueChanged

titleValueChanged = false
doAssert titleSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 5, button: 0))
doAssert titleSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 5, button: 0, clicks: 2))
doAssert titleSurface.frame()
let selectAllMods = when defined(macosx): platform.modSuper else: platform.modCtrl
doAssert titleSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyA, mods: selectAllMods))
doAssert titleSurface.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "discarded"))
doAssert titleSurface.frame()
doAssert titleSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEscape))
doAssert titleSurface.frame()
doAssert fileTitle == "notes.md" and not titleValueChanged

doAssert titleSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert titleSurface.frame()
doAssert titleSurface.lastTextInput().active
doAssert titleSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyA, mods: selectAllMods))
doAssert titleSurface.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "plan"))
doAssert titleSurface.frame()
doAssert titleSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert titleSurface.frame()
doAssert fileTitle == "plan" and titleValueChanged

var names = @[
  "alpha.txt",
  "beta.txt",
]
var editableListSubmitted: bool
let listState = ui.newListState(28, selectable = true,
  rowKey = proc(row: int): string = names[row])
let listContent = ui.newContent(proc(ctx: ui.Context) =
  let list = ctx.list(listState, names.len, proc(row: int) =
    discard ctx.editableText(names[row])
  ).size(180, 56)
  editableListSubmitted = list.submitted()
)
discard newWindow(WindowOptions(width: 180, height: 70, hidden: true,
  content: listContent))
let listSurface = fake.windows[^1].surface
doAssert listSurface.frame()
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 5, button: 0))
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 5, button: 0, clicks: 1))
doAssert listSurface.frame()
doAssert listState.selected() == 0
sleep(550)
doAssert listSurface.frame()
doAssert listSurface.lastTextInput().active

doAssert listSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEscape))
doAssert listSurface.frame()
let editRowKey = when defined(macosx): platform.keyEnter else: platform.keyF2
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: editRowKey))
doAssert listSurface.frame()
doAssert listSurface.lastTextInput().active

doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 5, button: 0))
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 5, button: 0, clicks: 2))
doAssert listSurface.frame()
doAssert editableListSubmitted
