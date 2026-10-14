## surface.nim: the surface of a window that shows content mynim draws
## itself is a GtkGLArea in place of the web view: frames are drawn with
## OpenGL in its render signal, into the framebuffer of the context GTK
## makes current, and GTK shows them. Without OpenGL, frames drawn in
## memory are painted with cairo in the draw signal, as on a
## GtkDrawingArea, which the surface is with MYNIM_GPU=0 and where
## OpenGL would not draw on a GPU (gpuGL). GTK's frame clock paces
## both; keys go through a GtkIMContext while a text input has the
## focus.
##
## Frames drawn in memory are drawn in the frame clock's update phase,
## by a tick callback, before GTK paints: the area then asks GTK to
## repaint what they changed, which GTK paints from them, keeping the
## rest of its buffer and telling the compositor only that changed. A
## draw GTK asks for by itself, as when the window is resized or
## uncovered, draws a frame there.

var
  surfaceOnce: bool
  gtkWidgetSetCanFocus: proc(w: pointer, v: bool) {.cdecl.}
  gtkWidgetAddEvents: proc(w: pointer, mask: int32) {.cdecl.}
  gtkWidgetQueueDraw: proc(w: pointer) {.cdecl.}
  gtkWidgetQueueDrawArea: proc(w: pointer, x, y,
    width, height: int32) {.cdecl.}
  gtkWidgetGetHasWindow: proc(w: pointer): bool {.cdecl.}
  gtkWidgetAddTickCallback: proc(w, callback, data,
    notify: pointer): uint32 {.cdecl.}
  cairoClipExtents: proc(cr: pointer, x1, y1, x2,
    y2: ptr float64) {.cdecl.}
  gtkWidgetGetAllocatedWidth: proc(w: pointer): int32 {.cdecl.}
  gtkWidgetGetAllocatedHeight: proc(w: pointer): int32 {.cdecl.}
  gtkWidgetGetScaleFactor: proc(w: pointer): int32 {.cdecl.}
  gtkWidgetGetDisplay: proc(w: pointer): pointer {.cdecl.}
  gtkIMContextSetClientWindow: proc(im, win: pointer) {.cdecl.}
  gtkIMContextFilterKeypress: proc(im, event: pointer): bool {.cdecl.}
  gtkIMContextFocusIn: proc(im: pointer) {.cdecl.}
  gtkIMContextFocusOut: proc(im: pointer) {.cdecl.}
  gtkIMContextReset: proc(im: pointer) {.cdecl.}
  gtkIMContextSetCursorLoc: proc(im: pointer,
    r: ptr gdkRectangle) {.cdecl.}
  gtkIMContextGetPreedit: proc(im: pointer, str: ptr pointer,
    attrs: ptr pointer, cursor: ptr int32) {.cdecl.}
  gdkKeyvalToUnicode: proc(keyval: uint32): uint32 {.cdecl.}
  cairoImageSurfaceForData: proc(data: ptr byte, format, width,
    height, stride: int32): pointer {.cdecl.}
  cairoSurfaceSetDeviceScale: proc(s: pointer, x, y: float64) {.cdecl.}
  cairoSetSourceSurface: proc(cr, s: pointer, x, y: float64) {.cdecl.}
  cairoSetOperator: proc(cr: pointer, op: int32) {.cdecl.}
  cairoPaint: proc(cr: pointer) {.cdecl.}
  gtkGLAreaSetRequiredVersion: proc(a: pointer,
    major, minor: int32) {.cdecl.}
  gtkGLAreaGetError: proc(a: pointer): pointer {.cdecl.}
  gtkGLAreaSetError: proc(a, gerr: pointer) {.cdecl.}
  gdkWindowPeekChildren: proc(w: pointer): pointer {.cdecl.}
  gdkWindowGetUserData: proc(w: pointer,
    data: ptr pointer) {.cdecl.}

  cbSurfaceDraw, cbSurfaceSize, cbSurfaceRealize, cbSurfaceButton,
    cbSurfaceMotion, cbSurfaceLeave, cbSurfaceScroll, cbSurfaceKey,
    cbSurfaceFocusIn, cbSurfaceFocusOut, cbSurfaceScale, cbIMCommit,
    cbIMPreedit, cbIMPreeditEnd, cbSurfaceRender, cbAreaContext,
    cbSurfaceUnrealize, cbSurfaceTick: pointer
  surfaceCursors: Table[Cursor, pointer]

