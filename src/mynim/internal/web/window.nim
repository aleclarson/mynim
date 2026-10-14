## window.nim: a window of the page — an element filling the page's
## element with the ID "mygo", or else the page, holding the canvas its
## surface draws on. The page's title is the title of the window opened
## last.

## css is the style sheet of windows, added to the page once.
const webWindowCSS = """
.mygo-window{position:absolute;inset:0;overflow:hidden;contain:strict}
body>.mygo-window{position:fixed}
.mygo-window>canvas{display:block;width:100%;height:100%;touch-action:none;outline:none;user-select:none;-webkit-user-select:none}
.mygo-window>textarea{position:absolute;left:0;top:0;width:1px;height:1em;padding:0;margin:0;border:0;outline:none;resize:none;overflow:hidden;opacity:0;color:transparent;background:transparent;caret-color:transparent;white-space:pre;font-size:16px;z-index:-1}
"""

var styled: bool

proc newWebWindow*(b: webBackend, opts: WindowOptions,
                   h: WindowHandler): webWindow =
  let doc = jsGet(jsGlobal(), "document")
  if not styled:
    styled = true
    let style = jsCall(doc, "createElement", [jsValueOf("style")])
    jsSet(style, "textContent", jsValueOf(webWindowCSS))
    discard jsCall(jsGet(doc, "head"), "appendChild", [style])
  var parent = jsCall(doc, "getElementById", [jsValueOf("mygo")])
  if jsIsNull(parent):
    parent = jsGet(doc, "body")
  elif jsString(jsGet(jsCall(jsGlobal(), "getComputedStyle", [parent]),
                      "position")) == "static":
    jsSet(jsGet(parent, "style"), "position", jsValueOf("relative"))
  result = webWindow(b: b, h: h, opts: opts, title: opts.title,
                     full: opts.fullScreen)
  result.el = jsCall(doc, "createElement", [jsValueOf("div")])
  jsSet(result.el, "className", jsValueOf("mygo-window"))
  jsSet(jsGet(result.el, "style"), "display", jsValueOf("none"))
  if not opts.backgroundColor.isNil:
    result.setBackgroundColor(opts.backgroundColor[])
  discard jsCall(parent, "appendChild", [result.el])
  result.s = newWebSurface(result)
  result.setTitle(opts.title)

method handle*(w: webWindow): uint = 0
method surface*(w: webWindow): Surface = w.s

method setTitle*(w: webWindow, t: string) =
  w.title = t
  if t != "":
    jsSet(jsGet(jsGlobal(), "document"), "title", jsValueOf(t))

method title*(w: webWindow): string = w.title

method setRepresentedFile*(w: webWindow, path: string) = discard
method setDocumentEdited*(w: webWindow, edited: bool) = discard

## bounds returns the window's element's rectangle in the page.
proc boundsRect(w: webWindow): Rect =
  let r = jsCall(w.el, "getBoundingClientRect", [])
  Rect(x: jsInt(jsGet(r, "x")), y: jsInt(jsGet(r, "y")),
       width: jsInt(jsGet(r, "width")), height: jsInt(jsGet(r, "height")))

## The page sets where windows are and how large: the methods setting it
## do nothing.
method setBounds*(w: webWindow, r: Rect) = discard
method bounds*(w: webWindow): Rect = w.boundsRect()
method setContentBounds*(w: webWindow, r: Rect) = discard
method contentBounds*(w: webWindow): Rect = w.boundsRect()
method setMinimumSize*(w: webWindow, s: Size) = discard
method setMaximumSize*(w: webWindow, s: Size) = discard
method setResizable*(w: webWindow, v: bool) = discard
method isResizable*(w: webWindow): bool = false
method setMovable*(w: webWindow, v: bool) = discard
method isMovable*(w: webWindow): bool = false
method setMinimizable*(w: webWindow, v: bool) = discard
method isMinimizable*(w: webWindow): bool = false
method setMaximizable*(w: webWindow, v: bool) = discard
method isMaximizable*(w: webWindow): bool = false
method setClosable*(w: webWindow, v: bool) = discard
method isClosable*(w: webWindow): bool = w.opts.closable
method setAlwaysOnTop*(w: webWindow, v: bool) = discard
method isAlwaysOnTop*(w: webWindow): bool = false
method minimize*(w: webWindow) = discard
method isMinimized*(w: webWindow): bool = false
method maximize*(w: webWindow) = discard
method unmaximize*(w: webWindow) = discard
method isMaximized*(w: webWindow): bool = false
method restore*(w: webWindow) = discard
method center*(w: webWindow) = discard
method setOpacity*(w: webWindow, v: float64) = discard
method opacity*(w: webWindow): float64 = 1
method setHasShadow*(w: webWindow, v: bool) = discard
method hasShadow*(w: webWindow): bool = false
method setIgnoreMouseEvents*(w: webWindow, v: bool) = discard
method setContentProtection*(w: webWindow, v: bool) = discard
method setVibrancy*(w: webWindow, material: string) = discard
method setProgressBar*(w: webWindow, state: string, value: float64) = discard
method flashFrame*(w: webWindow, flash: bool) = discard
method setSkipTaskbar*(w: webWindow, v: bool) = discard
method setVisibleOnAllWorkspaces*(w: webWindow, v: bool) = discard
method setIcon*(w: webWindow, png: seq[byte]) = raise errWeb()
method setMenu*(w: webWindow, m: Menu) = discard
method setAutoHideMenu*(w: webWindow, v: bool) = discard
method titleBar*(w: webWindow): TitleBar = TitleBar()
method startDrag*(w: webWindow) = discard
method titleBarDoubleClicked*(w: webWindow) = discard
method placeFlyout*(w: webWindow, f: Flyout, size: Size) = discard

