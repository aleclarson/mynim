import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc accessId(tree: ref platform.AccessTree; role: platform.AccessRole;
              label: string): uint64 =
  if tree != nil:
    for node in tree.nodes:
      if node.role == role and node.label == label:
        return node.id

proc accessNode(tree: ref platform.AccessTree; id: uint64):
    platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.id == id:
        return node

proc accessIndex(tree: ref platform.AccessTree; id: uint64): int =
  if tree != nil:
    for index, node in tree.nodes:
      if node.id == id:
        return index
  -1

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui sidebar test"))
app.initialized = true
app.handleReady()

let sidebarState = ui.newSidebarState("recents")
let locations = ui.newSidebarSectionState(open = true)
var changedBuilds = 0
var changeCalls = 0
let sidebarContent = ui.newContent(proc(ctx: ui.Context) =
  let row = ctx.row().fill().alignItems(ui.Align.Stretch)
  discard row.children(proc() =
    let sidebar = ctx.sidebar(sidebarState, proc() =
      discard ctx.sidebarSection("Favorites", proc() =
        discard ctx.sidebarItem("recents", "Recents")
        discard ctx.sidebarItem("desktop", "Desktop",
          buildAccessory = proc() = discard ctx.badge("3"))
        discard ctx.sidebarItem("documents", "Documents")
      )
      discard ctx.sidebarSection("Locations", locations, proc() =
        discard ctx.sidebarItem("mac", "Macintosh HD")
      )
    ).width(200)
    if sidebar.changed():
      inc changedBuilds
    discard sidebar.onChange(proc() = inc changeCalls)
    discard ctx.button("Other")
  )
)
let win = newWindow(WindowOptions(width: 500, height: 280, hidden: true,
  content: sidebarContent))
let native = fake.windows[^1].surface
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
let sidebarId = accessId(tree, platform.roleTree, "")
let favoritesId = accessId(tree, platform.roleTreeItem, "Favorites")
let recentsId = accessId(tree, platform.roleTreeItem, "Recents")
let desktopId = accessId(tree, platform.roleTreeItem, "Desktop 3")
let documentsId = accessId(tree, platform.roleTreeItem, "Documents")
let locationsId = accessId(tree, platform.roleTreeItem, "Locations")
let macId = accessId(tree, platform.roleTreeItem, "Macintosh HD")
doAssert sidebarId > 0 and favoritesId > 0 and recentsId > 0 and desktopId > 0 and
  documentsId > 0 and locationsId > 0 and macId > 0
doAssert (accessNode(tree, sidebarId).states and platform.accessSelectable) !=
  platform.AccessStates(0)
doAssert accessNode(tree, desktopId).level == 2
doAssert accessNode(tree, desktopId).label == "Desktop 3"
doAssert accessNode(tree, locationsId).parent == accessIndex(tree, sidebarId)
doAssert accessNode(tree, desktopId).parent == accessIndex(tree, favoritesId)
doAssert accessNode(tree, macId).parent == accessIndex(tree, locationsId)
doAssert (accessNode(tree, recentsId).states and platform.accessChecked) !=
  platform.AccessStates(0)

# Tab enters at the selected descendant. Arrow navigation crosses sections.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.focus == recentsId
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert native.frame()
doAssert sidebarState.selected == "desktop" and changedBuilds == 1 and
  changeCalls == 1
tree = native.accessibility()[0]
doAssert tree.focus == desktopId
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert native.frame()
doAssert sidebarState.selected == "documents"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert native.frame()
doAssert sidebarState.selected == "mac"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert native.frame()
doAssert sidebarState.selected == "mac",
  "Down should stop at the last visible item"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyHome))
doAssert native.frame()
doAssert sidebarState.selected == "recents"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert native.frame()
doAssert sidebarState.selected == "mac"

# Unicode text input cycles by prefix and moves focus to the match.
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "d"))
doAssert native.frame()
doAssert sidebarState.selected == "desktop"
tree = native.accessibility()[0]
doAssert tree.focus == desktopId
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "d"))
doAssert native.frame()
doAssert sidebarState.selected == "documents",
  "repeating a letter should cycle to the next matching item"
doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "o"))
doAssert native.frame()
doAssert sidebarState.selected == "documents"

# Pointer selection uses the same change callback as keyboard navigation.
tree = native.accessibility()[0]
let desktopBounds = accessNode(tree, desktopId).bounds
let previousChangeCalls = changeCalls
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: desktopBounds.x + desktopBounds.w / 2,
  y: desktopBounds.y + desktopBounds.h / 2))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: desktopBounds.x + desktopBounds.w / 2,
  y: desktopBounds.y + desktopBounds.h / 2))
doAssert native.frame()
doAssert sidebarState.selected == "desktop"
doAssert changeCalls == previousChangeCalls + 1

# Section disclosure is represented as an expandable tree item and can be
# collapsed or expanded by assistive technology.
doAssert (accessNode(tree, locationsId).states and platform.accessExpandable) !=
  platform.AccessStates(0)
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: locationsId, action: platform.accessCollapse))
doAssert native.frame()
doAssert not locations.open
tree = native.accessibility()[0]
doAssert accessId(tree, platform.roleTreeItem, "Macintosh HD") == 0
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: locationsId, action: platform.accessExpand))
doAssert native.frame()
doAssert locations.open
tree = native.accessibility()[0]
let locationsBounds = accessNode(tree, locationsId).bounds
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: locationsBounds.x + 8, y: locationsBounds.y + 8))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: locationsBounds.x + 8, y: locationsBounds.y + 8))
doAssert native.frame()
doAssert not locations.open
tree = native.accessibility()[0]
let locationsReopenedId = accessId(tree, platform.roleTreeItem, "Locations")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: locationsReopenedId, action: platform.accessExpand))
doAssert native.frame()
doAssert locations.open

# Focusing a tree item through accessibility selects it, and one Tab stop
# leaves the Sidebar for the following button.
tree = native.accessibility()[0]
let macNow = accessId(tree, platform.roleTreeItem, "Macintosh HD")
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: macNow, action: platform.accessFocus))
doAssert native.frame()
doAssert sidebarState.selected == "mac"
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: locationsId, action: platform.accessCollapse))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert native.frame()
doAssert sidebarState.selected == "documents",
  "End should skip items in a collapsed section"
tree = native.accessibility()[0]
let locationsNow = accessId(tree, platform.roleTreeItem, "Locations")
doAssert locationsNow > 0
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: locationsNow, action: platform.accessExpand))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
let otherId = accessId(tree, platform.roleButton, "Other")
doAssert otherId > 0 and tree.focus == otherId

win.destroy()
loop.shutdown()
