## Public value types used by elements and layout.

type
  Align* {.pure.} = enum ## Positions children in a row, column, or grid.
    Start ## Left in a row; top in a column.
    Center
    End ## Right in a row; bottom in a column.
    Stretch
    SpaceBetween
    SpaceAround
    SpaceEvenly
    Auto ## Used internally when no alignment was specified.

  TrackKind = enum
    trackFit, trackFixed, trackFr

  Track* = object ## A fixed, fractional, or content-fitting grid track.
    kind: TrackKind
    value: float32

  Rect* = object ## A rectangle in device independent pixels.
    x*, y*, w*, h*: float32

  Fit* {.pure.} = enum ## How an image fills its element.
    Contain ## Scales inside the element and keeps aspect ratio.
    Cover ## Covers the element and crops the excess.
    FillBox ## Stretches to the element.
    ScaleDown ## Uses Contain only when the image is too large.
    NaturalSize ## Centers the image at its natural size and crops it.

  BorderStyle* {.pure.} = enum ## How an element's border is drawn.
    Solid
    Dashed

  LinearGradient* = object ## Two color stops blended across an element.
    fromColor*, toColor*: Color ## Colors at the start and end of the line.
    angle*: float32 ## Degrees clockwise from upward: 90 runs left to right.
    start*, stop*: float32 ## Stop positions from 0 to 1; both zero mean 0 and 1.
    oklab*: bool ## Mixes the stops in Oklab when true, sRGB otherwise.

  Easing* = proc(progress: float32): float32 {.closure.}
    ## Maps progress from 0 to 1 to the curve's progress.

  SpringOptions* = object ## Physical or perceptual spring settings.
    duration*: Duration ## Approximate settling time; zero means 500 ms.
    bounce*: float64 ## Negative is slower; positive adds overshoot.
    mass*, stiffness*, damping*: float64
    precision*: float64
    velocity*: float32

  Animation* = object ## A timed easing curve or spring for scrolling.
    duration*: Duration ## Positive selects a curve; zero selects a spring.
    ease*: Easing ## Defaults to easeOut for timed animations.
    spring*: SpringOptions ## Spring settings when duration is zero.
    delay*: Duration ## Holds the current motion before changing target.

  ScrollMotionChannel = object
    value, velocity, target: float64
    at: MonoTime
    moving, curve, pending: bool
    fromValue: float64
    start: MonoTime
    duration: Duration
    ease: Easing
    mass, stiffness, damping, precision: float64
    pendingTarget: float64
    pendingAt: MonoTime
    pendingAnimation: Animation

  ScrollMotion = ref object
    x, y: ScrollMotionChannel
    targetX, targetY: float32
    animation: Animation
    initialized, changed: bool

  ScrollState* = ref object ## Persistent offset for one scroll container.
    offsetX, offsetY: float32
    maxX, maxY: float32
    scrollbarDragging: bool
    motion: ScrollMotion

  ListRequestKind = enum
    listNoRequest, listRequestToRow, listRequestIntoView, listRequestToEnd

  ListHeightBlock = ref object
    heights: array[64, float32]
    known: uint64
    knownCount: int
    sum: float64

  ListHeights = object
    count: int
    blockIds: seq[int]
    blocks: seq[ListHeightBlock]
    defaultHeight: float64
    prefixHeights: seq[float64]
    prefixCounts: seq[int]
    dirty: bool

  ListRowKey* = proc(row: int): string {.closure.} ## Returns a stable, unique row key.
  ListRowLabel* = proc(row: int): string {.closure.} ## Names and searches a list row.

  ListSelectedRow = object
    row, nearRow: int
    key: string
    keyValid: bool

  ListState* = ref object
    ## Persistent scroll and measured-height state for a virtualized list.
    scrollState: ScrollState
    heights: ListHeights
    rowKey: ListRowKey
    rowLabel: ListRowLabel
    keepOffset: bool
    rowCount: int
    viewportHeight: float32
    first, last: int
    selectedRow: int
    selectedKey: string
    chosenRows: seq[ListSelectedRow]
    selectedKeys: HashSet[string]
    selectedIndices: HashSet[int]
    typedLabel: string
    typedAt: MonoTime
    selectionPivot: int
    selectionPivotKey: string
    selectionPivotKeyValid: bool
    selectionSpan: int
    anchor: int
    anchorKey: string
    anchorInset: float64
    anchorScrollY: float32
    followOffsetY, followMaxY: float32
    followEndAnimation: Animation
    followLag: ScrollMotionChannel
    followRow: int
    followKey: string
    followBelow: float64
    followWidth: float32
    laidOut, visibleRead, atEnd: bool
    anchorValid, selectedKeyValid, selectionEnabled: bool
    multiSelectionEnabled: bool
    followEnd, following, followStarted, followRequest: bool
    followEndAnimated, followSeen, followKeyValid: bool
    request: ListRequestKind
    requestRow: int
    requestAlign: Align
    gap: float32
    frameOwner: pointer
    frameSlot: int32
    generation: uint32

  ScrollbarDrag = object
    state: ScrollState
    horizontal: bool
    pointerStart, offsetStart, rangeStart, travel: float32

