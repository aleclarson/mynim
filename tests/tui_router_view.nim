import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc accessNode(tree: ref platform.AccessTree; role: platform.AccessRole;
                label: string): platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == role and node.label == label:
        return node
  raise newException(AssertionDefect, "missing accessibility node " & label)

proc activate(native: fakeBackend.FakeSurface; node: platform.AccessNode) =
  doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
    id: node.id, action: platform.accessFocus))
  doAssert native.frame()
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keyEnter))
  doAssert native.frame()
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
    key: platform.keyEnter))
  doAssert native.frame()

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui router view test"))
app.initialized = true
app.handleReady()

let router = ui.newRouter("/settings/general")
var shownPath, sectionParam = ""
var contextRouterMatches = false
var contextRouterRestored = false
let routerContent = ui.newContent(proc(ctx: ui.Context) =
  discard router.view(ctx, proc(route: ui.Route) =
    if route.match("/settings/{section...}"):
      route.title("Settings")
      discard ctx.row().children(proc() =
        discard ctx.backButton()
        discard ctx.forwardButton()
      )
      discard route.view(ctx, proc(inner: ui.Route) =
        shownPath = inner.path()
        sectionParam = inner.param("section")
        contextRouterMatches = ctx.router() == router
        if inner.match("/general"):
          inner.title("General")
          discard ctx.link("Fonts", "/settings/fonts")
        elif inner.match("/fonts"):
          inner.title("Fonts")
          discard ctx.link("General", "/settings/general")
        else:
          discard ctx.text("Not found")
      )
  )
  contextRouterRestored = ctx.router() == nil
)
let win = newWindow(WindowOptions(width: 320, height: 180,
  hidden: true, content: routerContent))
let native = fake.windows[^1].fakeSurface()

doAssert native.frame()
doAssert router.location() == "/settings/general"
doAssert shownPath == "/general" and sectionParam == "general"
doAssert contextRouterMatches
doAssert contextRouterRestored
doAssert router.title() == "General"
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
activate(native, accessNode(tree, platform.roleLink, "Fonts"))
doAssert router.location() == "/settings/fonts"
doAssert shownPath == "/fonts" and sectionParam == "fonts"
doAssert router.title() == "Fonts"

tree = native.accessibility()[0]
activate(native, accessNode(tree, platform.roleButton, "Back"))
doAssert router.location() == "/settings/general"
doAssert shownPath == "/general" and sectionParam == "general"

tree = native.accessibility()[0]
activate(native, accessNode(tree, platform.roleButton, "Forward"))
doAssert router.location() == "/settings/fonts"
doAssert shownPath == "/fonts" and sectionParam == "fonts"

when defined(macosx):
  tree = native.accessibility()[0]
  let generalLink = accessNode(tree, platform.roleLink, "General")
  doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
    id: generalLink.id, action: platform.accessFocus))
  doAssert native.frame()
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keyBracketLeft, mods: platform.modSuper))
  doAssert native.frame()
  doAssert router.location() == "/settings/general"
  discard native.send(platform.SurfaceEvent(kind: platform.keyReleased,
    key: platform.keyBracketLeft, mods: platform.modSuper))
  discard native.frame()

win.destroy()
loop.shutdown()