proc loadSurface*() =
  if surfaceOnce: return
  surfaceOnce = true
  let t = libGTK
  let d = libGDK
  let c = libCairo
  mustBind(t, cast[ptr pointer](addr gtkWidgetSetCanFocus),
    "gtk_widget_set_can_focus")
  mustBind(t, cast[ptr pointer](addr gtkWidgetAddEvents),
    "gtk_widget_add_events")
  mustBind(t, cast[ptr pointer](addr gtkWidgetQueueDraw),
    "gtk_widget_queue_draw")
  mustBind(t, cast[ptr pointer](addr gtkWidgetQueueDrawArea),
    "gtk_widget_queue_draw_area")
  mustBind(t, cast[ptr pointer](addr gtkWidgetGetHasWindow),
    "gtk_widget_get_has_window")
  mustBind(t, cast[ptr pointer](addr gtkWidgetAddTickCallback),
    "gtk_widget_add_tick_callback")
  mustBind(c, cast[ptr pointer](addr cairoClipExtents),
    "cairo_clip_extents")
  mustBind(t, cast[ptr pointer](addr gtkWidgetGetAllocatedWidth),
    "gtk_widget_get_allocated_width")
  mustBind(t, cast[ptr pointer](addr gtkWidgetGetAllocatedHeight),
    "gtk_widget_get_allocated_height")
  mustBind(t, cast[ptr pointer](addr gtkWidgetGetScaleFactor),
    "gtk_widget_get_scale_factor")
  mustBind(t, cast[ptr pointer](addr gtkWidgetGetDisplay),
    "gtk_widget_get_display")
  mustBind(t, cast[ptr pointer](addr gtkIMContextSetClientWindow),
    "gtk_im_context_set_client_window")
  mustBind(t, cast[ptr pointer](addr gtkIMContextFilterKeypress),
    "gtk_im_context_filter_keypress")
  mustBind(t, cast[ptr pointer](addr gtkIMContextFocusIn),
    "gtk_im_context_focus_in")
  mustBind(t, cast[ptr pointer](addr gtkIMContextFocusOut),
    "gtk_im_context_focus_out")
  mustBind(t, cast[ptr pointer](addr gtkIMContextReset),
    "gtk_im_context_reset")
  mustBind(t, cast[ptr pointer](addr gtkIMContextSetCursorLoc),
    "gtk_im_context_set_cursor_location")
  mustBind(t, cast[ptr pointer](addr gtkIMContextGetPreedit),
    "gtk_im_context_get_preedit_string")
  mustBind(d, cast[ptr pointer](addr gdkKeyvalToUnicode),
    "gdk_keyval_to_unicode")
  mustBind(c, cast[ptr pointer](addr cairoImageSurfaceForData),
    "cairo_image_surface_create_for_data")
  mustBind(c, cast[ptr pointer](addr cairoSurfaceSetDeviceScale),
    "cairo_surface_set_device_scale")
  mustBind(c, cast[ptr pointer](addr cairoSetSourceSurface),
    "cairo_set_source_surface")
  mustBind(c, cast[ptr pointer](addr cairoSetOperator),
    "cairo_set_operator")
  mustBind(c, cast[ptr pointer](addr cairoPaint), "cairo_paint")
  mustBind(d, cast[ptr pointer](addr gdkWindowPeekChildren),
    "gdk_window_peek_children")
  mustBind(d, cast[ptr pointer](addr gdkWindowGetUserData),
    "gdk_window_get_user_data")
  # GtkGLArea came in GTK 3.16: gtkGLAreaNew and
  # gtkGLAreaSetHasAlpha are bound with the rest (ffi.nim); the others
  # mark it usable.
  if not bindFunc(t,
      cast[ptr pointer](addr gtkGLAreaSetRequiredVersion),
      "gtk_gl_area_set_required_version") or
      not bindFunc(t, cast[ptr pointer](addr gtkGLAreaGetError),
        "gtk_gl_area_get_error") or
      not bindFunc(t, cast[ptr pointer](addr gtkGLAreaSetError),
        "gtk_gl_area_set_error"):
    gtkGLAreaNew = nil

