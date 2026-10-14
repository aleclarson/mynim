## testhooks_gl.nim: hooks reporting how the surface of a window draws
## its native UI, with the framebuffer of a GtkGLArea when it has one.


## testSurfaceGL tells how the native UI of a window draws: "opengl"
## when its renderer draws in the GtkGLArea, "memory" when the GtkGLArea
## shows frames drawn on the CPU, "cairo" when a drawing area, or a
## GtkGLArea without a context, paints them with cairo, and "" before
## the first frame. For a GtkGLArea it returns its framebuffer's pixels
## too, premultiplied BGRA rows from the top, and their size.
proc testSurfaceGL*(handle: pointer): tuple[how: string,
    pix: seq[byte], width, height: int] =
  let s = surfaceByHandle(handle)
  if s.isNil:
    return ("", @[], 0, 0)
  if not s.gl or (not gtkGLAreaGetError.isNil and
      not gtkGLAreaGetError(s.area).isNil):
    return ("cairo", @[], 0, 0)
  if not s.rendered:
    return ("", @[], 0, 0)
  var how = "opengl"
  if s.inMemory:
    how = "memory"
  var makeCurrent, attachBuffers: proc(area: pointer) {.cdecl.}
  if not bindFunc(libGTK, cast[ptr pointer](addr makeCurrent),
      "gtk_gl_area_make_current") or
      not bindFunc(libGTK, cast[ptr pointer](addr attachBuffers),
        "gtk_gl_area_attach_buffers"):
    return (how, @[], 0, 0)
  # The area's framebuffer keeps the last frame it rendered.
  makeCurrent(s.area)
  attachBuffers(s.area)
  let scale = int(max(gtkWidgetGetScaleFactor(s.area), 1))
  let width = int(gtkWidgetGetAllocatedWidth(s.area)) * scale
  let height = int(gtkWidgetGetAllocatedHeight(s.area)) * scale
  let (pix, err) = gl.readFramebuffer(width, height)
  if not err.isNil:
    return (how, @[], 0, 0)
  (how, pix, width, height)

## testSurfaceOnScreen returns, as a PNG, what the display shows of the
## surface of a window: GTK repaints only what frames drawn in memory
## changed, and keeps the rest.
proc testSurfaceOnScreen*(handle: pointer): seq[byte] =
  let s = surfaceByHandle(handle)
  var getFromWindow: proc(win: pointer, x, y, width,
    height: int32): pointer {.cdecl.}
  if s.isNil or not bindFunc(libGDK,
      cast[ptr pointer](addr getFromWindow),
      "gdk_pixbuf_get_from_window"):
    return @[]
  # The area's GdkWindow is its parent's when it has none of its own.
  var at: gdkRectangle
  if not gtkWidgetGetHasWindow(s.area):
    gtkWidgetGetAllocation(s.area, addr at)
  let pix = getFromWindow(gtkWidgetGetWindow(s.area), at.x, at.y,
    gtkWidgetGetAllocatedWidth(s.area),
    gtkWidgetGetAllocatedHeight(s.area))
  if pix.isNil:
    return @[]
  defer: gObjectUnref(pix)
  pngFromPixbuf(pix)
