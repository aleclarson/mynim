## testhooks.nim: the functions in this file drive native UI the way a
## user would, for the GUI tests in internal/e2e. They must run on the
## main thread.

proc findMenuItem*(shell: pointer, label: string): pointer ## below
proc pressButton*(button: uint32, press: bool): bool ## below
proc clickSurface*(handle: pointer, x, y: float64, button: uint32): bool ## below

proc windowByHandle*(handle: pointer): gtkWindow =
  for w in theBackend.windows.values:
    if w.win == handle:
      return w
  nil

## testActivateMenuItem activates an item of a window's menu bar, found
## by the labels along its path.
proc testActivateMenuItem*(handle: pointer,
    path: varargs[string]): ref CatchableError =
  var w: gtkWindow = nil
  for x in theBackend.windows.values:
    if x.win == handle:
      w = x
  if w.isNil or w.menubar.isNil:
    return newException(CatchableError,
      "mynim: window has no menu bar")
  var shell = w.menubar
  for i, label in path:
    let item = findMenuItem(shell, label)
    if item.isNil:
      return newException(CatchableError,
        "mynim: no menu item " & $label)
    if i == path.len - 1:
      gtkMenuItemActivate(item)
      return nil
    shell = gtkMenuItemGetSubmenu(item)
    if shell.isNil:
      return newException(CatchableError,
        "mynim: menu " & $label & " has no submenu")
  nil

proc findMenuItem*(shell: pointer, label: string): pointer =
  let list = gtkContainerGetChildren(shell)
  defer: gListFree(list)
  var node = list
  while not node.isNil:
    let item = field[pointer](node, 0)
    if goStr(gtkMenuItemGetLabel(item)) == label:
      return item
    node = field[pointer](node, 8)
  nil

## testMenuBarState reports whether a window shows its menu bar, and
## whether the bar's first menu is open.
proc testMenuBarState*(handle: pointer): tuple[shown, open: bool] =
  let w = windowByHandle(handle)
  if w.isNil or w.menubar.isNil:
    return (false, false)
  var `open` = false
  let item = firstMenu(w.menubar)
  if not item.isNil:
    let sub = gtkMenuItemGetSubmenu(item)
    if not sub.isNil:
      `open` = gtkWidgetGetVisible(sub)
  (gtkWidgetGetVisible(w.menubar), `open`)

## testCloseMenuBar closes the menus of a window's menu bar, as Escape
## does.
proc testCloseMenuBar*(handle: pointer) =
  let w = windowByHandle(handle)
  if not w.isNil and not w.menubar.isNil:
    gtkMenuShellDeactivate(w.menubar)

## testActivateAccelerator presses a window's shortcut, as its keys do,
## and reports whether a menu item took it.
proc testActivateAccelerator*(handle: pointer, acc: string): bool =
  var activate: proc(obj: pointer, key, mods: uint32): bool {.cdecl.}
  let (key, mods, ok) = gtkAccelerator(acc)
  ok and
    bindFunc(libGTK, cast[ptr pointer](addr activate),
      "gtk_accel_groups_activate") and
    activate(handle, key, mods)

## testDismissPopups closes the context menus being shown, as if the
## user pressed Escape, and reports how many there were.
proc testDismissPopups*(): int =
  for m in theBackend.popups:
    gtkMenuShellDeactivate(m)
  theBackend.popups.len

## testSetDroppedFiles makes paths the files of the next drop on a
## window's page, as if they had been dragged there.
proc testSetDroppedFiles*(handle: pointer, paths: seq[string]) =
  for w in theBackend.windows.values:
    if w.win == handle:
      w.dropped = paths

## testDefaultURLHandler returns the id of the application GLib opens
## URLs of scheme with, as xdg-open and GTK apps do.
proc testDefaultURLHandler*(scheme: string): string =
  let info = gAppInfoGetDefaultForURIScheme(cs(scheme))
  if info.isNil:
    return ""
  defer: gObjectUnref(info)
  goStr(gAppInfoGetID(info))

## xtest holds the functions of the XTEST extension, which fake input
## like a keyboard or mouse would.
var xtest: tuple[
  key: proc(dpy: pointer, keycode: uint32, press: bool,
    delay: uint64): int32 {.cdecl.},
  button: proc(dpy: pointer, button: uint32, press: bool,
    delay: uint64): int32 {.cdecl.},
  motion: proc(dpy: pointer, screen: int32, x, y: int32,
    delay: uint64): int32 {.cdecl.}]

