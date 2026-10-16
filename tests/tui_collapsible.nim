import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc accessId(tree: ref platform.AccessTree; role: platform.AccessRole;
              label: string): uint64 =
  if tree == nil:
    return
  for node in tree.nodes:
    if node.role == role and node.label == label:
      return node.id

proc hasAccessLabel(tree: ref platform.AccessTree; label: string): bool =
  if tree != nil:
    for node in tree.nodes:
      if node.label == label:
        return true

proc focusedLabel(tree: ref platform.AccessTree): string =
  if tree != nil:
    for node in tree.nodes:
      if node.id == tree.focus:
        return node.label

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui collapsible test"))
app.initialized = true
app.handleReady()
fake.setPreferences(platform.Preferences(reduceMotion: true))

var advancedOpen = false
var disclosureChanged = false
var changeCount = 0
let disclosureContent = ui.newContent(proc(ctx: ui.Context) =
  let disclosure = ctx.collapsible("Advanced", advancedOpen, proc() =
    discard ctx.text("Inside")
    discard ctx.button("Inner")
  )
  disclosureChanged = disclosure.changed()
  discard disclosure.onChange(proc() = inc(changeCount))
)
let disclosureWindow = newWindow(WindowOptions(width: 240, height: 180,
  hidden: true, content: disclosureContent))
let disclosureSurface = fake.windows[^1].surface
doAssert disclosureSurface.frame()
doAssert disclosureSurface.send(platform.SurfaceEvent(
  kind: platform.accessibilityOn))
var tree = disclosureSurface.accessibility()[0]
let advancedId = accessId(tree, platform.roleDisclosure, "Advanced")
doAssert advancedId > 0
for node in tree.nodes:
  if node.id == advancedId:
    doAssert (node.states and platform.accessExpanded) ==
      platform.AccessStates(0)
    doAssert (node.actions and platform.actionPress) !=
      platform.AccessActions(0)
doAssert not tree.hasAccessLabel("Inside")

doAssert disclosureSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: advancedId, action: platform.accessPress))
doAssert disclosureSurface.frame()
doAssert advancedOpen and disclosureChanged and changeCount == 1
tree = disclosureSurface.accessibility()[0]
doAssert tree.hasAccessLabel("Inside")
let innerId = accessId(tree, platform.roleButton, "Inner")
doAssert innerId > 0
for node in tree.nodes:
  if node.id == advancedId:
    doAssert (node.states and platform.accessExpanded) ==
      platform.accessExpanded

doAssert disclosureSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert disclosureSurface.frame()
tree = disclosureSurface.accessibility()[0]
doAssert tree.focus == innerId
doAssert disclosureSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  mods: platform.modShift, key: platform.keyTab))
doAssert disclosureSurface.frame()
tree = disclosureSurface.accessibility()[0]
doAssert tree.focus == advancedId
doAssert disclosureSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace))
doAssert disclosureSurface.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keySpace))
doAssert disclosureSurface.frame()
doAssert not advancedOpen and disclosureChanged and changeCount == 2
doAssert not disclosureSurface.accessibility()[0].hasAccessLabel("Inside")

disclosureWindow.destroy()

var general = true
var privacy = false
var advanced = false
let accordionContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.accordion(proc() =
    discard ctx.accordionItem("General", general, proc() =
      discard ctx.button("Save")
    )
    discard ctx.accordionItem("Privacy", privacy, proc() =
      discard ctx.text("Tracking")
    )
    discard ctx.accordionItem("Advanced", advanced, proc() =
      discard ctx.text("Logs")
    )
  )
)
let accordionWindow = newWindow(WindowOptions(width: 300, height: 240,
  hidden: true, content: accordionContent))
let accordionSurface = fake.windows[^1].surface
doAssert accordionSurface.frame()
doAssert accordionSurface.send(platform.SurfaceEvent(
  kind: platform.accessibilityOn))
tree = accordionSurface.accessibility()[0]
let generalId = accessId(tree, platform.roleDisclosure, "General")
let privacyId = accessId(tree, platform.roleDisclosure, "Privacy")
let accordionAdvancedId = accessId(tree, platform.roleDisclosure, "Advanced")
doAssert generalId > 0 and privacyId > 0 and accordionAdvancedId > 0
doAssert tree.hasAccessLabel("Save") and not tree.hasAccessLabel("Tracking")

doAssert accordionSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: generalId, action: platform.accessPress))
doAssert accordionSurface.frame()
tree = accordionSurface.accessibility()[0]
doAssert not general and not tree.hasAccessLabel("Save")
for step in [
    (platform.keyDown, "Privacy"),
    (platform.keyDown, "Advanced"),
    (platform.keyDown, "Advanced"),
    (platform.keyHome, "General"),
    (platform.keyUp, "General"),
    (platform.keyEnd, "Advanced"),
    (platform.keyUp, "Privacy")]:
  doAssert accordionSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: step[0]))
  doAssert accordionSurface.frame()
  tree = accordionSurface.accessibility()[0]
  doAssert tree.focusedLabel() == step[1],
    $step[0] & " focused " & tree.focusedLabel()

