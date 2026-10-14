## base.nim: the backend helpers every part may call, whichever order
## the parts come in.

## themeAttr is the attribute of the page's root element that chooses the
## appearance, "dark" or "light", over the browser's: a page framing the
## app sets it to its own, which the frame's prefers-color-scheme does not
## follow in Chrome.
const themeAttr* = "data-mygo-theme"

proc webUnsupported*(): ref PlatformError =
  newException(PlatformError, "mynim: browsers do not support this")

proc errWeb(): ref CatchableError = webUnsupported()

proc newWebBackend*(): webBackend =
  ## The browser backend.
  webBackend()

## sync runs fn on the main thread, which is this thread: JavaScript's
## callbacks run on it too.
proc sync*(b: webBackend, fn: proc()) =
  fn()

## funcOf wraps fn for JavaScript, for the life of the app.
proc funcOf*(b: webBackend,
             fn: proc(this: JsValue, args: seq[JsValue]): JsValue): JsValue =
  let f = jsFuncOf(fn)
  b.funcs.add f
  f

proc newWebWindow*(b: webBackend, opts: WindowOptions,
                   h: WindowHandler): webWindow
proc installFiles*()
proc removeWindow*(b: webBackend, w: webWindow)
