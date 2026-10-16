## Package surface connects the content of a window that MyNim draws
## itself (package ui) to the window (package mynim), without either
## importing the other's internals.

import platform
import ../transfer
import ../i18n

export i18n.Region

type Region* = i18n.Region
  ## The user's regional formats; defined by package i18n.

type
  Conn* = ref object
    ## A window's side of the connection. Package mynim fills it before
    ## calling Content.attachContent; the content sets the hooks it
    ## handles. Everything runs on the main thread, except invalidate
    ## and post.
    surface*: platform.Surface
    ## window is the mynim.Window.
    window*: RootRef
    ## clipboard is the system clipboard.
    clipboard*: platform.Clipboard
    ## startDrag moves the window with the pointer, for drag regions;
    ## titleBarDoubleClicked does what a double click on a title bar
    ## does.
    startDrag*, titleBarDoubleClicked*: proc() {.closure.}
    ## escape is called with an Escape that no element or shortcut of
    ## the content handled, which closes a flyout.
    escape*: proc() {.closure.}
    ## startDataDrag connects a UI source to the core's process-local
    ## registry. local never leaves the process.
    startDataDrag*: proc(data: Data, local: RootRef, opts: DragOptions,
                         x, y: float64): ref CatchableError {.closure.}
    cancelDataDrag*: proc() {.closure.}
    ## isDark reports the system's dark appearance, and preferences the
    ## settings of the desktop that controls follow, which themeChanged
    ## tells changes of as well.
    isDark*: proc(): bool {.closure.}
    preferences*: proc(): platform.Preferences {.closure.}
    ## vibrancy reports whether the window currently shows its material.
    vibrancy*: proc(): bool {.closure.}
    ## locale returns the language the app shows (app.locale), and
    ## region the user's regional formats, which localeChanged tells
    ## changes of. They cost nothing: the content may read them every
    ## frame.
    locale*: proc(): string {.closure.}
    region*: proc(): Region {.closure.}
    ## rightToLeft reports whether the content is laid out right to
    ## left, as the app's language reads (i18n.direction of
    ## app.locale), unless the window says otherwise; nil is left to
    ## right. The content reads it as it builds each frame: call
    ## changed after it changes.
    rightToLeft*: proc(): bool {.closure.}
    ## uiFont returns the family of the desktop's interface font where
    ## the system's text stack does not know it (Linux), else "".
    uiFont*: proc(): string {.closure.}
    ## fontRendering returns how the desktop's settings say to
    ## rasterize text where the system's text stack does not know them
    ## (Linux).
    fontRendering*: proc(): platform.FontRendering {.closure.}
    ## titleBar returns the room the window controls take in a window
    ## with a hidden title bar, zero in other windows.
    titleBar*: proc(): platform.TitleBar {.closure.}
    ## openURL opens a link in the default browser, and gives done,
    ## unless nil, what came of it on the main thread.
    openURL*: proc(url: string, done: proc(err: ref CatchableError)) {.closure.}
    ## devTools tells that the window's developer tools are on
    ## (PageOptions.devTools): the content then opens its inspector.
    devTools*: bool
    ## invalidate asks for a frame; it is safe from any thread.
    invalidate*: proc() {.closure.}
    ## changed asks for a frame built anew after the app changed the
    ## state the content shows (Window.update, Window.invalidate); the
    ## content sets it, else the window asks the surface for a frame.
    changed*: proc() {.closure.}
    ## post runs fn on the main thread soon, unless the window has
    ## closed; it is safe from any thread.
    post*: proc(fn: proc() {.closure.}) {.closure.}
    ## ready tells that the content presented its first frame: the
    ## window is ready to show (Window.onReadyToShow).
    ready*: proc() {.closure.}
    ## popupMenu shows m as a context menu at (x, y) in the surface, in
    ## DIPs, once the event being handled returns. chosen receives the
    ## ID of the item chosen, if one is.
    popupMenu*: proc(m: platform.Menu, x, y: float64,
                     chosen: proc(id: int)) {.closure.}
    ## placeWebViews shows the window's web views where the content's
    ## last frame shows them (Surface.placeWebViews).
    placeWebViews*: proc(views: seq[platform.WebViewPlacement]) {.closure.}

    ## event receives the surface's events, and focus and blur of the
    ## window. It reports whether the content takes dragged files, as
    ## WindowHandler.surfaceEvent does.
    event*: proc(ev: platform.SurfaceEvent): bool {.closure.}
    ## themeChanged is called when the system appearance changes, and
    ## titleBarChanged when titleBar does.
    themeChanged*, titleBarChanged*: proc() {.closure.}
    ## localeChanged is called when locale or region changed, for the
    ## content to build its frame anew.
    localeChanged*: proc() {.closure.}
    ## capture renders the content as it is now into premultiplied RGBA.
    capture*: proc(): tuple[width, height: int, rgba: seq[byte]] {.closure.}
    ## toggleDevTools opens or closes the content's inspector, for the
    ## Toggle Developer Tools menu item, when devTools is set.
    toggleDevTools*: proc() {.closure.}
    ## detach is called once the window is closed.
    detach*: proc() {.closure.}

  Content* = ref object of RootObj
    ## Implemented by package ui.

  SurfaceWebView* = ref object of RootObj
    ## A web view a window made for its content to show (mynim.WebView,
    ## of Window.newWebView), which package ui places.

method attachContent*(c: Content; conn: Conn) {.base.} =
  raiseAssert("ui content must implement attachContent")

## surfaceWebView returns the web view's native side when it is of the
## window of conn and not destroyed, else nil. Main thread only.
method surfaceWebView*(v: SurfaceWebView; conn: Conn): platform.WebView {.base.} =
  nil