## show shows the window and gives it the keyboard, unless the app is in
## a frame of another page: that page keeps the keyboard until the window
## is clicked, as frames loading do not take it from the page scrolling
## them.
method show*(w: webWindow) =
  w.showInactive()
  if jsEqual(jsGet(jsGlobal(), "top"), jsGet(jsGlobal(), "self")):
    w.focus()

method showInactive*(w: webWindow) =
  if w.closed or w.visible:
    return
  w.visible = true
  jsSet(jsGet(w.el, "style"), "display", jsValueOf(""))
  discard w.s.measure()
  w.s.requestFrame()

method hide*(w: webWindow) =
  if not w.visible:
    return
  w.visible = false
  jsSet(jsGet(w.el, "style"), "display", jsValueOf("none"))

method isVisible*(w: webWindow): bool = w.visible
method focus*(w: webWindow) = w.s.focus()
method blur*(w: webWindow) = discard jsCall(w.s.input, "blur", [])
method isFocused*(w: webWindow): bool = w.focused

## setFullScreen asks the browser to show the window's element on the
## whole screen, which it allows while the user acts.
method setFullScreen*(w: webWindow, v: bool) =
  if v == w.full:
    return
  w.full = v
  let doc = jsGet(jsGlobal(), "document")
  if v:
    if jsType(jsGet(w.el, "requestFullscreen")) == jsFunction:
      discard jsCall(jsCall(w.el, "requestFullscreen", []), "catch",
        [jsNew(jsGet(jsGlobal(), "Function"), [jsValueOf("")])])
    w.h.enteredFullScreen()
  else:
    if not jsIsNull(jsGet(doc, "fullscreenElement")):
      discard jsCall(jsCall(doc, "exitFullscreen", []), "catch",
        [jsNew(jsGet(jsGlobal(), "Function"), [jsValueOf("")])])
    w.h.leftFullScreen()

method isFullScreen*(w: webWindow): bool = w.full

method setBackgroundColor*(w: webWindow, c: Color) =
  jsSet(jsGet(w.el, "style"), "background",
    jsValueOf("rgba(" & $int(c.r) & "," & $int(c.g) & "," & $int(c.b) &
              "," & $formatFloat(float64(c.a) / 255) & ")"))

method close*(w: webWindow) =
  if w.closed:
    return
  w.closed = true
  w.s.surfaceClosed()
  discard jsCall(w.el, "remove", [])
  w.b.removeWindow(w)
  w.h.closed()

## The page of a window is native UI's: none to load.
method loadURL*(w: webWindow, url: string) = discard
method loadHTML*(w: webWindow, html, baseURL: string) = discard
method loadFile*(w: webWindow, path, readAccessDir: string) = discard
method reload*(w: webWindow, ignoreCache: bool) = discard
method stopLoading*(w: webWindow) = discard
method goBack*(w: webWindow) = discard
method goForward*(w: webWindow) = discard
method canGoBack*(w: webWindow): bool = false
method canGoForward*(w: webWindow): bool = false
method url*(w: webWindow): string = ""
method isLoading*(w: webWindow): bool = false
method eval*(w: webWindow, js: string) = discard
method setUserScripts*(w: webWindow, scripts: seq[UserScript]) = discard
method setZoom*(w: webWindow, factor: float64) = discard
method zoom*(w: webWindow): float64 = 1
method setUserAgent*(w: webWindow, ua: string) = discard
method userAgent*(w: webWindow): string =
  jsString(jsGet(jsGet(jsGlobal(), "navigator"), "userAgent"))
method openDevTools*(w: webWindow) = discard
method closeDevTools*(w: webWindow) = discard
method isDevToolsOpened*(w: webWindow): bool = false
method droppedFiles*(w: webWindow): seq[string] = @[]
method print*(w: webWindow) = discard
method capturePage*(w: webWindow,
                    cb: proc(png: seq[byte], err: ref CatchableError)) =
  cb(@[], errWeb())
method printToPDF*(w: webWindow, opts: PDFOptions,
                   cb: proc(pdf: seq[byte], err: ref CatchableError)) =
  cb(@[], errWeb())
method callAsyncFunction*(w: webWindow, body: string,
                          cb: proc(res: string, err: ref CatchableError)) =
  cb("", errWeb())
