## Pointer-driven offsets for native UI elements.

const
  dragOffsetXKey = "mynim:draggable:x"
  dragOffsetYKey = "mynim:draggable:y"
  maxDragFling = 8000'f32

proc nearest*(points: varargs[Point]): proc(point: Point): Point {.closure.} =
  ## Returns a snap function that chooses the closest of the supplied points.
  if points.len == 0:
    raise newException(ValueError, "ui: nearest needs points")
  let choices = @points
  result = proc(point: Point): Point =
    result = choices[0]
    var distance = Inf.float32
    for choice in choices:
      let dx = choice.x - point.x
      let dy = choice.y - point.y
      let candidate = dx * dx + dy * dy
      if candidate < distance:
        result = choice
        distance = candidate

proc finitePoint(point: Point): bool =
  finiteMotion(float64(point.x)) and finiteMotion(float64(point.y))

proc clampDrag(point, rest: Point; axes: set[DragAxis]; bounded: bool;
               bounds: Rect): Point =
  result = point
  if DragAxis.Horizontal notin axes:
    result.x = rest.x
  elif bounded:
    result.x = min(max(result.x, bounds.x), bounds.x + bounds.w)
  if DragAxis.Vertical notin axes:
    result.y = rest.y
  elif bounded:
    result.y = min(max(result.y, bounds.y), bounds.y + bounds.h)

proc bandDrag(point, origin: Point; axes: set[DragAxis];
              options: DraggableOptions; parentWidth,
              parentHeight: float32): Point =
  result = point
  if DragAxis.Horizontal notin axes:
    result.x = origin.x
  elif options.bounds.isSome:
    let bounds = options.bounds.get
    if options.rigid:
      result.x = min(max(result.x, bounds.x), bounds.x + bounds.w)
    else:
      result.x = rubberband(result.x, bounds.x, bounds.x + bounds.w,
        parentWidth)
  if DragAxis.Vertical notin axes:
    result.y = origin.y
  elif options.bounds.isSome:
    let bounds = options.bounds.get
    if options.rigid:
      result.y = min(max(result.y, bounds.y), bounds.y + bounds.h)
    else:
      result.y = rubberband(result.y, bounds.y, bounds.y + bounds.h,
        parentHeight)

proc flingVelocity(point: Point): Point =
  if not finitePoint(point):
    return
  let speed = hypot(float64(point.x), float64(point.y))
  if speed > float64(maxDragFling):
    let scale = maxDragFling / float32(speed)
    result = Point(x: point.x * scale, y: point.y * scale)
  else:
    result = point

proc animateWithVelocity(e: Element; key: string; target: float32;
                         animation: Animation; velocity: float32): float32 =
  result = e.animate(key, target, animation)
  let node = e.node
  if node == nil:
    return
  var channels = e.owner.animations.getOrDefault(node[].identity)
  if not channels.hasKey(key):
    return
  var channel = channels[key]
  channel.velocity = if e.owner.reduceMotion or not channel.moving:
      0
    else:
      float64(velocity)
  channels[key] = channel
  e.owner.animations[node[].identity] = channels