# GDK event masks of the drawing area.
const surfaceEvents = 1'i32 shl 2 or 1'i32 shl 8 or 1'i32 shl 9 or
  1'i32 shl 10 or 1'i32 shl 11 or 1'i32 shl 12 or 1'i32 shl 13 or
  1'i32 shl 14 or 1'i32 shl 21 or 1'i32 shl 23

proc newSurfaceArea*(gl: bool): pointer ## surface_access.nim
proc newArea*(s: gtkSurface, gl: bool) ## below
proc connectSystem*(s: gtkSurface, data: pointer) ## surface_input.nim
proc cancelPendingDrop*(s: gtkSurface) ## surface_drop.nim
proc eventWindow*(s: gtkSurface): pointer ## below
method presentPixels*(s: gtkSurface, pix: openArray[byte],
  stride, width, height: int) ## below

proc createSurface*(w: gtkWindow) =
  loadSurface()
  let data = cast[pointer](w.id)
  let s = gtkSurface(w: w)
  s.im = gtkIMMulticontextNew()
  s.newArea(not gtkGLAreaNew.isNil and getEnv("MYNIM_GPU") != "0" and
    gpuGL())
  discard connect(s.im, "commit", cbIMCommit, data)
  discard connect(s.im, "preedit-changed", cbIMPreedit, data)
  discard connect(s.im, "preedit-end", cbIMPreeditEnd, data)
  s.connectSystem(data)
  w.surface = s

## newArea creates the surface's widget, a GtkGLArea or a
## GtkDrawingArea that assistive technology sees the content of, and
## connects its input.
proc newArea*(s: gtkSurface, gl: bool) =
  let data = cast[pointer](s.w.id)
  s.area = newSurfaceArea(gl)
  if gl:
    gtkGLAreaSetRequiredVersion(s.area, 3, 3)
    # Only transparent windows show what is behind them. With an alpha
    # channel GTK keeps the area in a texture it blends, rather than in
    # a renderbuffer it copies, which took a small window 50 MB more of
    # the GPU's memory, and an animation half as much CPU again.
    gtkGLAreaSetHasAlpha(s.area, s.w.opts.transparent)
    discard connect(s.area, "create-context", cbAreaContext, data)
    discard connect(s.area, "render", cbSurfaceRender, data)
  s.gl = gl
  gtkWidgetSetCanFocus(s.area, true)
  gtkWidgetAddEvents(s.area, surfaceEvents)
  # The edges of a frameless window resize it, as over a page.
  discard connect(s.area, "button-press-event", cbButtonPress, data)
  if s.w.undecorated():
    discard connect(s.area, "motion-notify-event", cbMotion, data)
  discard connect(s.area, "draw", cbSurfaceDraw, data)
  discard connect(s.area, "size-allocate", cbSurfaceSize, data)
  discard connect(s.area, "realize", cbSurfaceRealize, data)
  discard connect(s.area, "unrealize", cbSurfaceUnrealize, data)
  discard connect(s.area, "notify::scale-factor", cbSurfaceScale, data)
  discard connect(s.area, "button-press-event", cbSurfaceButton, data)
  discard connect(s.area, "button-release-event", cbSurfaceButton,
    data)
  discard connect(s.area, "motion-notify-event", cbSurfaceMotion, data)
  discard connect(s.area, "leave-notify-event", cbSurfaceLeave, data)
  discard connect(s.area, "scroll-event", cbSurfaceScroll, data)
  discard connect(s.area, "key-press-event", cbSurfaceKey, data)
  discard connect(s.area, "key-release-event", cbSurfaceKey, data)
  discard connect(s.area, "focus-in-event", cbSurfaceFocusIn, data)
  discard connect(s.area, "focus-out-event", cbSurfaceFocusOut, data)

## eventWindow returns the GdkWindow that receives the surface's input:
## the drawing area's own, or the input-only window a GtkGLArea, which
## draws in its parent's window, adds when realized.
proc eventWindow*(s: gtkSurface): pointer =
  let win = gtkWidgetGetWindow(s.area)
  if win.isNil or not s.gl:
    return win
  # GList: data 0, next 8.
  var l = gdkWindowPeekChildren(win)
  while not l.isNil:
    let child = field[pointer](l, 0)
    var owner: pointer
    gdkWindowGetUserData(child, addr owner)
    if owner == s.area:
      return child
    l = field[pointer](l, 8)
  win