## loadXTest binds the XTEST extension and returns the X display, or nil
## without an X server.
proc loadXTest*(): pointer =
  if not loadX11():
    return nil
  if xtest.key.isNil:
    let (lib, err) = openLib("libXtst.so.6")
    if not err.isNil or
        not bindFunc(lib, cast[ptr pointer](addr xtest.button),
          "XTestFakeButtonEvent") or
        not bindFunc(lib, cast[ptr pointer](addr xtest.motion),
          "XTestFakeMotionEvent") or
        not bindFunc(lib, cast[ptr pointer](addr xtest.key),
          "XTestFakeKeyEvent"):
      return nil
  x11.xdisplay(gdkDisplayGetDefault())

## testPressKeys presses keys, X keysym names such as "Control_L",
## together and releases them, through the XTEST extension like a
## keyboard would. It reports false without an X server.
proc testPressKeys*(names: varargs[string]): bool =
  let dpy = loadXTest()
  if dpy.isNil:
    return false
  var codes: seq[uint32]
  for n in names:
    codes.add uint32(x11.keysymToKeycode(dpy, x11.stringToKeysym(cs(n))))
  for c in codes:
    discard xtest.key(dpy, c, true, 0)
  for i in countdown(codes.len - 1, 0):
    discard xtest.key(dpy, codes[i], false, 0)
  discard x11.flush(dpy)
  true

## testMovePointer moves the pointer to a point of the screen through
## the XTEST extension like a mouse would. It reports false without an
## X server.
proc testMovePointer*(x, y: int): bool =
  let dpy = loadXTest()
  if dpy.isNil:
    return false
  discard xtest.motion(dpy, -1, int32(x), int32(y), 0)
    # -1: the pointer's screen
  discard x11.flush(dpy)
  true

## testPressButton presses or releases the first mouse button the same
## way.
proc testPressButton*(press: bool): bool = pressButton(1, press)

## pressButton presses or releases a mouse button, 1 the primary, 3 the
## secondary.
proc pressButton*(button: uint32, press: bool): bool =
  let dpy = loadXTest()
  if dpy.isNil:
    return false
  discard xtest.button(dpy, button, press, 0)
  discard x11.flush(dpy)
  true

## testPopups returns the labels of the items of the context menus being
## shown, "-" for separators.
proc testPopups*(): seq[seq[string]] =
  for m in theBackend.popups:
    var labels: seq[string]
    let list = gtkContainerGetChildren(m)
    var node = list
    while not node.isNil:
      var label = goStr(gtkMenuItemGetLabel(field[pointer](node, 0)))
      if label == "":
        label = "-"
      labels.add label
      node = field[pointer](node, 8)
    gListFree(list)
    result.add labels

## testChoosePopupItem chooses the item labeled label of a context menu
## being shown, and closes the menu, and reports whether it has one.
proc testChoosePopupItem*(label: string): bool =
  for m in theBackend.popups:
    let item = findMenuItem(m, label)
    if not item.isNil:
      gtkMenuItemActivate(item)
      gtkMenuShellDeactivate(m)
      return true
  false

## testResizeCursor returns the name of the resize cursor a frameless
## window shows over an edge of its page, or "".
proc testResizeCursor*(handle: pointer): string =
  for w in theBackend.windows.values:
    if w.win == handle and w.cursor.on:
      return resizeEdges[w.cursor.edge].cursor
  ""

## testUsePortalShortcuts makes global shortcuts bind through the XDG
## desktop portal, as on Wayland, and reports whether the desktop offers
## it.
proc testUsePortalShortcuts*(on: bool): bool =
  portalShortcutsOnly = on
  not on or portalVersion(shortcutsPortal) != 0

# Walking a header bar's own children, its title buttons among them.
var
  walkDone: bool
  cbWalk: pointer
  walked: seq[pointer]
  gtkContainerForall: proc(c, cb, data: pointer) {.cdecl.}
  gtkContainerGetType: proc(): uint {.cdecl.}
  gtkStyleContextHasClass: proc(c: pointer, name: pointer):
    bool {.cdecl.}
  gtkButtonClicked: proc(b: pointer) {.cdecl.}

