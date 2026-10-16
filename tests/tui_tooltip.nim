import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc node(tree: ref platform.AccessTree; role: platform.AccessRole;
          label: string): platform.AccessNode =
  if tree != nil:
    for item in tree.nodes:
      if item.role == role and item.label == label:
        return item
  raise newException(AssertionDefect,
    "missing access node " & $role & " labeled " & label)

proc hasTooltip(tree: ref platform.AccessTree): bool =
  if tree != nil:
    for item in tree.nodes:
      if item.role == platform.roleTooltip:
        return true

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui tooltip test"))
app.initialized = true
app.handleReady()

let focusContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.row().size(180, 40).tooltip("Toolbar").children(proc() =
    discard ctx.button("Save").tooltip("Saves the file")
  )
  discard ctx.button("Other")
  let custom = ctx.button("Custom")
  discard ctx.tooltipBase(custom, proc(tip: ui.Element) =
    discard tip.padding(4).background(ui.rgb(20, 30, 40)).children(proc() =
      discard ctx.text("Custom popup")
    )
  )
)
let focusWindow = newWindow(WindowOptions(width: 220, height: 100,
  hidden: true, content: focusContent))
let focusSurface = fake.windows[^1].surface
doAssert focusSurface.frame()
doAssert focusSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = focusSurface.accessibility()[0]
doAssert tree != nil
doAssert not tree.hasTooltip()
let saveNode = tree.node(platform.roleButton, "Save")
doAssert saveNode.description == "Saves the file"

# Keyboard focus shows the innermost tooltip at once.
doAssert focusSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert focusSurface.frame()
tree = focusSurface.accessibility()[0]
doAssert tree.hasTooltip()
var sawSaveTip = false
for item in tree.nodes:
  if item.role == platform.roleText and item.label == "Saves the file":
    sawSaveTip = true
doAssert sawSaveTip

# Escape dismisses the focused tooltip until focus leaves its anchor.
doAssert focusSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEscape))
doAssert focusSurface.frame()
tree = focusSurface.accessibility()[0]
doAssert not tree.hasTooltip()
doAssert focusSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert focusSurface.frame()
doAssert focusSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab, mods: platform.modShift))
doAssert focusSurface.frame()
tree = focusSurface.accessibility()[0]
doAssert tree.hasTooltip()

doAssert focusSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert focusSurface.frame()
doAssert focusSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert focusSurface.frame()
tree = focusSurface.accessibility()[0]
doAssert tree.hasTooltip()
var sawCustomTip = false
for item in tree.nodes:
  if item.role == platform.roleText and item.label == "Custom popup":
    sawCustomTip = true
doAssert sawCustomTip

var underlayClicks = 0
let hoverContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().size(240, 160).tooltip("Toolbar").children(proc() =
    discard ctx.box().absolute().left(0).top(0).size(240, 160)
      .onClick(proc() = inc underlayClicks)
    discard ctx.button("Hover").tooltip("Pointer help")
  )
)
let hoverWindow = newWindow(WindowOptions(width: 240, height: 160,
  hidden: true, content: hoverContent))
let hoverSurface = fake.windows[^1].surface
doAssert hoverSurface.frame()
doAssert hoverSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
tree = hoverSurface.accessibility()[0]
let hoverButton = tree.node(platform.roleButton, "Hover")
let pointerX = hoverButton.bounds.x + hoverButton.bounds.w / 2
let pointerY = hoverButton.bounds.y + hoverButton.bounds.h / 2
discard hoverSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: pointerX, y: pointerY))
doAssert hoverSurface.frame()
tree = hoverSurface.accessibility()[0]
doAssert not tree.hasTooltip()

# Let the pointer rest past the upstream 600 ms delay.
os.sleep(625)
doAssert hoverSurface.frame()
tree = hoverSurface.accessibility()[0]
doAssert tree.hasTooltip()
let tipNode = tree.node(platform.roleTooltip, "")
doAssert tipNode.bounds.y >= hoverButton.bounds.y + hoverButton.bounds.h

# The tooltip subtree passes pointer input through to the element below it.
let clickX = tipNode.bounds.x + tipNode.bounds.w / 2
let clickY = tipNode.bounds.y + tipNode.bounds.h / 2
discard hoverSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: clickX, y: clickY))
doAssert hoverSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: clickX, y: clickY))
doAssert hoverSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: clickX, y: clickY))
doAssert hoverSurface.frame()
doAssert underlayClicks == 1

hoverWindow.destroy()
focusWindow.destroy()
loop.shutdown()
