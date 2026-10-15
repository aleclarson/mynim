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
    focusSlot, keyPressSlot: int
    keyPressKey: platform.Key
    pointerX, pointerY: float32
    hasPointer: bool
    hoverSlots, pressHoverSlots, pressedSlots, clickedSlots: seq[int]
    frameScene: scene.Scene
    hasScene: bool
    accessibilityOn: bool
    keyboardFocusVisible, inFrame, closed, ready, gpuTried: bool
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

proc focusableSlot(layout: LayoutResult; slot: int): bool =
  let owner = layout.owner
  if owner == nil or owner.closed or owner.inBuild or not owner.hasFrame or
      layout.generation != owner.generation or slot <= 0 or
      slot >= owner.nodes.len:
    return false
  let node = owner.nodes[slot]
  node.focusable or node.clickHandler != nil

proc clickableSlot(layout: LayoutResult; slot: int): bool =
  let owner = layout.owner
  owner != nil and not owner.closed and not owner.inBuild and owner.hasFrame and
    layout.generation == owner.generation and slot > 0 and
    slot < owner.nodes.len and owner.nodes[slot].clickHandler != nil

proc nextFocusSlot(layout: LayoutResult; current: int; reverse: bool): int =
  let owner = layout.owner
  if owner == nil or owner.closed or owner.inBuild or not owner.hasFrame or
      layout.generation != owner.generation:
    return -1
  let last = owner.nodes.high
  if last <= 0:
    return -1
  var slot = current
  if slot < 1 or slot > last:
    slot = if reverse: 1 else: 0
  for _ in 0..<last:
    if reverse:
      dec slot
      if slot < 1:
        slot = last
    else:
      inc slot
      if slot > last:
        slot = 1
    if layout.focusableSlot(slot):
      return slot
  -1

proc accessibilityTree(layout: LayoutResult;
                      focusSlot: int): platform.AccessTree =
  let owner = layout.owner
  if owner == nil or owner.closed or layout.generation != owner.generation or
      layout.rects.len != owner.nodes.len:
    return
  if layout.focusableSlot(focusSlot):
    result.focus = uint64(focusSlot + 1)
  var accessIndex = newSeq[int](owner.nodes.len)
  for index in accessIndex.mitems:
    index = -1
  for slot in 1..<owner.nodes.len:
    let node = owner.nodes[slot]
    let image = node.bitmap != nil or node.vector != nil
    if image and node.label.len == 0 and node.clickHandler == nil and
        not node.focusable:
      continue
    if not image and not node.hasText and node.clickHandler == nil and
        not node.focusable and node.label.len == 0:
      continue

    let role = if node.clickHandler != nil:
        platform.roleButton
      elif node.hasText:
        platform.roleText
      elif image:
        platform.roleImage
      else:
        platform.roleGroup
    var label = node.label
    if label.len == 0 and node.hasText:
      label = node.textValue
    let parentSlot = int(node.parent)
    let parent = if parentSlot >= 0: accessIndex[parentSlot] else: -1
    let rect = layout.rects[slot]
    var accessible = platform.AccessNode(id: uint64(slot + 1),
      parent: parent, role: role, label: label,
      bounds: platform.RectF(x: rect.x.float64, y: rect.y.float64,
        w: rect.w.float64, h: rect.h.float64))
    if node.focusable or node.clickHandler != nil:
      accessible.states = platform.accessFocusable
      accessible.actions = platform.actionFocus
    if role == platform.roleButton:
      accessible.actions = accessible.actions or platform.actionPress
    result.nodes.add(accessible)
    accessIndex[slot] = result.nodes.high

proc updateAccessibility(rt: Runtime) =
  if rt.accessibilityOn and rt.conn.surface != nil:
    rt.conn.surface.updateAccessibility(
      rt.frameLayout.accessibilityTree(rt.focusSlot))

proc cancelKeyPress(rt: Runtime) =
  rt.keyPressSlot = -1
  rt.keyPressKey = platform.keyUnknown

proc requestFrame(rt: Runtime)

