## flyout.nim: a flyout of a tray icon has no parent, which a popup
## needs on Wayland, and AppIndicator tells neither clicks nor where
## its icon is: it is an undecorated toplevel utility window over the
## others, in the middle of the primary display's work area where the
## platform lets apps place windows, which a focusable one closes as it
## loses the keyboard.
##
## A flyout (WindowOptions.Flyout) is a GTK_WINDOW_POPUP window, as
## GTK's menus and tooltips are: override-redirect on X11, where it
## goes exactly where Flyout.Place puts it in the work area of a
## monitor, and an xdg_popup of its parent on Wayland, which
## gdk_window_move_to_rect places with the compositor's positioner and
## which follows the parent by itself. Such a window gets the keyboard
## only through a grab: a focusable flyout grabs the seat
## (gdk_seat_grab), which Wayland turns into the popup's grab, and the
## application's input (gtk_grab_add), and closes as GtkMenu does, on a
## press outside it, when the grab breaks, or when the compositor
## dismisses the popup.

var
  flyoutOnce: bool
  gdkWindowSetTransientFor: proc(w, parent: pointer) {.cdecl.}
  gdkWindowMoveToRect: proc(w: pointer, r: ptr gdkRectangle, rectAnchor,
    windowAnchor, hints, dx, dy: int32) {.cdecl.}
  gdkSeatGrab: proc(seat, w: pointer, caps: int32, ownerEvents: bool,
    cursor, event, prepare, data: pointer): int32 {.cdecl.}
  gdkSeatUngrab: proc(seat: pointer) {.cdecl.}
  gtkGrabAdd, gtkGrabRemove: proc(w: pointer) {.cdecl.}
  gtkWidgetTranslateCoordinates: proc(src, dst: pointer, x, y: int32,
    dx, dy: ptr int32): bool {.cdecl.}
  gtkWindowSetAcceptFocus: proc(w: pointer, v: bool) {.cdecl.}
  cbFlyoutPress*, cbFlyoutGrabBroken*, cbFlyoutUnmap*,
    cbFlyoutPrepare*: pointer

const
  typeHintPopupMenu = 9'i32 # GDK_WINDOW_TYPE_HINT_POPUP_MENU
  anchorHintsAll = 63'i32 # GDK_ANCHOR_FLIP|SLIDE|RESIZE
  seatCapabilityAll = 15'i32 # GDK_SEAT_CAPABILITY_ALL

proc loadFlyouts*() =
  if flyoutOnce: return
  flyoutOnce = true
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetTypeHint),
    "gtk_window_set_type_hint")
  mustBind(libGDK, cast[ptr pointer](addr gdkWindowSetTransientFor),
    "gdk_window_set_transient_for")
  mustBind(libGDK, cast[ptr pointer](addr gdkWindowMoveToRect),
    "gdk_window_move_to_rect")
  mustBind(libGDK, cast[ptr pointer](addr gdkSeatGrab), "gdk_seat_grab")
  mustBind(libGDK, cast[ptr pointer](addr gdkSeatUngrab),
    "gdk_seat_ungrab")
  mustBind(libGTK, cast[ptr pointer](addr gtkGrabAdd), "gtk_grab_add")
  mustBind(libGTK, cast[ptr pointer](addr gtkGrabRemove),
    "gtk_grab_remove")
  mustBind(libGTK,
    cast[ptr pointer](addr gtkWidgetTranslateCoordinates),
    "gtk_widget_translate_coordinates")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetAcceptFocus),
    "gtk_window_set_accept_focus")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetSkipPagerHint),
    "gtk_window_set_skip_pager_hint")

## gravity returns the GdkGravity of a point of a rectangle.
proc gravity(g: platform.Gravity): int32 =
  int32((g.y + 1) * 3 + g.x + 1 + 1)

method setAlwaysOnTop*(w: gtkWindow, v: bool) ## window.nim
method setBounds*(w: gtkWindow, r: platform.Rect) ## window.nim
proc contentWidget*(w: gtkWindow): pointer ## window.nim
proc willShow*(w: gtkWindow) ## window.nim
proc dismissFlyout*(w: gtkWindow, lost: bool) ## below
proc ungrab*(w: gtkWindow) ## below
proc contentOrigin*(w: gtkWindow): tuple[x, y: int32] ## below
proc hideFlyout*(w: gtkWindow) ## below
proc showFlyout*(w: gtkWindow, grab: bool) ## below
proc trayFlyout*(w: gtkWindow): bool ## below
proc closePopupsAbove*(b: Backend, parent: gtkWindow) ## below

