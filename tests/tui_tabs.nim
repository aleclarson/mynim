import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc tabId(tree: ref platform.AccessTree; label: string): uint64 =
  if tree != nil:
    for node in tree.nodes:
      if node.role == platform.roleTab and node.label == label:
        return node.id

proc tabStates(tree: ref platform.AccessTree; label: string):
    platform.AccessStates =
  if tree != nil:
    for node in tree.nodes:
      if node.role == platform.roleTab and node.label == label:
        return node.states

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui tabs test"))
app.initialized = true
app.handleReady()

var selected = 1
var changeCount = 0
var changedDuringBuild = false
let tabsContent = ui.newContent(proc(ctx: ui.Context) =
  let parts = ctx.tabsBase(selected, 3)
  let list = parts.list().gap(4)
  discard list.children(proc() =
    for index, label in ["General", "Appearance", "Advanced"]:
      let tab = parts.tab(index).label(label)
      discard tab.children(proc() = discard ctx.text(label))
  )
  changedDuringBuild = parts.changed()
  discard list.onChange(proc() = inc(changeCount))
)
let win = newWindow(WindowOptions(width: 360, height: 100, hidden: true,
  content: tabsContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert selected == 1
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
doAssert tree != nil
var foundTabList = false
for node in tree.nodes:
  if node.role == platform.roleTabList:
    foundTabList = true
doAssert foundTabList
let appearanceId = tabId(tree, "Appearance")
let advancedId = tabId(tree, "Advanced")
doAssert appearanceId > 0 and advancedId > 0
doAssert (tabStates(tree, "Appearance") and platform.accessSelected) !=
  platform.AccessStates(0)
doAssert (tabStates(tree, "General") and platform.accessSelected) ==
  platform.AccessStates(0)

# A tab list is one Tab stop, beginning at its selected tab.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.focus == appearanceId

# Arrow navigation both moves focus and changes selection.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert native.frame()
doAssert selected == 2 and changedDuringBuild and changeCount == 1
tree = native.accessibility()[0]
doAssert tree.focus == advancedId
doAssert (tabStates(tree, "Advanced") and platform.accessSelected) !=
  platform.AccessStates(0)

# Home and End select the first/last tab; the arrow keys wrap.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyHome))
doAssert native.frame()
doAssert selected == 0 and changeCount == 2
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert native.frame()
doAssert selected == 2 and changeCount == 3
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert native.frame()
doAssert selected == 0 and changeCount == 4

# Assistive technology can select an inactive tab with its press action.
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: appearanceId, action: platform.accessPress))
doAssert native.frame()
doAssert selected == 1 and changeCount == 5
doAssert (tabStates(native.accessibility()[0], "Appearance") and
  platform.accessSelected) != platform.AccessStates(0)

win.destroy()

var themedSelected = 0
var themedChangeCount = 0
let themedContent = ui.newContent(proc(ctx: ui.Context) =
  let tabs = ctx.tabs(themedSelected, ["One", "Two"])
  discard tabs.onChange(proc() = inc(themedChangeCount))
)
let themedWindow = newWindow(WindowOptions(width: 220, height: 70,
  hidden: true, content: themedContent))
let themedSurface = fake.windows[^1].surface
doAssert themedSurface.frame()
doAssert themedSurface.send(platform.SurfaceEvent(
  kind: platform.accessibilityOn))
tree = themedSurface.accessibility()[0]
let twoId = tabId(tree, "Two")
doAssert twoId > 0
doAssert themedSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: twoId, action: platform.accessPress))
doAssert themedSurface.frame()
doAssert themedSelected == 1 and themedChangeCount == 1
doAssert (tabStates(themedSurface.accessibility()[0], "Two") and
  platform.accessSelected) != platform.AccessStates(0)
themedWindow.destroy()

loop.shutdown()