proc configureDraggable(e: Element; current: Point;
                        options: DraggableOptions):
    tuple[target, shown: Point] =
  let node = e.node
  if node == nil:
    return (current, current)
  if not finitePoint(current):
    raise newException(ValueError, "ui: drag offset values must be finite")
  if options.bounds.isSome:
    let bounds = options.bounds.get
    if not finiteMotion(float64(bounds.x)) or
        not finiteMotion(float64(bounds.y)) or
        not finiteMotion(float64(bounds.w)) or
        not finiteMotion(float64(bounds.h)):
      raise newException(ValueError, "ui: drag bounds must be finite")
    if bounds.w < 0 or bounds.h < 0:
      raise newException(ValueError, "ui: drag bounds must not have a negative size")
  options.animation.validateAnimation()

  let owner = e.owner
  let identity = node[].identity
  let state = owner.draggableStates.mgetOrPut(identity, DraggableState())
  let axes = if options.axis == {}:
      {DragAxis.Horizontal, DragAxis.Vertical}
    else:
      options.axis
  let bounds = if options.bounds.isSome: options.bounds.get else: Rect()
  result.target = clampDrag(current, current, axes, options.bounds.isSome,
    bounds)
  node[].draggable = true
  if node[].parent >= 0 and int(node[].parent) < owner.nodes.len:
    owner.trackedBounds.incl(owner.nodes[int(node[].parent)].identity)

  let wasMoving = not e.settled(dragOffsetXKey) or
    not e.settled(dragOffsetYKey)
  var shown = Point(
    x: e.animate(dragOffsetXKey, result.target.x, options.animation),
    y: e.animate(dragOffsetYKey, result.target.y, options.animation))
  let gesture = owner.draggableGesture
  if gesture.identity == identity and gesture.serial != 0:
    if state.gestureSerial != gesture.serial:
      state.gestureSerial = gesture.serial
      state.pressing = gesture.held or gesture.released
      state.caught = wasMoving
      state.fromOffset = shown
      shown.x = e.jump(dragOffsetXKey, shown.x)
      shown.y = e.jump(dragOffsetYKey, shown.y)
      result.target = shown
    if state.pressing and gesture.held:
      var desired = state.fromOffset
      if gesture.moved:
        desired = Point(
          x: state.fromOffset.x + gesture.x - gesture.pressX,
          y: state.fromOffset.y + gesture.y - gesture.pressY)
        let parent = int(node[].parent)
        let parentBounds = if parent >= 0 and parent < owner.nodes.len:
            owner.lastBounds.getOrDefault(owner.nodes[parent].identity)
          else:
            Rect()
        desired = bandDrag(desired, state.fromOffset, axes, options,
          parentBounds.w, parentBounds.h)
      result.target = desired
      shown.x = e.jump(dragOffsetXKey, desired.x)
      shown.y = e.jump(dragOffsetYKey, desired.y)
      result.target = shown
    elif state.pressing and gesture.released:
      state.pressing = false
      let shouldSettle = gesture.moved or state.caught
      if shouldSettle:
        var velocity = if gesture.moved and not gesture.canceled:
            flingVelocity(Point(x: gesture.velocityX, y: gesture.velocityY))
          else:
            Point()
        if DragAxis.Horizontal notin axes:
          velocity.x = 0
        if DragAxis.Vertical notin axes:
          velocity.y = 0
        var target = shown
        if shouldSettle and not gesture.canceled and options.snap != nil:
          let projected = clampDrag(Point(
            x: project(shown.x, velocity.x),
            y: project(shown.y, velocity.y)), shown, axes,
            options.bounds.isSome, bounds)
          target = options.snap(projected)
          if not finitePoint(target):
            raise newException(ValueError,
              "ui: drag snap values must be finite")
        target = clampDrag(target, shown, axes, options.bounds.isSome, bounds)
        result.target = target
        var animation = options.animation
        animation.delay = DurationZero
        discard e.animateWithVelocity(dragOffsetXKey, target.x, animation,
          velocity.x)
        discard e.animateWithVelocity(dragOffsetYKey, target.y, animation,
          velocity.y)
        shown = Point(
          x: e.animate(dragOffsetXKey, target.x, animation),
          y: e.animate(dragOffsetYKey, target.y, animation))
      state.caught = false
  result.shown = shown
  if options.rigid and options.bounds.isSome:
    result.shown = clampDrag(shown, shown, axes, true, bounds)
  node[].draggableDragging = gesture.identity == identity and gesture.held and
    gesture.moved
  node[].draggableMoving = not e.settled(dragOffsetXKey) or
    not e.settled(dragOffsetYKey)
  node[].dragOffset = result.shown

proc draggable*(e: Element; offset: var Point;
                options = DraggableOptions()): Element =
  ## Lets pointer movement offset this element and animates it when released.
  result = e
  let node = e.node
  if node == nil:
    return
  let configured = e.configureDraggable(offset, options)
  offset = configured.target

proc draggable*(e: Element;
                options = DraggableOptions()): Element =
  ## Lets pointer movement offset this element using retained internal state.
  result = e
  let node = e.node
  if node == nil:
    return
  let state = e.owner.draggableStates.mgetOrPut(node[].identity,
    DraggableState())
  let configured = e.configureDraggable(state.ownOffset, options)
  state.ownOffset = configured.target

proc dragOffset*(e: Element): Point =
  ## Returns the current shown offset of a Draggable element.
  let node = e.node
  if node != nil and node[].draggable:
    result = node[].dragOffset