## initFlyout makes a new window a flyout, before it shows.
proc initFlyout*(w: gtkWindow) =
  loadFlyouts()
  let data = cast[pointer](w.id)
  if w.opts.flyout.tray != nil:
    gtkWindowSetTypeHint(w.win, typeHintUtility)
    gtkWindowSetSkipPagerHint(w.win, true)
    w.setAlwaysOnTop(true)
    gtkWindowSetAcceptFocus(w.win, w.opts.flyout.focusable)
    w.placeFlyout(w.opts.flyout,
      Size(width: w.opts.width, height: w.opts.height))
    return
  gtkWindowSetTypeHint(w.win, typeHintPopupMenu)
  # Its size is the one asked for, smaller than its content's natural
  # size too.
  gtkWindowSetResizable(w.win, true)
  discard connect(w.win, "button-press-event", cbFlyoutPress, data)
  discard connect(w.win, "grab-broken-event", cbFlyoutGrabBroken, data)
  discard connect(w.win, "unmap-event", cbFlyoutUnmap, data)
  w.placeFlyout(w.opts.flyout,
    Size(width: w.opts.width, height: w.opts.height))

## placeFlyout places a flyout next to its anchor: on X11 where
## Flyout.Place puts it, on Wayland with the compositor's positioner,
## which takes a popup's position as it maps: there a flyout that shows
## maps again, unless only its parent moved, which the popup follows.
method placeFlyout*(w: gtkWindow, f: Flyout, size: Size) =
  if w.opts.flyout != nil and f.tray != nil and not w.closed:
    w.flyout = f
    w.flyoutSize = size
    w.placed = true
    let r = platform.centered(size,
      platform.primaryWorkArea(screenImpl().displays()))
    w.setBounds(r) # Wayland compositors place it themselves
    return
  let p = gtkWindow(w.opts.parent)
  if w.opts.flyout.isNil or w.closed or p.isNil or p.closed:
    return
  let same = w.placed and f == w.flyout and size == w.flyoutSize
  w.flyout = f
  w.flyoutSize = size
  w.placed = true
  if w.b.onX11:
    let (ox, oy) = p.contentOrigin()
    var anchor = f.anchor
    anchor.x += int(ox)
    anchor.y += int(oy)
    let (r, _, _) = f.place(anchor, size,
      platform.workAreaFor(anchor, screenImpl().displays()))
    w.setBounds(r)
    return
  let visible = gtkWidgetGetVisible(w.win)
  if visible and same:
    return
  if visible:
    w.hideFlyout()
  gtkWindowResize(w.win, int32(size.width), int32(size.height))
  gtkWidgetRealize(w.win)
  let gdkWin = gtkWidgetGetWindow(w.win)
  gdkWindowSetTransientFor(gdkWin, gtkWidgetGetWindow(p.win))
  # Relative to the parent's GdkWindow, its shadows included.
  var x, y: int32
  discard gtkWidgetTranslateCoordinates(p.contentWidget(), p.win,
    int32(f.anchor.x), int32(f.anchor.y), addr x, addr y)
  var alloc: gdkRectangle
  gtkWidgetGetAllocation(p.win, addr alloc)
  var r = gdkRectangle(x: x + alloc.x, y: y + alloc.y,
    width: int32(max(f.anchor.width, 1)),
    height: int32(max(f.anchor.height, 1)))
  let (ra, wa, dx, dy) = f.gravities()
  gdkWindowMoveToRect(gdkWin, addr r, gravity(ra), gravity(wa),
    anchorHintsAll, int32(dx), int32(dy))
  if visible:
    w.showFlyout(f.focusable)

## contentOrigin returns where the window's content is on the screen.
proc contentOrigin*(w: gtkWindow): tuple[x, y: int32] =
  gtkWidgetRealize(w.win)
  var x, y: int32
  discard gdkWindowGetOrigin(gtkWidgetGetWindow(w.win), addr x, addr y)
  var dx, dy: int32
  discard gtkWidgetTranslateCoordinates(w.contentWidget(), w.win, 0, 0,
    addr dx, addr dy)
  (x + dx, y + dy)

## showFlyout shows a flyout, which takes the keyboard when grab is set.
proc showFlyout*(w: gtkWindow, grab: bool) =
  if w.trayFlyout():
    w.willShow()
    gtkWidgetShow(w.win)
    if grab:
      gtkWindowPresent(w.win)
    return
  if gtkWidgetGetVisible(w.win):
    return
  if not w.b.onX11:
    let p = gtkWindow(w.opts.parent)
    w.b.closePopupsAbove(p)
    w.b.flyouts.add w
  w.willShow()
  if not grab:
    gtkWidgetShow(w.win)
    return
  gtkWidgetRealize(w.win)
  let seat = gdkDisplayGetDefaultSeat(gdkDisplayGetDefault())
  # The prepare function shows the window: Wayland maps the popup with
  # the grab.
  if gdkSeatGrab(seat, gtkWidgetGetWindow(w.win), seatCapabilityAll,
      true, nil, nil, cbFlyoutPrepare, cast[pointer](w.id)) == 0:
    w.grabbed = true
    gtkGrabAdd(w.win)
  gtkWidgetShow(w.win) # unless the prepare function did