proc refreshPointer(rt: Runtime) =
  rt.hoverSlots.setLen(0)
  rt.pressedSlots.setLen(0)
  let under = if rt.hasPointer:
      rt.frameLayout.slotsAt(rt.pointerX, rt.pointerY)
    else:
      @[]
  if rt.pressTarget.owner != nil:
    for slot in rt.pressHoverSlots:
      if slot in under:
        rt.hoverSlots.add(slot)
        rt.pressedSlots.add(slot)
  else:
    rt.hoverSlots = under
    rt.pressedSlots.setLen(0)
  if rt.frameLayout.clickableSlot(rt.keyPressSlot) and
      rt.focusSlot == rt.keyPressSlot and rt.keyPressSlot notin rt.pressedSlots:
    rt.pressedSlots.add(rt.keyPressSlot)

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

  rt.refreshPointer()
  rt.context.owner.hoveredSlots = rt.hoverSlots
  rt.context.owner.pressedSlots = rt.pressedSlots
  rt.context.owner.clickedSlots = rt.clickedSlots
  rt.context.owner.focusedSlots.setLen(0)
  rt.context.owner.focusVisibleSlots.setLen(0)
  if rt.focusSlot > 0:
    rt.context.owner.focusedSlots.add(rt.focusSlot)
    if rt.keyboardFocusVisible:
      rt.context.owner.focusVisibleSlots.add(rt.focusSlot)
  rt.clickedSlots.setLen(0)
  rt.context.build(rt.view)
  let layout = rt.context.layout(width, height)
  if rt.focusSlot >= 0 and not layout.focusableSlot(rt.focusSlot):
    rt.focusSlot = -1
    rt.keyboardFocusVisible = false
    rt.cancelKeyPress()
    layout.owner.focusedSlots.setLen(0)
    layout.owner.focusVisibleSlots.setLen(0)
    for slot in 1..<layout.owner.nodes.len:
      layout.owner.nodes[slot].focused = false
      layout.owner.nodes[slot].focusVisible = false
    rt.requestFrame()
  rt.frameLayout = layout
  rt.frameScene = layout.paintScene(scale)
  rt.hasScene = true
  rt.updateAccessibility()
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
  of platform.keyPressed:
    if ev.key == platform.keyTab and
        (ev.mods and (platform.modCtrl or platform.modAlt or
          platform.modSuper)) == 0:
      let next = rt.frameLayout.nextFocusSlot(rt.focusSlot,
        (ev.mods and platform.modShift) != 0)
      if next >= 0:
        rt.cancelKeyPress()
        rt.focusSlot = next
        rt.keyboardFocusVisible = true
        rt.refreshPointer()
        rt.requestFrame()
        return true
      return false
    if ev.key in {platform.keyEnter, platform.keySpace} and
        (ev.mods and (platform.modCtrl or platform.modAlt or
          platform.modSuper)) == 0 and rt.focusSlot > 0 and
        rt.frameLayout.clickableSlot(rt.focusSlot):
      if not ev.repeat:
        rt.keyPressSlot = rt.focusSlot
        rt.keyPressKey = ev.key
        rt.keyboardFocusVisible = true
        rt.refreshPointer()
        rt.requestFrame()
      return true
    false
  of platform.keyReleased:
    if ev.key == rt.keyPressKey and rt.keyPressSlot > 0:
      let slot = rt.keyPressSlot
      let activate = rt.focusSlot == slot and
        rt.frameLayout.clickableSlot(slot)
      rt.cancelKeyPress()
      if activate:
        let handler = rt.frameLayout.owner.nodes[slot].clickHandler
        handler()
        rt.clickedSlots = @[slot]
      rt.refreshPointer()
      rt.requestFrame()
      return true
    false
  of platform.pointerMove:
    let previousHover = rt.hoverSlots
    let previousPressed = rt.pressedSlots
    rt.pointerX = float32(ev.x)
    rt.pointerY = float32(ev.y)
    rt.hasPointer = true
    rt.refreshPointer()
    if rt.hoverSlots != previousHover or rt.pressedSlots != previousPressed:
      rt.requestFrame()
    false
  of platform.pointerDown:
    if ev.button != 0:
      return false
    let previousHover = rt.hoverSlots
    let previousPressed = rt.pressedSlots
    let previousFocus = rt.focusSlot
    let previousFocusVisible = rt.keyboardFocusVisible
    rt.cancelKeyPress()
    rt.pointerX = float32(ev.x)
    rt.pointerY = float32(ev.y)
    rt.hasPointer = true
    rt.pressTarget = rt.frameLayout.targetAt(rt.pointerX, rt.pointerY)
    rt.pressHoverSlots = rt.frameLayout.slotsAt(rt.pointerX, rt.pointerY)
    if rt.pressTarget.owner != nil:
      let slot = int(rt.pressTarget.slot)
      if rt.frameLayout.focusableSlot(slot):
        rt.focusSlot = slot
        rt.keyboardFocusVisible = false
    rt.refreshPointer()
    if rt.hoverSlots != previousHover or rt.pressedSlots != previousPressed:
      rt.requestFrame()
    if rt.focusSlot != previousFocus or
        rt.keyboardFocusVisible != previousFocusVisible:
      rt.requestFrame()
    return rt.pressTarget.owner != nil
  of platform.pointerUp:
    if ev.button != 0:
      return false
    let previousHover = rt.hoverSlots
    let previousPressed = rt.pressedSlots
    rt.pointerX = float32(ev.x)
    rt.pointerY = float32(ev.y)
    rt.hasPointer = true
    var clickedSlot = -1
    result = rt.frameLayout.dispatchClick(rt.pressTarget,
      rt.pointerX, rt.pointerY, clickedSlot)
    rt.clickedSlots.setLen(0)
    if result:
      rt.clickedSlots.add(clickedSlot)
    rt.pressTarget = Element()
    rt.pressHoverSlots.setLen(0)
    rt.refreshPointer()
    if result or rt.hoverSlots != previousHover or
        rt.pressedSlots != previousPressed:
      rt.requestFrame()
    return result
  of platform.surfaceBlur:
    let previousPressed = rt.pressedSlots
    let previousFocusVisible = rt.keyboardFocusVisible
    rt.cancelKeyPress()
    rt.keyboardFocusVisible = false
    rt.pressTarget = Element()
    rt.pressHoverSlots.setLen(0)
    rt.refreshPointer()
    if rt.pressedSlots != previousPressed or previousFocusVisible:
      rt.requestFrame()
    false
  of platform.pointerLeave:
    let previousHover = rt.hoverSlots
    let previousPressed = rt.pressedSlots
    rt.hasPointer = false
    rt.refreshPointer()
    if rt.hoverSlots != previousHover or rt.pressedSlots != previousPressed:
      rt.requestFrame()
    false
  of platform.accessibilityOn:
    rt.accessibilityOn = true
    rt.updateAccessibility()
    true
  of platform.accessAction:
    if ev.action == platform.accessPress:
      result = rt.frameLayout.dispatchAccessPress(ev.id)
      if result:
        let slot = int(ev.id - 1)
        rt.clickedSlots = @[slot]
        rt.focusSlot = slot
        rt.keyboardFocusVisible = false
        rt.cancelKeyPress()
        rt.requestFrame()
    elif ev.action == platform.accessFocus and ev.id > 0:
      let slot = int(ev.id - 1)
      if rt.frameLayout.focusableSlot(slot):
        let changed = rt.focusSlot != slot or rt.keyboardFocusVisible
        rt.focusSlot = slot
        rt.keyboardFocusVisible = false
        rt.cancelKeyPress()
        if changed:
          rt.requestFrame()
        result = true
    return result
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
  let rt = Runtime(conn: conn, view: content.view, context: newContext(),
                   focusSlot: -1, keyPressSlot: -1)
  conn.event = proc(ev: platform.SurfaceEvent): bool = rt.event(ev)
  conn.changed = proc() = rt.requestFrame()
  conn.themeChanged = proc() = rt.requestFrame()
  conn.titleBarChanged = proc() = rt.requestFrame()
  conn.localeChanged = proc() = rt.requestFrame()
  conn.capture = proc(): tuple[width, height: int, rgba: seq[byte]] =
    rt.capture()
  conn.detach = proc() = rt.close()
  rt.requestFrame()