proc destroy*(s: gtkSurface) =
  s.cancelPendingDrop()
  s.cancelDataDrag()
  if not s.lastPointer.isNil:
    gdkEventFree(s.lastPointer)
    s.lastPointer = nil
  gtkIMContextSetClientWindow(s.im, nil)
  gObjectUnref(s.im)
  s.im = nil
  if not s.lastKey.isNil:
    gdkEventFree(s.lastKey)
    s.lastKey = nil

method surface*(w: gtkWindow): Surface =
  ## the surface of a window created with WindowOptions.surface.
  if w.surface.isNil: nil else: Surface(w.surface)

method native*(s: gtkSurface): SurfaceNative =
  result = SurfaceNative(widget: cast[uint](s.area))
  if s.rendering:
    result.glArea = cast[uint](s.area)

method size*(s: gtkSurface): tuple[width, height, scale: float64] =
  (float64(gtkWidgetGetAllocatedWidth(s.area)),
   float64(gtkWidgetGetAllocatedHeight(s.area)),
   float64(max(gtkWidgetGetScaleFactor(s.area), 1)))

method requestFrame*(s: gtkSurface) =
  if s.w.closed: discard
  elif s.drawsGL(): gtkWidgetQueueDraw(s.area)
  else:
    s.again = true
    if s.tick == 0:
      s.tick = gtkWidgetAddTickCallback(s.area, cbSurfaceTick,
        cast[pointer](s.w.id), nil)

## drawsGL tells that the area draws its frames with OpenGL, in its
## render signal: a GtkGLArea with a context.
proc drawsGL*(s: gtkSurface): bool =
  s.gl and gtkGLAreaGetError(s.area).isNil

## presentDamage shows a frame drawn in memory that changed the last
## one only within damage. Drawn by the tick callback, it is painted
## where GTK repaints what changed; in the draw signal or the render
## signal, it is painted whole, and what it changed outside GTK's clip
## is repainted in the next frame.
method presentDamage*(s: gtkSurface, pix: openArray[byte],
    stride, width, height: int, damage: seq[platform.Rect]) =
  let scale = max(int(gtkWidgetGetScaleFactor(s.area)), 1)
  # GTK takes the area to repaint in the coordinates of the widget's
  # GdkWindow, whatever its documentation says: a GtkGLArea has none of
  # its own, and its parent's starts above and left of it, by the title
  # bar GTK draws, its shadow, or the menu bar.
  var at: gdkRectangle
  if not gtkWidgetGetHasWindow(s.area):
    gtkWidgetGetAllocation(s.area, addr at)
  proc queue(d: platform.Rect) =
    let x0 = d.x div scale
    let y0 = d.y div scale
    gtkWidgetQueueDrawArea(s.area, at.x + int32(x0), at.y + int32(y0),
      int32((d.x + d.width + scale - 1) div scale - x0),
      int32((d.y + d.height + scale - 1) div scale - y0))
  if not s.ticking:
    s.presentPixels(pix, stride, width, height)
    if not s.cr.isNil:
      var x0, y0, x1, y1: float64
      cairoClipExtents(s.cr, addr x0, addr y0, addr x1, addr y1)
      let clip = platform.Rect(
        x: int(floor(x0)) * scale, y: int(floor(y0)) * scale,
        width: int(ceil(x1)) * scale - int(floor(x0)) * scale,
        height: int(ceil(y1)) * scale - int(floor(y0)) * scale)
      for d in damage:
        if not d.`in`(clip):
          queue(d)
    return
  s.staged.pix = @pix
  s.staged.stride = stride
  s.staged.width = width
  s.staged.height = height
  for d in damage:
    queue(d)

## mallocTrim is glibc's malloc_trim, which other C libraries lack:
## dlsym on a nil handle is dlopen's RTLD_DEFAULT.
var mallocTrim = symAddr(LibHandle(nil), "malloc_trim")

## idle gives the system back the memory that C code freed while
## drawing frames, which glibc keeps for later: GTK paints a window it
## composites with OpenGL into an image as large as the window each
## frame, and glibc raises its threshold for giving large blocks back
## as they are freed.
method idle*(s: gtkSurface) =
  s.staged.pix = @[] # the host freed it
  if not mallocTrim.isNil:
    cast[proc(arg: cint) {.cdecl.}](mallocTrim)(0)

