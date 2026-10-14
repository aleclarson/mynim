## layer.nim: gtk-layer-shell makes panels surfaces of the
## wlr-layer-shell protocol on Wayland compositors that speak it (Sway,
## Hyprland, KDE Plasma, COSMIC…), as launchers there do (Ulauncher,
## Walker, anyrun): above other windows, full-screen ones too, on the
## output where they are put, out of the taskbar. Wayland lets other
## windows do none of that. The library is optional: without it, or
## where the compositor does not speak the protocol (GNOME), a panel is
## a window as others.

var
  layerOnce, layerSupported*: bool
  gtkLayerIsSupported: proc(): bool {.cdecl.}
  gtkLayerInitForWindow: proc(w: pointer) {.cdecl.}
  gtkLayerSetNamespace: proc(w: pointer, ns: cstring) {.cdecl.}
  gtkLayerSetLayer: proc(w: pointer, layer: int32) {.cdecl.}
  gtkLayerSetAnchor: proc(w: pointer, edge: int32, anchor: bool) {.cdecl.}
  gtkLayerSetMargin: proc(w: pointer, edge, margin: int32) {.cdecl.}
  gtkLayerSetMonitor: proc(w, monitor: pointer) {.cdecl.}
  gtkLayerSetKeyboardMode: proc(w: pointer, mode: int32) {.cdecl.} # 0.6
  gtkLayerSetKeyboardInteractivity: proc(w: pointer, v: bool) {.cdecl.}
  gdkDisplayGetMonitorAtPoint: proc(d: pointer, x, y: int32): pointer {.cdecl.}

const
  layerOverlay = 3'i32 # GTK_LAYER_SHELL_LAYER_OVERLAY
  edgeLeft = 0'i32 # GtkLayerShellEdge
  edgeTop = 2'i32
  keyboardExclusive = 1'i32 # GtkLayerShellKeyboardMode
  keyboardOnDemand = 2'i32

## loadLayerShell loads gtk-layer-shell once, and reports whether panels
## can be layer surfaces.
proc loadLayerShell*(): bool =
  if not layerOnce:
    layerOnce = true
    let (lib, lerr) = openLib("libgtk-layer-shell.so.0")
    if not lerr.isNil:
      return false
    var ok =
      bindFunc(lib, cast[ptr pointer](addr gtkLayerIsSupported),
        "gtk_layer_is_supported") and
      bindFunc(lib, cast[ptr pointer](addr gtkLayerInitForWindow),
        "gtk_layer_init_for_window") and
      bindFunc(lib, cast[ptr pointer](addr gtkLayerSetNamespace),
        "gtk_layer_set_namespace") and
      bindFunc(lib, cast[ptr pointer](addr gtkLayerSetLayer),
        "gtk_layer_set_layer") and
      bindFunc(lib, cast[ptr pointer](addr gtkLayerSetAnchor),
        "gtk_layer_set_anchor") and
      bindFunc(lib, cast[ptr pointer](addr gtkLayerSetMargin),
        "gtk_layer_set_margin") and
      bindFunc(lib, cast[ptr pointer](addr gtkLayerSetMonitor),
        "gtk_layer_set_monitor") and
      bindFunc(libGDK, cast[ptr pointer](addr gdkDisplayGetMonitorAtPoint),
        "gdk_display_get_monitor_at_point")
    if not bindFunc(lib, cast[ptr pointer](addr gtkLayerSetKeyboardMode),
        "gtk_layer_set_keyboard_mode"):
      ok = ok and bindFunc(lib,
        cast[ptr pointer](addr gtkLayerSetKeyboardInteractivity),
        "gtk_layer_set_keyboard_interactivity")
    layerSupported = ok and gtkLayerIsSupported()
  layerSupported

proc constrain*(w: gtkWindow, width0, height0: int32):
    tuple[width, height: int32] ## window.nim
proc layerKeyboard*(w: gtkWindow, take: bool)
proc placeLayer*(w: gtkWindow, x, y: int)
proc sizeLayer*(w: gtkWindow, width, height: int32)