doAssert accordionSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert accordionSurface.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keyEnter))
doAssert accordionSurface.frame()
doAssert privacy and accordionSurface.accessibility()[0].hasAccessLabel("Tracking")
accordionWindow.destroy()

var baseOpen = false
var baseProgress = 0'f32
var basePanelBuilt = false
var baseChanged = false
fake.setPreferences(platform.Preferences(reduceMotion: false))
let baseContent = ui.newContent(proc(ctx: ui.Context) =
  basePanelBuilt = false
  let parts = ctx.collapsibleBase(baseOpen)
  baseProgress = parts.progress()
  let trigger = parts.trigger().label("More")
  discard trigger.children(proc() = discard ctx.text("More"))
  baseChanged = trigger.changed()
  discard parts.panel(proc() =
    basePanelBuilt = true
    for _ in 0..<4:
      discard ctx.text("Line")
  )
)
let baseWindow = newWindow(WindowOptions(width: 260, height: 220,
  hidden: true, content: baseContent))
let baseSurface = fake.windows[^1].surface
doAssert baseSurface.frame()
doAssert not basePanelBuilt and baseProgress == 0
doAssert baseSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
tree = baseSurface.accessibility()[0]
let moreId = accessId(tree, platform.roleDisclosure, "More")
doAssert moreId > 0
doAssert baseSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: moreId, action: platform.accessPress))
doAssert baseSurface.frame()
doAssert baseOpen and baseChanged and basePanelBuilt
sleep(50)
doAssert baseSurface.frame()
doAssert baseProgress > 0 and baseProgress < 1, $baseProgress
doAssert basePanelBuilt
sleep(220)
doAssert baseSurface.frame()
doAssert baseProgress == 1 and basePanelBuilt
doAssert baseSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert baseSurface.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keyEnter))
doAssert baseSurface.frame()
doAssert not baseOpen and basePanelBuilt
sleep(50)
doAssert baseSurface.frame()
doAssert baseProgress > 0 and baseProgress < 1, $baseProgress
doAssert basePanelBuilt
sleep(220)
doAssert baseSurface.frame()
doAssert baseProgress == 0 and not basePanelBuilt
fake.setPreferences(platform.Preferences(reduceMotion: true))
doAssert baseSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert baseSurface.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keyEnter))
doAssert baseSurface.frame()
doAssert baseOpen and baseProgress == 1 and basePanelBuilt
baseWindow.destroy()

var measuredOpen = false
var measuredProgress = 0'f32
var measuredBuilt = false
var afterPanel: ui.Element
let measuredContext = ui.newContext()
proc measuredView(ctx: ui.Context) =
  measuredBuilt = false
  discard ctx.column().children(proc() =
    let parts = ctx.collapsibleBase(measuredOpen)
    measuredProgress = parts.progress()
    discard parts.trigger().height(24)
    discard parts.panel(proc() =
      measuredBuilt = true
      for _ in 0..<4:
        discard ctx.text("Measured line")
    )
    afterPanel = ctx.text("After")
  )

measuredContext.build(measuredView)
let closedY = measuredContext.layout(240, 220).bounds(afterPanel).y
doAssert not measuredBuilt
measuredOpen = true
measuredContext.build(measuredView)
let startY = measuredContext.layout(240, 220).bounds(afterPanel).y
doAssert measuredBuilt
sleep(50)
measuredContext.build(measuredView)
let middleY = measuredContext.layout(240, 220).bounds(afterPanel).y
doAssert measuredBuilt
doAssert measuredProgress > 0 and measuredProgress < 1, $measuredProgress
sleep(220)
measuredContext.build(measuredView)
let openY = measuredContext.layout(240, 220).bounds(afterPanel).y
doAssert measuredBuilt
doAssert middleY > startY and middleY < openY,
  "the panel's measured height should grow with animation: start " &
    $startY & ", middle " & $middleY & ", open " & $openY

measuredOpen = false
measuredContext.build(measuredView)
discard measuredContext.layout(240, 220)
sleep(50)
measuredContext.build(measuredView)
let closingY = measuredContext.layout(240, 220).bounds(afterPanel).y
doAssert measuredProgress > 0 and measuredProgress < 1, $measuredProgress
doAssert closingY > closedY and closingY < openY,
  "the panel's measured height should shrink with animation"
sleep(220)
measuredContext.build(measuredView)
let closedAgainY = measuredContext.layout(240, 220).bounds(afterPanel).y
doAssert abs(closedAgainY - closedY) < 0.1'f32
measuredContext.close()
loop.shutdown()