method refreshRate*(s: gtkSurface): float64 =
  let win = gtkWidgetGetWindow(s.area)
  if s.w.closed or win.isNil:
    return 0
  let m = gdkDisplayGetMonitorAtWin(gdkWindowGetDisplay(win), win)
  if m.isNil:
    return 0
  float64(gdkMonitorGetRefreshRate(m)) / 1000

method presentPixels*(s: gtkSurface, pix: openArray[byte],
    stride, width, height: int) =
  if s.cr.isNil:
    if s.rendering:
      # The content draws in memory after all, as when its GL renderer
      # fails: GTK shows only what OpenGL draws.
      s.inMemory = true
      let err = s.present.present(pix, stride, width, height)
      if not err.isNil and not s.presentFailed:
        s.presentFailed = true
        stderr.writeLine "mynim: native UI shows nothing: " & err.msg
      return
    # Frames are drawn in the draw signal; outside of it, ask for one.
    gtkWidgetQueueDraw(s.area)
    return
  if pix.len < stride * height or width == 0 or height == 0:
    return
  const formatARGB32 = 0'i32
  const operatorSource = 1'i32
  const operatorOver = 2'i32
  # premultiplied, native endian: BGRA
  let img = cairoImageSurfaceForData(addr pix[0], formatARGB32,
    int32(width), int32(height), int32(stride))
  let scale = float64(max(gtkWidgetGetScaleFactor(s.area), 1))
  cairoSurfaceSetDeviceScale(img, scale, scale)
  cairoSetSourceSurface(s.cr, img, 0, 0)
  var op = operatorSource
  if not s.layers.isNil:
    op = operatorOver # over the web views, which holes show
  cairoSetOperator(s.cr, op)
  cairoPaint(s.cr)
  cairoSurfaceDestroy(img)

var cursorNames* = {
  cursorDefault: "default", cursorPointer: "pointer",
  cursorText: "text",
  cursorMove: "move", cursorResizeEW: "ew-resize",
  cursorResizeNS: "ns-resize",
  cursorResizeNWSE: "nwse-resize", cursorResizeNESW: "nesw-resize",
  cursorNotAllowed: "not-allowed", cursorCrosshair: "crosshair",
  cursorGrab: "grab", cursorGrabbing: "grabbing",
  cursorResizeN: "n-resize", cursorResizeE: "e-resize",
  cursorResizeS: "s-resize",
  cursorResizeW: "w-resize", cursorResizeColumn: "col-resize",
  cursorResizeRow: "row-resize",
  cursorVerticalText: "vertical-text", cursorCopy: "copy",
  cursorAlias: "alias",
  cursorContextMenu: "context-menu", cursorNone: "none",
}.toTable

method setCursor*(s: gtkSurface, c: Cursor) =
  s.cursor = c
  let win = s.eventWindow()
  if win.isNil or s.w.cursor.on:
    return # a resize cursor of the edges shows
  var cur = surfaceCursors.getOrDefault(c)
  if cur.isNil and not surfaceCursors.hasKey(c):
    var name = cursorNames.getOrDefault(c)
    if name == "":
      name = "default"
    cur = gdkCursorNewFromName(gtkWidgetGetDisplay(s.area), cs(name))
    surfaceCursors[c] = cur
  gdkWindowSetCursor(win, cur)

method setTextInput*(s: gtkSurface, t: TextInputState) =
  let active = t.active
  let caret = t.caret
  if s.textInput and (not active or s.input.client != t.client):
    s.clientComposition.reset()
    gtkIMContextReset(s.im)
  s.input = t
  s.textInput = active
  s.caret = caret
  if active:
    var r = gdkRectangle(x: int32(caret.x), y: int32(caret.y),
      width: max(int32(caret.w), 1), height: int32(caret.h + 0.5))
    gtkIMContextSetCursorLoc(s.im, addr r)

proc send*(s: gtkSurface, ev: SurfaceEvent): bool =
  if ev.kind == platform.pointerDown or
      ev.kind == platform.surfaceBlur:
    s.clientComposition.reset()
  if s.w.closed:
    return false
  s.w.h.surfaceEvent(ev)

proc gdkMods*(state: uint32): platform.Modifiers =
  var m: platform.Modifiers
  if (state and 1) != 0:
    m = m or modShift
  if (state and (1 shl 2)) != 0:
    m = m or modCtrl
  if (state and (1 shl 3)) != 0:
    m = m or modAlt
  if (state and (1 shl 26 or 1 shl 28)) != 0:
    m = m or modSuper
  m

