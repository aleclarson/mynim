## A window runtime that builds a frame and submits its scene to the
## platform GPU renderer, with the CPU rasterizer as fallback.

type
  View* = proc(c: Context) {.closure.}

  Content* = ref object of surface.Content
    view: View

  Runtime = ref object
    conn: surface.Conn
    view: View
    context: Context
    frameLayout: LayoutResult
    pressTarget: Element
    frameScene: scene.Scene
    hasScene: bool
    inFrame, closed, ready, gpuTried: bool
    gpuError: string
    software: raster.Renderer
    when defined(macosx):
      metalRenderer: metalGpu.Renderer
    elif (defined(linux) and (defined(amd64) or defined(arm64))) or
        defined(emscripten):
      glRenderer: glGpu.Renderer

proc newContent*(view: View): Content =
  ## Creates native UI content for WindowOptions.content.
  Content(view: view)

proc frameDimension(value: float64; name: string): float32 =
  if classify(value) in {fcNan, fcInf, fcNegInf} or
      abs(value) > float64(high(float32)):
    raise newException(ValueError, "ui: surface " & name & " is out of range")
  float32(max(value, 0))

proc releaseGpu(rt: Runtime) =
  when defined(macosx):
    if rt.metalRenderer != nil:
      rt.metalRenderer.release()
      rt.metalRenderer = nil
  elif (defined(linux) and (defined(amd64) or defined(arm64))) or
      defined(emscripten):
    if rt.glRenderer != nil:
      rt.glRenderer.release()
      rt.glRenderer = nil

proc tryGpu(rt: Runtime; frame: scene.Scene): bool =
  when defined(macosx):
    let native = rt.conn.surface.native()
    if native.layer == 0:
      return false
    if not rt.gpuTried:
      rt.gpuTried = true
      try:
        rt.metalRenderer = metalGpu.new(native.layer)
      except CatchableError as error:
        rt.gpuError = error.msg
    if rt.metalRenderer == nil:
      return false
    try:
      rt.metalRenderer.render(frame)
      return true
    except CatchableError as error:
      rt.gpuError = error.msg
      rt.releaseGpu()
      false
  elif defined(linux) and (defined(amd64) or defined(arm64)):
    let native = rt.conn.surface.native()
    if native.glArea == 0:
      return false
    if not rt.gpuTried:
      rt.gpuTried = true
      let (renderer, error) = glGpu.newRenderer()
      if error == nil:
        rt.glRenderer = renderer
      else:
        rt.gpuError = error.msg
    if rt.glRenderer == nil:
      return false
    let error = rt.glRenderer.render(frame)
    if error == nil:
      return true
    rt.gpuError = error.msg
    rt.releaseGpu()
    false
  elif defined(emscripten):
    let native = rt.conn.surface.native()
    if native.canvas == 0:
      return false
    if not rt.gpuTried:
      rt.gpuTried = true
      let (renderer, error) = glGpu.newRenderer()
      if error == nil:
        rt.glRenderer = renderer
      else:
        rt.gpuError = error.msg
    if rt.glRenderer == nil:
      return false
    let error = rt.glRenderer.render(frame)
    if error == nil:
      return true
    rt.gpuError = error.msg
    rt.releaseGpu()
    false
  else:
    false

proc present(rt: Runtime; frame: scene.Scene) =
  if frame.width <= 0 or frame.height <= 0:
    return
  if rt.tryGpu(frame):
    return
  if rt.gpuError.len > 0:
    stderr.writeLine("mynim: drawing without the GPU: " & rt.gpuError)
    rt.gpuError.setLen(0)
  discard rt.software.render(frame)
  let image = rt.software.image
  rt.conn.surface.presentPixels(image.pix, image.stride, image.w, image.h)

proc renderFrame(rt: Runtime; presentFrame = true) =
  if rt.closed or rt.inFrame:
    return
  rt.inFrame = true
  defer: rt.inFrame = false

  let size = rt.conn.surface.size()
  let width = frameDimension(size.width, "width")
  let height = frameDimension(size.height, "height")
  let scale = if classify(size.scale) in {fcNan, fcInf, fcNegInf} or
      size.scale <= 0 or size.scale > float64(high(float32)):
    1'f32
  else:
    float32(size.scale)

  rt.context.build(rt.view)
  let layout = rt.context.layout(width, height)
  rt.frameLayout = layout
  rt.frameScene = layout.paintScene(scale)
  rt.hasScene = true
  if presentFrame:
    rt.present(rt.frameScene)

  if presentFrame and not rt.ready and rt.conn.ready != nil and
      rt.conn.post != nil:
    rt.ready = true
    rt.conn.post(rt.conn.ready)

proc requestFrame(rt: Runtime) =
  if not rt.closed and rt.conn.surface != nil:
    rt.conn.surface.requestFrame()

proc event(rt: Runtime; ev: platform.SurfaceEvent): bool =
  if rt.closed:
    return false
  case ev.kind
  of platform.surfaceFrame:
    rt.renderFrame()
    true
  of platform.surfaceResize:
    rt.requestFrame()
    false
  of platform.surfaceRenew:
    rt.releaseGpu()
    rt.gpuTried = false
    rt.requestFrame()
    false
  of platform.pointerDown:
    rt.pressTarget = Element()
    if ev.button == 0:
      rt.pressTarget = rt.frameLayout.targetAt(float32(ev.x), float32(ev.y))
    return rt.pressTarget.owner != nil
  of platform.pointerUp:
    if ev.button == 0:
      result = rt.frameLayout.dispatchClick(rt.pressTarget,
        float32(ev.x), float32(ev.y))
    rt.pressTarget = Element()
    if result:
      rt.requestFrame()
    return result
  of platform.surfaceBlur:
    rt.pressTarget = Element()
    false
  else:
    false

proc capture(rt: Runtime): tuple[width, height: int, rgba: seq[byte]] =
  if rt.closed:
    return
  if not rt.hasScene:
    rt.renderFrame(false)
    rt.requestFrame()
  if not rt.hasScene:
    return

  var software: raster.Renderer
  discard software.render(rt.frameScene)
  let image = software.image
  result.width = image.w
  result.height = image.h
  result.rgba = image.pix
  for offset in countup(0, result.rgba.high - 3, 4):
    swap(result.rgba[offset], result.rgba[offset + 2])

proc close(rt: Runtime) =
  if rt.closed:
    return
  rt.closed = true
  rt.context.close()
  rt.releaseGpu()
  rt.frameLayout = LayoutResult()
  rt.pressTarget = Element()
  rt.gpuError.setLen(0)
  rt.software.release()
  rt.frameScene = scene.Scene()
  rt.hasScene = false

method attachContent*(content: Content; conn: surface.Conn) =
  let rt = Runtime(conn: conn, view: content.view, context: newContext())
  conn.event = proc(ev: platform.SurfaceEvent): bool = rt.event(ev)
  conn.changed = proc() = rt.requestFrame()
  conn.themeChanged = proc() = rt.requestFrame()
  conn.titleBarChanged = proc() = rt.requestFrame()
  conn.localeChanged = proc() = rt.requestFrame()
  conn.capture = proc(): tuple[width, height: int, rgba: seq[byte]] =
    rt.capture()
  conn.detach = proc() = rt.close()
  rt.requestFrame()