## titleButtons returns the title buttons shown over the page of a
## window with a hidden title bar, in order across its bars, with their
## names: "minimize", "maximize" or "close".
proc titleButtons*(w: gtkWindow): tuple[names: seq[string],
    buttons: seq[pointer]] =
  if not walkDone:
    walkDone = true
    mustBind(libGTK, cast[ptr pointer](addr gtkContainerForall),
      "gtk_container_forall")
    mustBind(libGTK, cast[ptr pointer](addr gtkContainerGetType),
      "gtk_container_get_type")
    mustBind(libGTK, cast[ptr pointer](addr gtkStyleContextHasClass),
      "gtk_style_context_has_class")
    mustBind(libGTK, cast[ptr pointer](addr gtkButtonClicked),
      "gtk_button_clicked")
    cbWalk = cast[pointer](
      proc(widget, data: pointer) {.cdecl.} =
        walked.add widget
        if gTypeCheckInstanceIsA(widget, gtkContainerGetType()):
          gtkContainerForall(widget, cbWalk, nil))
  var names: seq[string]
  var buttons: seq[pointer]
  if w.isNil or w.controls.isNil:
    return (names, buttons)
  for bar in w.controls.bars:
    if bar.isNil:
      continue
    walked = @[]
    gtkContainerForall(bar, cbWalk, nil)
    for widget in walked:
      let style = gtkWidgetGetStyleContext(widget)
      if not gtkWidgetGetVisible(widget) or
          not gtkStyleContextHasClass(style, cs("titlebutton")):
        continue
      for name in ["minimize", "maximize", "close"]:
        if gtkStyleContextHasClass(style, cs(name)):
          names.add name
          buttons.add widget
  (names, buttons)

## testTitleButtons returns the names of the title buttons over the page
## of a window with a hidden title bar.
proc testTitleButtons*(handle: pointer): seq[string] =
  let (names, _) = titleButtons(windowByHandle(handle))
  names

## testPressTitleButton clicks one of them.
proc testPressTitleButton*(handle: pointer, name: string): bool =
  let (names, buttons) = titleButtons(windowByHandle(handle))
  for i, n in names:
    if n == name:
      gtkButtonClicked(buttons[i])
      return true
  false

## testClickSurface clicks (x, y), in DIPs, in a window showing native
## UI, through the XTEST extension like a mouse would. It reports false
## for a window showing a web page, and without an X server.
proc testClickSurface*(handle: pointer, x, y: float64): bool =
  clickSurface(handle, x, y, 1)

proc clickSurface*(handle: pointer, x, y: float64, button: uint32):
    bool =
  let w = windowByHandle(handle)
  if w.isNil or w.surface.isNil:
    return false
  var origin: proc(win: pointer, x, y: ptr int32): int32 {.cdecl.}
  if not bindFunc(libGDK, cast[ptr pointer](addr origin),
      "gdk_window_get_origin"):
    return false
  var ox, oy: int32
  discard origin(w.surface.eventWindow(), addr ox, addr oy)
  let scale = float64(gtkWidgetGetScaleFactor(w.surface.area))
  if not testMovePointer(int((float64(ox) + x) * scale),
      int((float64(oy) + y) * scale)):
    return false
  pressButton(button, true) and pressButton(button, false)

## testSideButton clicks a mouse's back or forward button (buttons 8 and
## 9) in a window showing native UI, through XTEST.
proc testSideButton*(handle: pointer, back: bool): bool =
  var button = uint32(9)
  if back:
    button = 8
  clickSurface(handle, 20, 20, button)

## testDragSurface presses the primary button at the first of points, in
## DIPs, in a window showing native UI, moves the pointer through the
## others, and releases it at the last, through XTEST.
proc testDragSurface*(handle: pointer,
    points: seq[array[2, float64]]): bool =
  let w = windowByHandle(handle)
  if w.isNil or w.surface.isNil or points.len < 2:
    return false
  var origin: proc(win: pointer, x, y: ptr int32): int32 {.cdecl.}
  if not bindFunc(libGDK, cast[ptr pointer](addr origin),
      "gdk_window_get_origin"):
    return false
  var ox, oy: int32
  discard origin(w.surface.eventWindow(), addr ox, addr oy)
  let scale = float64(gtkWidgetGetScaleFactor(w.surface.area))
  proc move(p: array[2, float64]): bool =
    testMovePointer(int((float64(ox) + p[0]) * scale),
      int((float64(oy) + p[1]) * scale))
  if not move(points[0]) or not pressButton(1, true):
    return false
  for p in points[1 ..< points.len]:
    discard move(p)
  pressButton(1, false)

## testRightClickSurface clicks (x, y) with the secondary button, as
## testClickSurface does with the primary.
proc testRightClickSurface*(handle: pointer, x, y: float64): bool =
  clickSurface(handle, x, y, 3)

## testHasRecentItem reports whether the shared recent files list holds
## the file at path, as App.AddRecentDocument put it there.
proc testHasRecentItem*(path: string): bool =
  gtkRecentManagerHasItem(gtkRecentManagerGetDefault(),
    cs(fileURI(path)))

## testWindowTitle returns the title GTK gives a window.
proc testWindowTitle*(handle: pointer): string =
  goStr(gtkWindowGetTitle(handle))