## modifierKeyval is the modifier a GDK keyval presses: Shift_L/R,
## Control_L/R, Alt_L/R and Meta_L/R, Super_L/R and Hyper_L/R; 0 for
## other keys.
proc modifierKeyval*(keyval: uint32): platform.Modifiers =
  case keyval
  of 0xffe1, 0xffe2: modShift
  of 0xffe3, 0xffe4: modCtrl
  of 0xffe9, 0xffea, 0xffe7, 0xffe8: modAlt
  of 0xffeb, 0xffec, 0xffed, 0xffee: modSuper
  else: 0

var gdkKeys* = {
  0xff0d'u32: keyEnter, 0xff8d'u32: keyEnter, 0xff1b'u32: keyEscape,
  0xff08'u32: keyBackspace,
  0xff09'u32: keyTab, 0xfe20'u32: keyTab, 0x20'u32: keySpace,
  0xffff'u32: keyDelete,
  0xff9f'u32: keyDelete, 0xff63'u32: keyInsert, 0xff50'u32: keyHome,
  0xff95'u32: keyHome,
  0xff57'u32: keyEnd, 0xff9c'u32: keyEnd, 0xff55'u32: keyPageUp,
  0xff9a'u32: keyPageUp,
  0xff56'u32: keyPageDown, 0xff9b'u32: keyPageDown,
  0xff51'u32: keyLeft, 0xff96'u32: keyLeft,
  0xff52'u32: keyUp, 0xff97'u32: keyUp, 0xff53'u32: keyRight,
  0xff98'u32: keyRight,
  0xff54'u32: keyDown, 0xff99'u32: keyDown,
  0xff67'u32: keyContextMenu,
  0x1008ff26'u32: keyBack, 0x1008ff27'u32: keyForward,
    # XF86Back, XF86Forward
}.toTable

proc keyvalKey*(keyval: uint32): platform.Key =
  if gdkKeys.hasKey(keyval):
    return gdkKeys[keyval]
  if keyval >= 0xffbe and keyval <= 0xffc9:
    return platform.Key(int(keyF1) + int(keyval - 0xffbe))
  let r = gdkKeyvalToUnicode(keyval)
  if r != 0:
    return keyForRune(int32(r))
  keyUnknown

## eventPhysicalKey reads GdkEventKey.hardware_keycode on the
## supported 64-bit GTK ABI. X11 and Wayland expose the evdev code
## plus 8 here.
proc eventPhysicalKey*(event: pointer): platform.Key =
  let code = field[uint16](event, 48)
  if code >= 8:
    return keyForScancode(code - 8)
  keyUnknown