## hideFlyout hides a flyout, and lets the grab of a focusable one go.
proc hideFlyout*(w: gtkWindow) =
  w.ungrab()
  w.b.flyouts.keepItIf(it != w)
  if gtkWidgetGetMapped(w.win):
    inc w.unmaps # its unmap event comes later, maybe once it shows again
  gtkWidgetHide(w.win)

## closePopupsAbove closes the popups above parent, the topmost first,
## as the user dismissing them, or hides those that stay: Wayland maps
## a popup only over the topmost one, or a toplevel, which GDK makes
## its parent.
proc closePopupsAbove*(b: Backend, parent: gtkWindow) =
  while b.flyouts.len > 0:
    let top = b.flyouts[^1]
    if top == parent:
      return
    top.dismissFlyout(false)
    if not top.closed and gtkWidgetGetVisible(top.win):
      top.hideFlyout()
    b.flyouts.keepItIf(it != top)

## dismissFlyouts closes the focusable flyouts that grab the input as
## another window takes the keyboard, which their grab keeps from it.
proc dismissFlyouts*(b: Backend, focus: gtkWindow) =
  for w in b.windows.values:
    if w.grabbed and w != focus:
      w.dismissFlyout(false)

proc ungrab*(w: gtkWindow) =
  if not w.grabbed: return
  w.grabbed = false
  gtkGrabRemove(w.win)
  gdkSeatUngrab(gdkDisplayGetDefaultSeat(gdkDisplayGetDefault()))

## dismissFlyout closes a flyout the user dismissed, as the user
## closing it. One that stays, but lost its popup (the compositor hid
## it, or its grab broke), hides.
proc dismissFlyout*(w: gtkWindow, lost: bool) =
  if w.closed or w.dismissing: return
  w.dismissing = true
  defer: w.dismissing = false
  if w.h.shouldClose():
    w.close()
  elif lost:
    w.hideFlyout()

proc initFlyoutCallbacks*() =
  cbFlyoutPrepare = cast[pointer](
    proc(seat, gdkWin, data: pointer) {.cdecl.} =
      let w = theBackend.window(data)
      if not w.isNil:
        gtkWidgetShow(w.win))
  # The application's input goes to a focusable flyout while it grabs
  # it: a press elsewhere, in another window or, on X11, another app,
  # closes it.
  cbFlyoutPress = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      if w.isNil or not w.grabbed:
        return false
      # Where the press is on the screen, as GtkMenu looks: the
      # event's window and coordinates may be the grab's or the
      # window's under the pointer. GdkEventButton: x_root 64,
      # y_root 72.
      var ox, oy: int32
      discard gdkWindowGetOrigin(gtkWidgetGetWindow(w.win), addr ox, addr oy)
      var a: gdkRectangle
      gtkWidgetGetAllocation(w.win, addr a)
      let x = field[float64](event, 64) - float64(ox)
      let y = field[float64](event, 72) - float64(oy)
      if x >= 0 and y >= 0 and x < float64(a.width) and
          y < float64(a.height):
        return false
      w.dismissFlyout(false)
      true)
  cbFlyoutGrabBroken = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      if not w.isNil and w.grabbed:
        w.grabbed = false
        gtkGrabRemove(w.win)
        w.dismissFlyout(true)
      false)
  # A Wayland compositor dismissed the popup, and GDK hid its window:
  # an unmap the backend's own hiding (unmaps) does not account for.
  # X11 servers do not dismiss popups.
  cbFlyoutUnmap = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      if w.isNil or w.b.onX11:
        return false
      if w.unmaps > 0:
        dec w.unmaps
        return false
      if gtkWidgetGetVisible(w.win):
        w.ungrab()
        w.dismissFlyout(true)
      false)

## trayFlyout reports a flyout of a tray icon.
proc trayFlyout*(w: gtkWindow): bool =
  w.opts.flyout != nil and w.opts.flyout.tray != nil

## grabbingChild reports whether a flyout of w's grabs the input, and so
## has the keyboard w lost to it.
proc grabbingChild*(w: gtkWindow): bool =
  for x in w.b.windows.values:
    if not x.grabbed: continue
    var p = gtkWindow(x.opts.parent)
    while p != nil:
      if p == w: return true
      p = gtkWindow(p.opts.parent)
  false