const
  Auto* = Inf.float32 ## Automatic length, used by margins.

proc contains*(r: Rect; x, y: float32): bool =
  ## Reports whether the point is inside r, including its top and left edges.
  x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h

proc newScrollState*(): ScrollState =
  ## Creates persistent state for a scroll container.
  new(result)

proc linear*(progress: float32): float32 = progress

proc easeIn*(progress: float32): float32 = progress * progress

proc easeOut*(progress: float32): float32 =
  1'f32 - (1'f32 - progress) * (1'f32 - progress)

proc easeInOut*(progress: float32): float32 =
  if progress < 0.5'f32:
    2'f32 * progress * progress
  else:
    1'f32 - 2'f32 * (1'f32 - progress) * (1'f32 - progress)

let Smooth* = Animation(spring: SpringOptions(
  duration: initDuration(milliseconds = 500)))
let Snappy* = Animation(spring: SpringOptions(
  duration: initDuration(milliseconds = 500), bounce: 0.15))
let Bouncy* = Animation(spring: SpringOptions(
  duration: initDuration(milliseconds = 500), bounce: 0.3))

proc finiteMotion(value: float64): bool =
  classify(value) notin {fcNan, fcInf, fcNegInf}

proc cubicBezier*(x1, y1, x2, y2: float32): Easing =
  ## Creates a CSS-style cubic Bézier easing from (0, 0) to (1, 1).
  for value in [x1, y1, x2, y2]:
    if not finiteMotion(float64(value)):
      raise newException(ValueError, "ui: easing values must be finite")
  if x1 < 0 or x1 > 1 or x2 < 0 or x2 > 1:
    raise newException(ValueError,
      "ui: cubicBezier x1 and x2 must be within 0 and 1")
  let cx = 3 * float64(x1)
  let bx = 3 * (float64(x2) - float64(x1)) - cx
  let ax = 1 - cx - bx
  let cy = 3 * float64(y1)
  let by = 3 * (float64(y2) - float64(y1)) - cy
  let ay = 1 - cy - by
  let curveX = proc(t: float64): float64 = ((ax * t + bx) * t + cx) * t
  result = proc(x: float32): float32 =
    if x <= 0 or x >= 1:
      return x
    let target = float64(x)
    var t = target
    for _ in 0..<8:
      let dx = (3 * ax * t + 2 * bx) * t + cx
      if abs(dx) < 1e-6:
        break
      let error = curveX(t) - target
      if abs(error) < 1e-7:
        return float32(((ay * t + by) * t + cy) * t)
      t -= error / dx
    var lo = 0.0
    var hi = 1.0
    t = target
    for _ in 0..<40:
      let value = curveX(t)
      if abs(value - target) < 1e-7:
        break
      if value < target:
        lo = t
      else:
        hi = t
      t = (lo + hi) / 2
    float32(((ay * t + by) * t + cy) * t)

proc springPhysics(options: SpringOptions):
    tuple[mass, stiffness, damping, precision: float64] =
  for value in [options.bounce, options.mass, options.stiffness,
      options.damping, options.precision, float64(options.velocity)]:
    if not finiteMotion(value):
      raise newException(ValueError, "ui: spring values must be finite")
  if options.duration < DurationZero or options.mass < 0 or
      options.stiffness < 0 or options.damping < 0 or options.precision < 0:
    raise newException(ValueError, "ui: spring options must not be negative")

  result.mass = if options.mass == 0: 1 else: options.mass
  result.precision = if options.precision == 0: 0.001 else: options.precision
  if options.stiffness != 0 or options.damping != 0:
    if options.duration != DurationZero or options.bounce != 0:
      raise newException(ValueError,
        "ui: a spring takes duration and bounce or stiffness and damping, not both")
    result.stiffness = if options.stiffness == 0: 170 else: options.stiffness
    result.damping = if options.damping == 0: 26 else: options.damping
  else:
    if options.bounce <= -1 or options.bounce >= 1:
      raise newException(ValueError,
        "ui: spring bounce must be between -1 and 1")
    let duration = if options.duration == DurationZero:
        0.5
      else:
        float64(options.duration.inNanoseconds) / 1_000_000_000
    let w = 2 * PI / duration
    var ratio = 1 - options.bounce
    if options.bounce < 0:
      ratio = 1 / (1 + options.bounce)
    result.stiffness = w * w * result.mass
    result.damping = 2 * ratio * w * result.mass

  let w = result.stiffness / result.mass
  let a = result.damping / result.mass
  if not finiteMotion(w) or not finiteMotion(a) or w <= 0 or a <= 0:
    raise newException(ValueError, "ui: spring options exceed numerical range")

proc validateAnimation(animation: Animation) =
  if animation.duration < DurationZero or animation.delay < DurationZero:
    raise newException(ValueError,
      "ui: animation durations must not be negative")
  if animation.duration == DurationZero:
    discard springPhysics(animation.spring)

proc solveSpring(x, velocity, mass, stiffness, damping,
                 dt: float64): tuple[x, velocity: float64] =
  if x == 0 and velocity == 0:
    return
  let w = sqrt(stiffness / mass)
  let a = (damping / mass) / 2
  let discriminant = a * a - w * w
  if abs(discriminant) < 1e-8 * w * w:
    let b = velocity + a * x
    let decay = exp(-a * dt)
    return ((x + b * dt) * decay, (velocity - a * b * dt) * decay)
  if discriminant < 0:
    let f = sqrt(-discriminant)
    let angle = f * dt
    let sn = sin(angle)
    let cs = cos(angle)
    let b = (velocity + a * x) / f
    let decay = exp(-a * dt)
    let y = x * cs + b * sn
    return (y * decay, (f * (-x * sn + b * cs) - a * y) * decay)
  let f = sqrt(discriminant)
  let r1 = -w * w / (a + f)
  let r2 = -a - f
  let c1 = (velocity - r2 * x) / (r1 - r2)
  let c2 = x - c1
  let u = c1 * exp(r1 * dt)
  let z = c2 * exp(r2 * dt)
  (u + z, r1 * u + r2 * z)

proc step(channel: var ScrollMotionChannel; now: MonoTime) =
  let dt = float64((now - channel.at).inNanoseconds) / 1_000_000_000
  if dt <= 0:
    channel.at = now
    return
  channel.at = now
  if not channel.moving:
    channel.velocity = 0
    return
  if channel.curve:
    let duration = float64(channel.duration.inNanoseconds) / 1_000_000_000
    let progress = float64((now - channel.start).inNanoseconds) /
      1_000_000_000 / duration
    if progress >= 1:
      channel.value = channel.target
      channel.velocity = 0
      channel.moving = false
      return
    let t = float32(max(progress, 0.0))
    let easing = if channel.ease == nil: easeOut else: channel.ease
    let eased = easing(t)
    if not finiteMotion(float64(eased)):
      raise newException(ValueError, "ui: easing result must be finite")
    let span = channel.target - channel.fromValue
    channel.value = channel.fromValue + span * float64(eased)
    let lo = max(float64(t) - 1e-3, 0.0)
    let hi = min(float64(t) + 1e-3, 1.0)
    if hi > lo:
      let slope = float64(easing(float32(hi)) - easing(float32(lo))) /
        (hi - lo) / duration
      if not finiteMotion(slope) or not finiteMotion(span * slope):
        raise newException(ValueError, "ui: easing slope must be finite")
      channel.velocity = span * slope
    else:
      channel.velocity = 0
    return
  let moved = solveSpring(channel.value - channel.target, channel.velocity,
    channel.mass, channel.stiffness, channel.damping, dt)
  channel.value = channel.target + moved.x
  channel.velocity = moved.velocity
  if abs(moved.x) <= channel.precision and
      abs(moved.velocity) <= channel.precision *
        sqrt(channel.stiffness / channel.mass):
    channel.value = channel.target
    channel.velocity = 0
    channel.moving = false

proc advance(channel: var ScrollMotionChannel; now: MonoTime) =
  if channel.pending and now >= channel.pendingAt:
    channel.step(channel.pendingAt)
    let target = channel.pendingTarget
    let animation = channel.pendingAnimation
    channel.pending = false
    channel.target = target
    channel.moving = true
    if animation.duration > DurationZero:
      channel.curve = true
      channel.fromValue = channel.value
      channel.start = channel.pendingAt
      channel.duration = animation.duration
      channel.ease = if animation.ease == nil: easeOut else: animation.ease
    else:
      let physics = springPhysics(animation.spring)
      channel.curve = false
      channel.mass = physics.mass
      channel.stiffness = physics.stiffness
      channel.damping = physics.damping
      channel.precision = physics.precision
      if animation.spring.velocity != 0:
        channel.velocity = float64(animation.spring.velocity)
    channel.at = channel.pendingAt
  channel.step(now)

proc headFor(channel: var ScrollMotionChannel; target: float64;
             animation: Animation; now: MonoTime) =
  if animation.delay > DurationZero:
    channel.pending = true
    channel.pendingTarget = target
    channel.pendingAt = now + animation.delay
    channel.pendingAnimation = animation
    channel.pendingAnimation.delay = DurationZero
    return
  channel.target = target
  channel.moving = true
  channel.pending = false
  if animation.duration > DurationZero:
    channel.curve = true
    channel.fromValue = channel.value
    channel.start = now
    channel.duration = animation.duration
    channel.ease = if animation.ease == nil: easeOut else: animation.ease
    return
  let physics = springPhysics(animation.spring)
  channel.curve = false
  channel.mass = physics.mass
  channel.stiffness = physics.stiffness
  channel.damping = physics.damping
  channel.precision = physics.precision
  if animation.spring.velocity != 0:
    channel.velocity = float64(animation.spring.velocity)

proc animate(state: ScrollState; now: MonoTime;
             reduceMotion: bool): bool =
  let motion = state.motion
  if motion == nil:
    return false
  if not motion.initialized:
    motion.x = ScrollMotionChannel(value: float64(state.offsetX),
      target: float64(state.offsetX), at: now)
    motion.y = ScrollMotionChannel(value: float64(state.offsetY),
      target: float64(state.offsetY), at: now)
    motion.initialized = true
  if reduceMotion:
    let targetX = min(max(float64(motion.targetX), 0), float64(state.maxX))
    let targetY = min(max(float64(motion.targetY), 0), float64(state.maxY))
    state.offsetX = float32(targetX)
    state.offsetY = float32(targetY)
    state.motion = nil
    return false
  if motion.changed:
    let targetX = min(max(float64(motion.targetX), 0), float64(state.maxX))
    let targetY = min(max(float64(motion.targetY), 0), float64(state.maxY))
    motion.x.advance(now)
    motion.y.advance(now)
    motion.x.headFor(targetX, motion.animation, now)
    motion.y.headFor(targetY, motion.animation, now)
    motion.changed = false
  motion.x.advance(now)
  motion.y.advance(now)
  state.offsetX = min(max(float32(motion.x.value), 0'f32), state.maxX)
  state.offsetY = min(max(float32(motion.y.value), 0'f32), state.maxY)
  result = motion.x.moving or motion.x.pending or
    motion.y.moving or motion.y.pending
  if not result:
    state.offsetX = min(max(float32(motion.x.target), 0'f32), state.maxX)
    state.offsetY = min(max(float32(motion.y.target), 0'f32), state.maxY)
    state.motion = nil

proc stopScrollMotion(state: ScrollState) =
  if state != nil:
    state.motion = nil

func offset*(state: ScrollState): tuple[x, y: float32] =
  ## Returns the current horizontal and vertical offsets in DIPs.
  if state == nil: return
  (x: state.offsetX, y: state.offsetY)

func maxOffset*(state: ScrollState): tuple[x, y: float32] =
  ## Returns the greatest horizontal and vertical offsets in DIPs.
  if state == nil: return
  (x: state.maxX, y: state.maxY)

proc scrollTo*(state: ScrollState; x, y: float32) =
  ## Sets the requested offsets immediately; layout clamps to the content.
  if state == nil:
    raise newException(ValueError, "ui: scroll state cannot be nil")
  if classify(x) in {fcNan, fcInf, fcNegInf} or
      classify(y) in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "ui: scroll offsets must be finite")
  state.offsetX = max(x, 0'f32)
  state.offsetY = max(y, 0'f32)
  state.motion = nil

proc scrollTo*(state: ScrollState; x, y: float32; animation: Animation) =
  ## Smoothly moves to the requested offsets, clamped to the content range.
  ## Input interrupts the animation; reduced motion goes to the target at once.
  ## Smooth, Snappy, Bouncy, or a timed Animation can be passed. For timed
  ## animations, use std/times.initDuration to set duration and delay.
  if state == nil:
    raise newException(ValueError, "ui: scroll state cannot be nil")
  if not finiteMotion(float64(x)) or not finiteMotion(float64(y)):
    raise newException(ValueError, "ui: scroll offsets must be finite")
  validateAnimation(animation)
  let targetX = max(x, 0'f32)
  let targetY = max(y, 0'f32)
  if state.motion != nil and state.motion.targetX == targetX and
      state.motion.targetY == targetY:
    return
  if state.motion == nil:
    state.motion = ScrollMotion()
  state.motion.targetX = targetX
  state.motion.targetY = targetY
  state.motion.animation = animation
  state.motion.changed = true

func scrolling*(state: ScrollState): bool =
  ## Reports whether an animated scroll is pending or in progress.
  state != nil and state.motion != nil