proc initSurfaceCallbacks*() =
  cbSurfaceDraw = cast[pointer](
    proc(widget, cr, data: pointer): bool {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if s.isNil:
        return true
      # A GtkGLArea draws in its render signal, unless it has no
      # context: then, as a drawing area, in this one.
      if s.drawsGL():
        return false
      s.cr = cr
      # The frame the tick callback drew, unless GTK resized the area
      # since; else GTK asked for this draw by itself, and the content
      # draws a frame now.
      let (w, h, scale) = s.size()
      if s.staged.pix.len > 0 and
          s.staged.width == int(ceil(w * scale)) and
          s.staged.height == int(ceil(h * scale)):
        s.presentPixels(s.staged.pix, s.staged.stride, s.staged.width,
          s.staged.height)
      else:
        discard s.send(SurfaceEvent(kind: surfaceFrame))
      s.staged.pix = @[]
      s.cr = nil
      true)
  # The tick callback draws the frames asked for in memory, before GTK
  # paints, as long as they are asked for.
  cbSurfaceTick = cast[pointer](
    proc(widget, clock, data: pointer): bool {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if s.isNil:
        return false
      if s.drawsGL():
        # The area has its context now: frames come from its render
        # signal.
        s.tick = 0
        gtkWidgetQueueDraw(s.area)
        return false
      s.again = false
      s.ticking = true
      s.staged.pix = @[]
      discard s.send(SurfaceEvent(kind: surfaceFrame))
      s.ticking = false
      if not s.again:
        s.tick = 0
      s.again)
  # The GtkGLArea's context: OpenGL 3.3, else OpenGL ES 3.0. One GDK
  # cannot make leaves the area its error, so that it draws with cairo,
  # without the context GTK's own handler would make.
  cbAreaContext = cast[pointer](
    proc(area, data: pointer): pointer {.cdecl.} =
      let (ctx, gerr) = glContext(gtkWidgetGetWindow(area))
      if not gerr.isNil:
        gtkGLAreaSetError(area, gerr)
        gErrorFree(gerr)
      ctx)
  cbSurfaceRender = cast[pointer](
    proc(area, context, data: pointer): bool {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if s.isNil:
        return false
      s.rendering = true
      s.rendered = true
      s.inMemory = false
      discard s.send(SurfaceEvent(kind: surfaceFrame))
      s.rendering = false
      true)
  cbSurfaceSize = cast[pointer](
    proc(widget, allocation, data: pointer) {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if not s.isNil:
        discard s.send(SurfaceEvent(kind: surfaceResize)))
  cbSurfaceScale = cast[pointer](
    proc(widget, pspec, data: pointer) {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if not s.isNil:
        discard s.send(SurfaceEvent(kind: surfaceResize))
        gtkWidgetQueueDraw(s.area))
  # Input methods let go of the GdkWindow before it goes, as GtkEntry
  # has them: fcitx5's disconnects from it.
  cbSurfaceUnrealize = cast[pointer](
    proc(widget, data: pointer) {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if not s.isNil:
        gtkIMContextSetClientWindow(s.im, nil))
  cbSurfaceRealize = cast[pointer](
    proc(widget, data: pointer) {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if not s.isNil:
        gtkIMContextSetClientWindow(s.im, s.eventWindow())
        if s.cursor != cursorDefault:
          s.setCursor(s.cursor) # on the area that took another's place
      )
  # GdkEventButton: type 0, time 20, x 24, y 32, state 48, button 52.
  cbSurfaceButton = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if s.isNil:
        return false
      let typ = field[int32](event, 0)
      if typ != 4 and typ != 7:
        # GDK_BUTTON_PRESS, GDK_BUTTON_RELEASE: GTK's own double click
        # events add nothing.
        return true
      let n = field[uint32](event, 52)
      let mods = gdkMods(field[uint32](event, 48))
      if n == 8 or n == 9:
        # The side buttons go back and forward, as keys do.
        var kind = keyPressed
        var k = keyBack
        if typ == 7:
          kind = keyReleased
        if n == 9:
          k = keyForward
        discard s.send(SurfaceEvent(kind: kind, key: k, mods: mods))
        return true
      var button = -1
      case n
      of 1: button = 0
      of 2: button = 2
      of 3: button = 1
      else: return true
      var kind = pointerDown
      if typ == 7:
        kind = pointerUp
      elif not gtkWidgetHasFocus(s.area):
        gtkWidgetGrabFocus(s.area)
      if kind == pointerDown and button == 0:
        if not s.lastPointer.isNil:
          gdkEventFree(s.lastPointer)
        s.lastPointer = gdkEventCopy(event)
      discard s.send(SurfaceEvent(kind: kind,
        x: field[float64](event, 24), y: field[float64](event, 32),
        button: button, mods: mods))
      if kind == pointerUp and button == 0 and s.dragRequest.isNil and
          not s.lastPointer.isNil:
        gdkEventFree(s.lastPointer)
        s.lastPointer = nil
      true)
  # GdkEventMotion: x 24, y 32, state 48.
  cbSurfaceMotion = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if not s.isNil:
        if (field[uint32](event, 48) and (1'u32 shl 8)) != 0:
          if not s.lastPointer.isNil:
            gdkEventFree(s.lastPointer)
          s.lastPointer = gdkEventCopy(event)
        discard s.send(SurfaceEvent(kind: pointerMove,
          x: field[float64](event, 24), y: field[float64](event, 32),
          mods: gdkMods(field[uint32](event, 48))))
      false)
  # GdkEventCrossing: mode 72; only normal crossings leave.
  cbSurfaceLeave = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if not s.isNil and field[int32](event, 72) == 0:
        discard s.send(SurfaceEvent(kind: pointerLeave))
      false)
  # GdkEventScroll: x 24, y 32, state 40, direction 44, delta_x 72,
  # delta_y 80.
  cbSurfaceScroll = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if s.isNil:
        return false
      var ev = SurfaceEvent(kind: pointerScroll,
        x: field[float64](event, 24), y: field[float64](event, 32),
        mods: gdkMods(field[uint32](event, 40)))
      const step = 50
      case field[int32](event, 44)
      of 0: ev.dy = -step
      of 1: ev.dy = step
      of 2: ev.dx = -step
      of 3: ev.dx = step
      of 4: # smooth
        let dx = field[float64](event, 72)
        let dy = field[float64](event, 80)
        ev.dx = dx * step
        ev.dy = dy * step
        ev.precise = dx != float64(int64(dx)) or
          dy != float64(int64(dy))
      else: discard
      discard s.send(ev)
      true)
  # GdkEventKey: type 0, state 24, keyval 28, hardware_keycode 48.
  cbSurfaceKey = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if s.isNil:
        return false
      var kind = keyPressed
      if field[int32](event, 0) == 9: # GDK_KEY_RELEASE
        kind = keyReleased
      else:
        s.clientComposition.reset()
        if not s.lastKey.isNil:
          gdkEventFree(s.lastKey)
        s.lastKey = gdkEventCopy(event)
      if s.textInput and gtkIMContextFilterKeypress(s.im, event):
        return true
      # A modifier key on its own: the state is the one before the
      # event, so the key's own bit goes in or out.
      let bit = modifierKeyval(field[uint32](event, 28))
      if bit != 0:
        var state = gdkMods(field[uint32](event, 24))
        if kind == keyPressed:
          state = state or bit
        else:
          state = state and not bit
        discard s.send(SurfaceEvent(kind: modifiersChanged,
          mods: state))
        return false
      let k = keyvalKey(field[uint32](event, 28))
      let mods = gdkMods(field[uint32](event, 24))
      let physical = eventPhysicalKey(event)
      # A key the layout types no US key for, as S on a Cyrillic
      # layout, still reaches shortcuts by its position. A release is
      # sent whatever the modifiers held now, so that a press sent as
      # a chord is let go of even after Ctrl was.
      if k == keyUnknown:
        if kind == keyReleased and physical != keyUnknown:
          discard s.send(SurfaceEvent(kind: kind,
            physicalKey: physical, mods: mods))
          return false
        if not keyByPosition(k, physical, mods):
          return false
      if kind == keyPressed:
        s.pressing = event
      let took = s.send(SurfaceEvent(kind: kind, key: k,
        physicalKey: physical, mods: mods))
      s.pressing = nil
      took)
  cbSurfaceFocusIn = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if not s.isNil:
        gtkIMContextFocusIn(s.im)
        discard s.send(SurfaceEvent(kind: surfaceFocus))
      false)
  cbSurfaceFocusOut = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if not s.isNil:
        gtkIMContextFocusOut(s.im)
        discard s.send(SurfaceEvent(kind: surfaceBlur))
      false)
  cbIMCommit = cast[pointer](
    proc(im, str, data: pointer) {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if s.isNil:
        return
      if s.input.client != nil:
        s.clientComposition.replace(s.input.client, nil, goStr(str))
        return
      let text = goStr(str)
      if text != "":
        discard s.send(SurfaceEvent(kind: textInput, text: text)))
  cbIMPreedit = cast[pointer](
    proc(im, data: pointer) {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if s.isNil:
        return
      var str: pointer
      var cursor: int32
      gtkIMContextGetPreedit(s.im, addr str, nil, addr cursor)
      let text = takeStr(str)
      if s.input.client != nil:
        let c = s.input.client
        s.clientComposition.reset()
        # caret is the utf16 length of the first min(cursor, runes)
        # runes of the preedit.
        var i = 0
        var runeCount = 0
        let n = min(int(cursor), runeLen(text))
        while i < text.len and runeCount < n:
          i += text.runeLenAt(i)
          inc runeCount
        let caret = utf16Len(text[0 ..< i])
        c.setMarkedText(nil, text,
          TextRange(start: caret, `end`: caret))
        return
      discard s.send(SurfaceEvent(kind: textComposition, text: text,
        caret: min(int(cursor), runeLen(text)))))
  cbIMPreeditEnd = cast[pointer](
    proc(im, data: pointer) {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if s.isNil:
        return
      if s.input.client != nil:
        s.clientComposition.`end`(s.input.client)
        return
      discard s.send(SurfaceEvent(kind: textComposition)))