## initLayer makes a new panel a layer surface where it can be one,
## before GTK realizes it, and reports whether it did. Without a
## position, the compositor centers it on the output it chooses, the one
## the user is on.
proc initLayer*(w: gtkWindow): bool =
  if w.b.onX11 or not loadLayerShell():
    return false
  gtkLayerInitForWindow(w.win)
  # The namespace tells compositors' rules which surfaces are the
  # app's.
  var name = w.b.name
  if name == "":
    name = getAppFilename().lastPathPart
  gtkLayerSetNamespace(w.win, cs(name))
  gtkLayerSetLayer(w.win, layerOverlay)
  w.layer = true
  w.layerKeyboard(true)
  if not w.opts.center:
    w.placeLayer(w.opts.x, w.opts.y)
  true

## layerKeyboard asks for the keyboard of a layer surface as it shows,
## or not, as ShowInactive shows it. Compositors give the keyboard to a
## surface that asks for it alone (exclusive), not to one that would
## take it on demand, which only a click on it gets, and Sway takes it
## back from a surface that goes from one to the other: a panel keeps
## the keyboard while it shows, as launchers do, which blurs it only as
## it hides. Before gtk-layer-shell 0.6, a panel always asks for it.
proc layerKeyboard*(w: gtkWindow, take: bool) =
  if gtkLayerSetKeyboardMode.isNil:
    gtkLayerSetKeyboardInteractivity(w.win, true)
  elif take:
    gtkLayerSetKeyboardMode(w.win, keyboardExclusive)
  else:
    gtkLayerSetKeyboardMode(w.win, keyboardOnDemand)

## placeLayer puts a layer surface's top-left corner at x, y, on the
## output there, with margins from that output's top and left edges.
proc placeLayer*(w: gtkWindow, x, y: int) =
  let m = gdkDisplayGetMonitorAtPoint(gdkDisplayGetDefault(),
    int32(x), int32(y))
  var g: gdkRectangle
  gdkMonitorGetGeometry(m, addr g)
  gtkLayerSetMonitor(w.win, m)
  gtkLayerSetAnchor(w.win, edgeTop, true)
  gtkLayerSetAnchor(w.win, edgeLeft, true)
  gtkLayerSetMargin(w.win, edgeTop, int32(y) - g.y)
  gtkLayerSetMargin(w.win, edgeLeft, int32(x) - g.x)
  w.layerAt = (ref platform.Point)(x: x, y: y)

## centerLayer lets the compositor center a layer surface on its output.
proc centerLayer*(w: gtkWindow) =
  gtkLayerSetAnchor(w.win, edgeTop, false)
  gtkLayerSetAnchor(w.win, edgeLeft, false)
  w.layerAt = nil

## setLayerBounds places and sizes a layer surface.
proc setLayerBounds*(w: gtkWindow, r: platform.Rect) =
  let (width, height) = w.constrain(int32(r.width), int32(r.height))
  w.placeLayer(r.x, r.y)
  w.sizeLayer(width, height)

## sizeLayer sizes a layer surface, which gtk-layer-shell sizes as the
## window asks to be, not by its default size.
proc sizeLayer*(w: gtkWindow, width, height: int32) =
  gtkWidgetSetSizeRequest(w.win, width, height)
  gtkWindowResize(w.win, width, height)

## layerBounds returns where a layer surface is: where it was put, or
## the middle of its output, as the compositor centers it.
proc layerBounds*(w: gtkWindow): platform.Rect =
  var width, height: int32
  gtkWindowGetSize(w.win, addr width, addr height)
  var r = platform.Rect(width: int(width), height: int(height))
  if w.layerAt != nil:
    r.x = w.layerAt.x
    r.y = w.layerAt.y
    return r
  let d = gdkDisplayGetDefault()
  var m: pointer
  let gw = gtkWidgetGetWindow(w.win)
  if not gw.isNil and gtkWidgetGetMapped(w.win):
    m = gdkDisplayGetMonitorAtWin(d, gw)
  if m.isNil:
    m = gdkDisplayGetPrimaryMonitor(d)
  if m.isNil:
    return r
  var g: gdkRectangle
  gdkMonitorGetGeometry(m, addr g)
  r.x = int(g.x) + (int(g.width) - r.width) div 2
  r.y = int(g.y) + (int(g.height) - r.height) div 2
  r
