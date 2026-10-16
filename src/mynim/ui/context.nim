## Frame scope and checked handles for elements in the current UI pass.

type
  Context* = ref ContextObj ## Stable context for one window's UI builds.

  ContextObj = object
    owner: ElementOwner
    theme: Theme
    reduceMotion: bool
    treeState: TreeState
    accordion: AccordionBuild
    accordionHeaders: Table[uint64, seq[uint64]]
    checkboxGroup: CheckboxGroupBuild
    segmentedToggles: bool
    formDepth: int
    pendingKey: string
    rightToLeft: bool
    hasPendingKey: bool
    themeEnabled, themeBackground: bool

  Handle* = object ## Stable UI-thread element reference rebound each build.
    state: HandleState

  Ref* = Handle ## Compatibility name for Handle.

  HandleState = ref object
    identity: uint64
    bindings: seq[HandleBinding]
    pending: bool

  HandleBinding = ref object
    owner: ElementOwner
    identity, requestIdentity, handleIdentity: uint64
    slot, generation: uint32
    requested: bool

  HandleFocusRequest = object
    handleIdentity, identity: uint64

  UiActionKind = enum
    actionShortcut, actionChange, actionSubmit

  CheckboxGroupBuild = ref object
    boxes: seq[ptr bool]

  AccordionBuild = ref object
    headers, last: seq[uint64]

  UiAction = object
    handle: HandleState
    identity: uint64
    generation: uint32
    kind: UiActionKind
    modifiers: platform.Modifiers
    key: platform.Key
    action: proc() {.closure.}

  ScalarAnimation = object
    value, velocity, fromValue, target: float64
    at, startAt, pendingAt: MonoTime
    duration: Duration
    ease: Easing
    mass, stiffness, damping, precision: float64
    pendingTarget: float64
    pendingAnimation: Animation
    generation: uint32
    initialized, moving, curve, pending, jumped: bool

  ScalarSequence = object
    frames: seq[Keyframe]
    options: KeyframeOptions
    startAt: MonoTime
    fromValue, value: float32
    generation: uint32
    initialized, done: bool

  ColorMotion = object
    fromColor, targetColor, shown: Color
    progress: ScalarAnimation
    generation: uint32
    initialized: bool

  StepperRepeat = object
    started: MonoTime
    repeats: int64
    direction: int8
    initialized: bool

  NumberInputState = ref object
    text: string
    lastValue: float64
    pendingValue: float64
    hasPendingValue: bool

  TooltipState = object
    hover, focus, shown, dismissed: uint64
    hoverSince, focusSince, lastShown: MonoTime

  ElementOwner = ref object
    activeContext: Context
    nodes: seq[ElementNode]
    idSlots: Table[uint64, int]
    identityParents: Table[uint64, uint64]
    previousInteraction: Table[uint64, uint8]
    keyedSeen: HashSet[string]
    focusRequests: seq[HandleFocusRequest]
    actions: seq[UiAction]
    pendingNotices: Table[uint64, uint8]
    pendingSliderValues: Table[uint64, float64]
    stepperRepeats: Table[uint64, StepperRepeat]
    numberInputStates: Table[uint64, NumberInputState]
    tooltips: TooltipState
    rangeSliderDrags: Table[uint64, int8]
    pendingTextCallbacks: Table[uint64, seq[proc() {.closure.}]]
    pendingTextSubmitCallbacks: Table[uint64, seq[proc() {.closure.}]]
    textInputClients: Table[uint64, platform.TextInputClient]
    animations: Table[uint64, Table[string, ScalarAnimation]]
    colorMotions: Table[uint64, Table[string, ColorMotion]]
    keyframes: Table[uint64, Table[string, ScalarSequence]]
    frameNow: MonoTime
    committedRects: seq[Rect]
    lastBounds: Table[uint64, Rect]
    trackedBounds: HashSet[uint64]
    focusIdentity: uint64
    focusActive: bool
    invalidate: proc() {.closure.}
    natural: seq[NaturalSize]
    rectScratch: seq[Rect]
    paintSlots: seq[int]
    flexSlots: seq[int]
    flexLines: seq[FlexLine]
    gridScratch: GridScratch
    flexSizes, flexBases, flexMin, flexMax, flexFactors: seq[float32]
    hoveredSlots, pressedSlots, clickedSlots, focusedSlots,
      focusVisibleSlots: seq[int]
    generation: uint32
    parent: int32
    inBuild, reduceMotion, animating: bool
    hasFrame: bool
    closed: bool

  UiLengthKind = enum
    lengthAuto, lengthPixels, lengthPercent

  UiLength = object
    value: float32
    kind: UiLengthKind

  NaturalSize = object
    w, h: float32

  FlexLine = object
    first, pastLast: int
    main, cross: float32

  GridItem = object
    slot, col, row, colSpan, rowSpan: int

  GridContribution = object
    start, span: int
    minimum, maximum: float32

  GridScratch = object
    items: seq[GridItem]
    occupied: seq[bool]
    contributions: seq[GridContribution]
    values: seq[float32]

  Element* = object
    ## A checked 16-byte handle on 64-bit targets; it expires after its build callback.
    owner: ElementOwner
    slot: uint32
    generation: uint32

  Bitmap* = ref object
    ## A stable scene image created once and reused across frame builds.
    image: scene.Image
    pixelated: bool

  Svg* = ref object
    ## A parsed vector image and its recently rasterized sizes/colors.
    doc: svgRenderer.Doc
    width, height: float32
    pictures: seq[SvgPicture]

  SvgPicture = ref object
    width, height: int
    color: Color
    stretch: bool
    image: scene.Image

  UiShadow = object
    x, y, blur, spread: float32
    color: Color
    inset: bool

  ElementNode = object
    parent, firstChild, lastChild, nextSibling: int32
    identity: uint64
    childCount: uint64
    keyed: bool
    keyScope: string
    row, reverse, wrap, wrapReverse, grid, absolute, alignSet,
      justifySet, focusable, activateEnter, focused, focusVisible,
      focusRingDisabled, scrollX, scrollY,
      revealInScroll, rightToLeft, directionSet: bool
    focusGroupSet, groupSelects: bool
    tabStopSet, tabStop: bool
    formContainer, formField, formLabel, accessHidden, disabled,
      invalid, tooltipEnabled, tooltipOverlay, passThrough: bool
    focusOrientation: FocusOrientation
    logical: uint8
    clipX, clipY, hasFollowScroll: bool
    followScrollSlot: int32
    gridCol, gridRow, gridColSpan, gridRowSpan: int
    tooltipGap: float32
    # Overlay text is painted but excluded from the node's natural size.
    hasText, textNoWrap, textColorSet, textOverlay, listRowSelected,
      listRowFocusVisible, listRowHeader, listRowPinnedHeader: bool
    textMaxLines: int
    listRowAction: bool
    slider, sliderVertical, rating, stepper, numberInput, rangeSlider,
      rangeSliderThumb, splitPane, splitHandle, splitVertical: bool
    rangeSliderHandle: int8
    sliderLow, sliderHigh, sliderValue, sliderStep: float64
    sliderClampLow, sliderClampHigh: float64
    hasAccessRange: bool
    accessMin, accessMax, accessNow: float64
    accessStep: float64
    accessStepHandler: proc(delta: float64) {.closure.}
    textAlign: Align
    hovered, pressed, clicked, changed, submitted,
      valueChangedInBuild: bool
    label: string
    accessDescription: string
    tooltipText: string
    tooltipBuild: proc(tip: Element) {.closure.}
    labelTargetSlot, fieldLabelSlot, fieldContentSlot,
      fieldControlSlot, focusTargetSlot: int32
    textValue: string
    placeholder: string
    textStyle: textStack.Style
    textColor, textSelectionColor: Color
    shapedText: textStack.Layout
    textClient: platform.TextInputClient
    textAreaOwner: platform.TextInputClient
    textAreaLine: int
    clickHandler: proc(mods: platform.Modifiers) {.closure.}
    accessRole: platform.AccessRole
    accessSort: platform.AccessStates
    accessExtraStates: platform.AccessStates
    accessExtraActions: platform.AccessActions
    accessLevel: int
    accessRoleSet: bool
    keyHandler: UiKeyHandler
    treeAccessAction: TreeAccessAction
    treeAccessFocus: TreeAccessFocus
    tableState: ListState
    tableColumnId: string
    tableColumnIndex: int
    tableColumnFixed, tableColumnHeader, tableColumnFlexible: bool
    tableHeaderMenuArea: bool
    tableColumnMinWidth, tableColumnMaxWidth: float32
    tableResizeHandle, tableFitMeasure: bool
    bitmap: Bitmap
    imageRegion: Rect
    flipX, flipY: bool
    vector: Svg
    vectorColor: Color
    imageTint: Color
    grayscale: bool
    fit: Fit
    width, height, minW, minH, maxW, maxH, basis: UiLength
    aspectRatio: float32
    grow, shrink: float32
    pad, margin: array[4, float32]
    inset: array[4, UiLength]
    gapX, gapY: float32
    justify, align, selfAlign, alignContent, justifyItems,
      justifySelf: Align
    cols, rows: seq[Track]
    background, borderColor, listSelectedTextColor, focusRingColor: Color
    opacity: float32
    opacitySet: bool
    scrollState: ScrollState
    scrollbarColor: Color
    scrollbarWidth: float32
    scrollbarInsets: array[4, float32]
    listState: ListState
    listRowIndex: int
    hasGradient: bool
    gradient: LinearGradient
    shadows: seq[UiShadow]
    radius, border: array[4, float32]
    borderStyle: BorderStyle

  LayoutResult* = object
    ## Snapshot bounds calculated from a completed build.
    root*: Rect
    owner: ElementOwner
    generation: uint32
    rects: seq[Rect]
    animating: bool

const
  identityHovered = 1'u8 shl 0
  identityPressed = 1'u8 shl 1
  identityClicked = 1'u8 shl 2
  identityFocused = 1'u8 shl 3
  identityFocusVisible = 1'u8 shl 4
  noticeChanged = 1'u8 shl 0
  noticeSubmitted = 1'u8 shl 1
  rootIdentity = 0x6A09E667F3BCC909'u64
  identitySalt = 0xA5A5A5A5A5A5A5A5'u64
  identityGolden = 0x9E3779B97F4A7C15'u64
  identityKindGeneric = 0'u8
  identityKindBox = 1'u8
  identityKindRow = 2'u8
  identityKindColumn = 3'u8
  identityKindImage = 4'u8
  identityKindSvg = 5'u8
  identityKindText = 6'u8
  identityKindGrid = 7'u8
  identityKindTextInput = 8'u8
  logPadStart = 1'u8 shl 0
  logPadEnd = 1'u8 shl 1
  logMarginStart = 1'u8 shl 2
  logMarginEnd = 1'u8 shl 3
  logBorderStart = 1'u8 shl 4
  logBorderEnd = 1'u8 shl 5
  logInsetStart = 1'u8 shl 6
  logInsetEnd = 1'u8 shl 7
  logPad = logPadStart or logPadEnd
  logMargin = logMarginStart or logMarginEnd
  logBorder = logBorderStart or logBorderEnd
  logInset = logInsetStart or logInsetEnd

func startSide(node: ElementNode): int =
  if node.rightToLeft: 1 else: 3

func endSide(node: ElementNode): int = 4 - node.startSide

proc unlog(node: ptr ElementNode; side: int; group: uint8) =
  if node == nil or side notin {1, 3}:
    return
  const starts = logPadStart or logMarginStart or logBorderStart or
    logInsetStart
  if side == node[].startSide:
    node[].logical = node[].logical and not (group and starts)
  else:
    node[].logical = node[].logical and not (group and not starts)

proc swapLogical(node: var ElementNode) =
  if (node.logical and logPad) != 0:
    swap(node.pad[1], node.pad[3])
  if (node.logical and logMargin) != 0:
    swap(node.margin[1], node.margin[3])
  if (node.logical and logBorder) != 0:
    swap(node.border[1], node.border[3])
  if (node.logical and logInset) != 0:
    swap(node.inset[1], node.inset[3])

func clipsChildren(node: ElementNode): bool =
  node.scrollState != nil or node.clipX or node.clipY

proc finiteRegion(value: float32): bool =
  classify(value) notin {fcNan, fcInf, fcNegInf}

proc bitmapSource(node: ElementNode): Rect =
  if node.bitmap == nil or node.bitmap.image == nil or
      node.bitmap.image.w <= 0 or node.bitmap.image.h <= 0:
    return
  let width = float32(node.bitmap.image.w)
  let height = float32(node.bitmap.image.h)
  let source = node.imageRegion
  if source.w <= 0 or source.h <= 0:
    return Rect(w: width, h: height)
  if not source.x.finiteRegion or not source.y.finiteRegion or
      not source.w.finiteRegion or not source.h.finiteRegion:
    return
  let requestedRight = source.x + source.w
  let requestedBottom = source.y + source.h
  if not requestedRight.finiteRegion or not requestedBottom.finiteRegion:
    return
  let left = max(source.x, 0'f32)
  let top = max(source.y, 0'f32)
  let right = min(requestedRight, width)
  let bottom = min(requestedBottom, height)
  if right <= left or bottom <= top:
    return
  Rect(x: left, y: top, w: right - left, h: bottom - top)

var nextHandleIdentity = 0'u64

proc newContext*(): Context =
  ## Creates a stable context. Call close when its owner shuts down.
  new(result)
  new(result.owner)
  result.owner.idSlots = initTable[uint64, int]()
  result.owner.identityParents = initTable[uint64, uint64]()
  result.owner.lastBounds = initTable[uint64, Rect]()
  result.owner.trackedBounds = initHashSet[uint64]()
  result.owner.previousInteraction = initTable[uint64, uint8]()
  result.owner.keyedSeen = initHashSet[string]()
  result.owner.pendingNotices = initTable[uint64, uint8]()
  result.owner.pendingSliderValues = initTable[uint64, float64]()
  result.owner.stepperRepeats = initTable[uint64, StepperRepeat]()
  result.owner.numberInputStates = initTable[uint64, NumberInputState]()
  result.owner.rangeSliderDrags = initTable[uint64, int8]()
  result.owner.pendingTextCallbacks =
    initTable[uint64, seq[proc() {.closure.}]]()
  result.owner.pendingTextSubmitCallbacks =
    initTable[uint64, seq[proc() {.closure.}]]()
  result.owner.textInputClients =
    initTable[uint64, platform.TextInputClient]()
  result.owner.animations =
    initTable[uint64, Table[string, ScalarAnimation]]()
  result.owner.colorMotions =
    initTable[uint64, Table[string, ColorMotion]]()
  result.owner.keyframes =
    initTable[uint64, Table[string, ScalarSequence]]()
  result.accordionHeaders = initTable[uint64, seq[uint64]]()
  result.theme = lightTheme()

proc multiplyWrap(a, b: uint64): uint64 {.inline.} =
  cast[uint64](cast[int64](a) *% cast[int64](b))

proc addWrap(a, b: uint64): uint64 {.inline.} =
  cast[uint64](cast[int64](a) +% cast[int64](b))

proc mixIdentity(a, b: uint64): uint64 {.inline.} =
  var hash = multiplyWrap(a, identityGolden) xor
    addWrap(b, 0x632BE59BD9B4E019'u64)
  hash = multiplyWrap(hash xor (hash shr 30), 0xBF58476D1CE4E5B9'u64)
  hash = multiplyWrap(hash xor (hash shr 27), 0x94D049BB133111EB'u64)
  hash xor (hash shr 31)

proc keyHash(token: string): uint64 =
  result = 14695981039346656037'u64
  for character in token:
    result = multiplyWrap(result xor uint64(ord(character)),
      1099511628211'u64)

proc childIdentity(parent: uint64; child: uint64; kind: uint8): uint64 =
  mixIdentity(parent, multiplyWrap(child, identityGolden) xor uint64(kind))

proc keyedIdentity(parent: uint64; token: string): uint64 =
  mixIdentity(parent, keyHash(token) xor identitySalt)

proc keyToken(value: string): string =
  "s:" & $value.len & ":" & value

proc keyToken[T: SomeInteger](value: T): string =
  "i:" & $value

proc keyScope(parent: uint64; token: string): string =
  $parent & "\0" & token

proc applyPreviousInteraction(owner: ElementOwner; node: var ElementNode) =
  if owner == nil:
    return
  let state = owner.previousInteraction.getOrDefault(node.identity)
  node.hovered = (state and identityHovered) != 0
  node.pressed = (state and identityPressed) != 0
  node.clicked = (state and identityClicked) != 0
  node.focused = (state and identityFocused) != 0
  node.focusVisible = (state and identityFocusVisible) != 0
  let notices = owner.pendingNotices.getOrDefault(node.identity)
  node.changed = (notices and noticeChanged) != 0
  node.submitted = (notices and noticeSubmitted) != 0

proc notifyAction(owner: ElementOwner; identity: uint64; generation: uint32;
                  kind: UiActionKind): bool =
  if owner == nil or owner.closed or owner.generation != generation or
      owner.idSlots.getOrDefault(identity, -1) < 0:
    return false
  let bit = case kind
    of actionChange: noticeChanged
    of actionSubmit: noticeSubmitted
    of actionShortcut: 0'u8
  if bit == 0:
    return false
  let notices = owner.pendingNotices.getOrDefault(identity)
  if (notices and bit) != 0:
    return false
  owner.pendingNotices[identity] = notices or bit
  var callbacks: seq[proc() {.closure.}]
  for action in owner.actions:
    if action.kind == kind and action.identity == identity and
        action.generation == generation and action.action != nil:
      callbacks.add(action.action)
  for callback in callbacks:
    if owner.closed or owner.generation != generation:
      break
    callback()
  true

proc deferTextInputChange(owner: ElementOwner; identity: uint64;
                          generation: uint32) =
  if owner == nil or owner.closed or owner.generation != generation or
      owner.idSlots.getOrDefault(identity, -1) < 0:
    return
  let notices = owner.pendingNotices.getOrDefault(identity)
  if (notices and noticeChanged) != 0:
    return
  owner.pendingNotices[identity] = notices or noticeChanged
  var callbacks: seq[proc() {.closure.}]
  for action in owner.actions:
    if action.kind == actionChange and action.identity == identity and
        action.generation == generation and action.action != nil:
      callbacks.add(action.action)
  if callbacks.len > 0:
    owner.pendingTextCallbacks[identity] = callbacks

proc deferTextInputSubmit(owner: ElementOwner; identity: uint64;
                          generation: uint32) =
  if owner == nil or owner.closed or owner.generation != generation or
      owner.idSlots.getOrDefault(identity, -1) < 0:
    return
  let notices = owner.pendingNotices.getOrDefault(identity)
  if (notices and noticeSubmitted) != 0:
    return
  owner.pendingNotices[identity] = notices or noticeSubmitted
  var callbacks: seq[proc() {.closure.}]
  for action in owner.actions:
    if action.kind == actionSubmit and action.identity == identity and
        action.generation == generation and action.action != nil:
      callbacks.add(action.action)
  if callbacks.len > 0:
    owner.pendingTextSubmitCallbacks[identity] = callbacks

proc assignKey(owner: ElementOwner; node: var ElementNode; parent: uint64;
               token: string) =
  let scope = keyScope(parent, token)
  if node.keyed and node.keyScope != scope:
    owner.keyedSeen.excl(node.keyScope)
  if scope in owner.keyedSeen and
      (not node.keyed or node.keyScope != scope):
    raise newException(ValueError, "ui: duplicate key " & token)
  owner.keyedSeen.incl(scope)
  node.identity = keyedIdentity(parent, token)
  node.keyed = true
  node.keyScope = scope
  owner.applyPreviousInteraction(node)

proc key*(c: Context; value: string): Context =
  ## Gives the next element a stable identity before it reads interaction state.
  result = c
  if c != nil and c.owner != nil and c.owner.inBuild and not c.owner.closed:
    c.pendingKey = keyToken(value)
    c.hasPendingKey = true

proc key*[T: SomeInteger](c: Context; value: T): Context =
  ## Gives the next element a stable integer identity before state is read.
  result = c
  if c != nil and c.owner != nil and c.owner.inBuild and not c.owner.closed:
    c.pendingKey = keyToken(value)
    c.hasPendingKey = true

proc handleBinding(state: HandleState; owner: ElementOwner;
                   create: bool): HandleBinding =
  if state == nil or owner == nil:
    return nil
  for binding in state.bindings:
    if binding.owner == owner:
      return binding
  if create:
    result = HandleBinding(owner: owner, handleIdentity: state.identity)
    state.bindings.add(result)

proc newHandleState(): HandleState =
  if nextHandleIdentity == high(uint64):
    raise newException(ValueError, "ui: Handle identity space exhausted")
  inc nextHandleIdentity
  new(result)
  result.identity = nextHandleIdentity

proc initState(handle: var Handle): HandleState =
  if handle.state == nil:
    handle.state = newHandleState()
  handle.state

proc existingBinding(handle: Handle; owner: ElementOwner): HandleBinding =
  if handle.state != nil:
    result = handle.state.handleBinding(owner, false)

proc removeFocusRequest(owner: ElementOwner; handleIdentity: uint64) =
  if owner == nil or handleIdentity == 0:
    return
  var slot = 0
  while slot < owner.focusRequests.len:
    if owner.focusRequests[slot].handleIdentity == handleIdentity:
      owner.focusRequests.delete(slot)
    else:
      inc slot

proc hasFocusRequest(owner: ElementOwner; handleIdentity,
                     identity: uint64): bool =
  if owner == nil:
    return false
  for request in owner.focusRequests:
    if request.handleIdentity == handleIdentity and
        request.identity == identity:
      return true

proc queueFocusRequest(owner: ElementOwner; binding: HandleBinding) =
  if owner == nil or binding == nil or binding.identity == 0:
    return
  if binding.requestIdentity != 0 and
      binding.requestIdentity != binding.identity:
    owner.removeFocusRequest(binding.handleIdentity)
  var existing = -1
  for slot, request in owner.focusRequests:
    if request.handleIdentity == binding.handleIdentity:
      existing = slot
      break
  let request = HandleFocusRequest(handleIdentity: binding.handleIdentity,
                                   identity: binding.identity)
  if existing >= 0:
    owner.focusRequests[existing] = request
  else:
    owner.focusRequests.add(request)
  binding.requestIdentity = binding.identity
  binding.requested = false

proc newHandle*(): Handle =
  ## Creates a stable reference; the zero-value Handle also works.
  result.state = newHandleState()

proc focus*(handle: var Handle; c: Context = nil) =
  ## Requests focus, waiting for the first binding when none exists yet.
  let state = handle.initState()
  var binding: HandleBinding
  if c != nil:
    if c.owner == nil or c.owner.closed:
      return
    binding = state.handleBinding(c.owner, true)
  else:
    for candidate in state.bindings:
      if candidate.owner == nil or candidate.owner.closed:
        continue
      if binding != nil:
        raise newException(ValueError,
          "ui: Handle.focus needs a Context when bound in multiple windows")
      binding = candidate
  if binding == nil:
    state.pending = true
    return
  binding.requested = true
  binding.owner.queueFocusRequest(binding)
  if binding.owner.invalidate != nil:
    binding.owner.invalidate()

proc requestFocus*(handle: var Handle; c: Context = nil) =
  ## Alias for focus.
  handle.focus(c)

proc cancelFocus*(handle: var Handle; c: Context = nil) =
  ## Cancels a pending request in c, or all requests when c is omitted.
  if handle.state == nil:
    return
  if c == nil:
    handle.state.pending = false
  for binding in handle.state.bindings:
    if c != nil and binding.owner != c.owner:
      continue
    binding.requested = false
    if binding.owner != nil:
      binding.owner.removeFocusRequest(binding.handleIdentity)
    binding.requestIdentity = 0

proc focused*(handle: Handle; c: Context): bool =
  ## Reports whether the bound element owns keyboard focus in c.
  if c == nil or c.owner == nil or c.owner.closed:
    return false
  let binding = handle.existingBinding(c.owner)
  binding != nil and binding.identity != 0 and
    c.owner.focusActive and
    c.owner.focusIdentity == binding.identity

proc focusWithin*(handle: Handle; c: Context): bool =
  ## Reports whether the bound element or a descendant owns keyboard focus.
  if c == nil or c.owner == nil or c.owner.closed:
    return false
  let binding = handle.existingBinding(c.owner)
  if binding == nil or binding.identity == 0:
    return false
  var identity = c.owner.focusIdentity
  var remaining = c.owner.identityParents.len + 1
  while identity != 0 and remaining > 0:
    if identity == binding.identity:
      return true
    identity = c.owner.identityParents.getOrDefault(identity)
    dec remaining

proc focused*(c: Context; handle: Handle): bool =
  ## Reports whether handle owns keyboard focus in c.
  handle.focused(c)

proc focusWithin*(c: Context; handle: Handle): bool =
  ## Reports whether handle or a descendant owns keyboard focus in c.
  handle.focusWithin(c)

proc resolve*(c: Context; handle: Handle): Element =
  ## Resolves handle to its current-pass checked element.
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    return
  let binding = handle.existingBinding(c.owner)
  if binding != nil and binding.generation == c.owner.generation and
      int(binding.slot) < c.owner.nodes.len:
    result = Element(owner: c.owner, slot: binding.slot,
                     generation: binding.generation)

proc theme*(c: Context): Theme =
  ## Returns the theme used by the current frame.
  if c == nil: lightTheme() else: c.theme

proc setTheme*(c: Context; value: Theme) =
  ## Sets the theme for the rest of this frame and fills the root background.
  if c == nil or c.owner == nil or c.owner.closed:
    raise newException(ValueError, "ui: cannot set the theme on a closed context")
  var resolved = value
  if resolved.font.len == 0:
    resolved.font = c.theme.font
  c.theme = resolved
  c.themeEnabled = true
  c.themeBackground = true
  if c.owner.inBuild and c.owner.nodes.len > 0:
    c.owner.nodes[0].background = resolved.background

proc retire(owner: ElementOwner) =
  owner.closed = true
  owner.inBuild = false
  owner.hasFrame = false
  owner.parent = -1
  owner.nodes = @[]
  owner.idSlots.clear()
  owner.identityParents.clear()
  owner.previousInteraction.clear()
  owner.keyedSeen.clear()
  owner.focusRequests = @[]
  owner.actions = @[]
  owner.pendingNotices.clear()
  owner.pendingSliderValues.clear()
  owner.stepperRepeats.clear()
  owner.numberInputStates.clear()
  owner.rangeSliderDrags.clear()
  owner.pendingTextCallbacks.clear()
  owner.pendingTextSubmitCallbacks.clear()
  owner.textInputClients.clear()
  owner.animations.clear()
  owner.colorMotions.clear()
  owner.keyframes.clear()
  owner.committedRects = @[]
  owner.lastBounds.clear()
  owner.trackedBounds.clear()
  owner.focusIdentity = 0
  owner.focusActive = false
  owner.invalidate = nil
  owner.natural = @[]
  owner.rectScratch = @[]
  owner.paintSlots = @[]
  owner.flexSlots = @[]
  owner.flexLines = @[]
  owner.gridScratch = GridScratch()
  owner.flexSizes = @[]
  owner.flexBases = @[]
  owner.flexMin = @[]
  owner.flexMax = @[]
  owner.flexFactors = @[]
  owner.hoveredSlots = @[]
  owner.pressedSlots = @[]
  owner.clickedSlots = @[]
  owner.focusedSlots = @[]
  owner.focusVisibleSlots = @[]

proc node(e: Element): ptr ElementNode =
  if e.owner == nil or e.owner.closed or not e.owner.inBuild or
      e.generation != e.owner.generation or int(e.slot) >= e.owner.nodes.len:
    return nil
  addr e.owner.nodes[int(e.slot)]

proc effectivelyDisabled(owner: ElementOwner; slot: int): bool =
  if owner == nil or slot <= 0 or slot >= owner.nodes.len:
    return false
  var current = slot
  while current > 0 and current < owner.nodes.len:
    if owner.nodes[current].disabled:
      return true
    current = int(owner.nodes[current].parent)

proc valid*(e: Element): bool =
  ## Reports whether e belongs to the active build callback.
  e.node != nil

proc bindHandle*(e: Element; handle: var Handle): Element =
  ## Binds handle to e for this build pass.
  result = e
  let elementNode = e.node
  if elementNode == nil:
    return
  let state = handle.initState()
  let binding = state.handleBinding(e.owner, true)
  if binding.generation == e.generation and binding.slot != e.slot:
    raise newException(ValueError,
      "ui: Handle bound to two elements in one build")
  if binding.requestIdentity != 0:
    let requestPending = e.owner.hasFocusRequest(binding.handleIdentity,
      binding.requestIdentity)
    if binding.requestIdentity != elementNode[].identity:
      if requestPending:
        binding.requested = true
      e.owner.removeFocusRequest(binding.handleIdentity)
      binding.requestIdentity = 0
    elif not requestPending:
      binding.requestIdentity = 0
  binding.slot = e.slot
  binding.generation = e.generation
  binding.identity = elementNode[].identity
  if state.pending:
    binding.requested = true
    state.pending = false
  if binding.requested:
    e.owner.queueFocusRequest(binding)

proc onShortcut*(handle: var Handle; c: Context; mods: platform.Modifiers;
                 key: platform.Key; action: proc() {.closure.}) =
  ## Registers an action for a key pressed while this element or its
  ## descendants have focus. The handle must be bound during this build pass.
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild or
      action == nil:
    return
  c.owner.actions.add(UiAction(handle: handle.initState(),
    kind: actionShortcut, modifiers: mods, key: key, action: action))

proc onShortcut*(c: Context; mods: platform.Modifiers; key: platform.Key;
                 action: proc() {.closure.}) =
  ## Registers a shortcut for the current parent, or the whole window at root.
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild or
      action == nil:
    return
  let slot = int(c.owner.parent)
  if slot < 0 or slot >= c.owner.nodes.len:
    return
  c.owner.actions.add(UiAction(
    identity: c.owner.nodes[slot].identity,
    generation: c.owner.generation, kind: actionShortcut,
    modifiers: mods, key: key,
    action: action))

proc key*(e: Element; value: string): Element =
  ## Keys a container before its children; use Context.key for stateful controls.
  result = e
  let node = e.node
  if node != nil:
    let parentIdentity = if node[].parent >= 0:
        e.owner.nodes[int(node[].parent)].identity
      else:
        rootIdentity
    e.owner.assignKey(node[], parentIdentity, keyToken(value))

proc key*[T: SomeInteger](e: Element; value: T): Element =
  ## Keys a container before its children; use Context.key for stateful controls.
  result = e
  let node = e.node
  if node != nil:
    let parentIdentity = if node[].parent >= 0:
        e.owner.nodes[int(node[].parent)].identity
      else:
        rootIdentity
    e.owner.assignKey(node[], parentIdentity, keyToken(value))

proc newElement(c: Context; row: bool;
                identityKind = identityKindGeneric): Element =
  if c == nil or c.owner.closed or not c.owner.inBuild or c.owner.parent < 0:
    raise newException(ValueError, "ui: element created outside a frame build")
  if int64(c.owner.nodes.len) > int64(high(int32)):
    raise newException(ValueError, "ui: too many elements in one frame")

  let slot = uint32(c.owner.nodes.len)
  let index = int(slot)
  let parentSlot = int(c.owner.parent)
  let parentIdentity = c.owner.nodes[parentSlot].identity
  let childOrdinal = c.owner.nodes[parentSlot].childCount
  inc c.owner.nodes[parentSlot].childCount
  var node = ElementNode(parent: c.owner.parent, firstChild: -1,
                         lastChild: -1, nextSibling: -1,
                         identity: childIdentity(parentIdentity,
                           childOrdinal, identityKind),
                         row: row,
                         rightToLeft:
                           c.owner.nodes[parentSlot].rightToLeft,
                         hovered: index in c.owner.hoveredSlots,
                         pressed: index in c.owner.pressedSlots,
                         clicked: index in c.owner.clickedSlots,
                         focused: index in c.owner.focusedSlots,
                         activateEnter: true,
                         focusVisible: index in c.owner.focusVisibleSlots,
                         focusRingColor: c.theme.focus,
                         textSelectionColor: c.theme.selection,
                         scrollbarColor: c.theme.scrollbar,
                         scrollbarWidth: c.theme.scrollbarWidth,
                         shrink: 1, justify: Align.Start,
                         align: if row: Align.Center else: Align.Auto,
                         selfAlign: Align.Auto,
                         alignContent: Align.Auto,
                         justifyItems: Align.Auto,
                         justifySelf: Align.Auto)
  if c.hasPendingKey:
    c.owner.assignKey(node, parentIdentity, c.pendingKey)
    c.pendingKey.setLen(0)
    c.hasPendingKey = false
  else:
    c.owner.applyPreviousInteraction(node)
  c.owner.nodes.add(node)
  let p = parentSlot
  if c.owner.nodes[p].lastChild >= 0:
    c.owner.nodes[int(c.owner.nodes[p].lastChild)].nextSibling = int32(slot)
  else:
    c.owner.nodes[p].firstChild = int32(slot)
  c.owner.nodes[p].lastChild = int32(slot)
  result = Element(owner: c.owner, slot: slot,
                   generation: c.owner.generation)

proc box*(c: Context): Element =
  ## Adds a box container to the current parent.
  c.newElement(false, identityKindBox)

proc row*(c: Context): Element =
  ## Adds a row container to the current parent.
  c.newElement(true, identityKindRow)

proc column*(c: Context): Element =
  ## Adds a column container to the current parent.
  c.newElement(false, identityKindColumn)

proc newBitmap*(source: sourceImage.Image): Bitmap =
  ## Converts an image.Image to a reusable premultiplied scene bitmap.
  if source != nil:
    result = Bitmap(image: scene.newSceneImage(source))

proc update*(bitmap: Bitmap; source: sourceImage.Image) =
  ## Replaces a bitmap's pixels while retaining its scene-image identity.
  if bitmap == nil or source == nil:
    return
  let bounds = source.bounds()
  let width = bounds.dx
  let height = bounds.dy
  var rgba = sourceImage.RgbaImage(pix: newSeq[uint8](4 * width * height),
    stride: 4 * width, rect: sourceImage.rect(0, 0, width, height))
  sourceImage.drawSrc(rgba, sourceImage.rect(0, 0, width, height), source,
                      bounds.min)
  if bitmap.image == nil:
    bitmap.image = scene.newImageRgba(width, height, rgba.pix)
  else:
    bitmap.image.w = width
    bitmap.image.h = height
    bitmap.image.pix = rgba.pix
    bitmap.image.changed()

proc size*(bitmap: Bitmap): tuple[width, height: int] =
  ## Reports a bitmap's intrinsic size in pixels.
  if bitmap != nil and bitmap.image != nil:
    result = (bitmap.image.w, bitmap.image.h)

proc pixelated*(bitmap: Bitmap): Bitmap =
  ## Uses nearest-neighbor sampling when the bitmap is enlarged.
  result = bitmap
  if result != nil:
    result.pixelated = true

proc parseSvg*(data: openArray[byte] | string):
    tuple[svg: Svg, error: string] =
  ## Parses an SVG document once for reuse by image elements.
  let (doc, error) = svgRenderer.parse(data)
  if error.len > 0:
    return (nil, error)
  let (width, height) = svgRenderer.size(doc)
  (Svg(doc: doc, width: float32(width), height: float32(height)), "")

proc size*(vector: Svg): tuple[width, height: float32] =
  ## Reports an SVG's intrinsic size in DIPs.
  if vector != nil:
    result = (vector.width, vector.height)

proc image*(c: Context; bitmap: Bitmap): Element =
  ## Adds a bitmap element with its natural pixel size in DIPs.
  result = c.newElement(false, identityKindImage)
  let n = result.node
  if n != nil:
    n.bitmap = bitmap
    n.fit = Fit.Contain

proc imageRegion*(c: Context; bitmap: Bitmap; source: Rect;
                  flipX = false; flipY = false): Element =
  ## Adds an image element showing source pixels from a bitmap. An empty
  ## source rectangle shows the whole bitmap; an out-of-bounds rectangle
  ## is clipped to the bitmap. flipX and flipY mirror that region.
  result = c.image(bitmap)
  let n = result.node
  if n != nil:
    n.imageRegion = source
    n.flipX = flipX
    n.flipY = flipY

proc svg*(c: Context; vector: Svg): Element =
  ## Adds an SVG element with its intrinsic size in DIPs.
  result = c.newElement(false, identityKindSvg)
  let n = result.node
  if n != nil:
    n.vector = vector
    n.vectorColor = rgb(0, 0, 0)
    n.fit = Fit.Contain

proc text*(c: Context; value: string): Element =
  ## Adds a text element using the system UI font at its natural size.
  result = c.newElement(false, identityKindText)
  let n = result.node
  if n != nil:
    n.hasText = true
    n.textValue = value
    n.textColor = if c.themeEnabled: c.theme.text else: rgb(0, 0, 0)
    if c.themeEnabled:
      if c.theme.font.len > 0:
        n.textStyle.family = c.theme.font
      n.textStyle.size = c.theme.fontSize

proc children*(e: Element; build: proc() {.closure.}): Element =
  ## Builds children with e as their parent for the duration of build.
  result = e
  if e.node == nil or build == nil:
    return
  let owner = e.owner
  let previous = owner.parent
  owner.parent = int32(e.slot)
  try:
    build()
  finally:
    owner.parent = previous

proc buildTooltips(c: Context)

proc build*(c: Context; view: proc(c: Context) {.closure.}) =
  ## Runs one view build pass. Elements made in view expire when it returns.
  if c == nil or c.owner.closed:
    raise newException(ValueError, "ui: cannot build with a closed context")
  if c.owner.inBuild:
    raise newException(ValueError, "ui: nested frame build")
  if c.owner.generation == high(uint32):
    c.owner.retire()
    new(c.owner)
    c.owner.idSlots = initTable[uint64, int]()
    c.owner.identityParents = initTable[uint64, uint64]()
    c.owner.lastBounds = initTable[uint64, Rect]()
    c.owner.trackedBounds = initHashSet[uint64]()
    c.owner.previousInteraction = initTable[uint64, uint8]()
    c.owner.keyedSeen = initHashSet[string]()
    c.owner.pendingNotices = initTable[uint64, uint8]()
    c.owner.pendingSliderValues = initTable[uint64, float64]()
    c.owner.stepperRepeats = initTable[uint64, StepperRepeat]()
    c.owner.numberInputStates = initTable[uint64, NumberInputState]()
    c.owner.rangeSliderDrags = initTable[uint64, int8]()
    c.owner.pendingTextCallbacks =
      initTable[uint64, seq[proc() {.closure.}]]()
    c.owner.pendingTextSubmitCallbacks =
      initTable[uint64, seq[proc() {.closure.}]]()
    c.owner.textInputClients =
      initTable[uint64, platform.TextInputClient]()
    c.owner.animations =
      initTable[uint64, Table[string, ScalarAnimation]]()
    c.owner.colorMotions =
      initTable[uint64, Table[string, ColorMotion]]()
    c.owner.keyframes =
      initTable[uint64, Table[string, ScalarSequence]]()
    c.accordion = nil
    c.accordionHeaders.clear()
  inc c.owner.generation
  c.owner.frameNow = getMonoTime()
  c.owner.animating = false
  c.owner.actions.setLen(0)
  c.owner.nodes.setLen(0)
  c.owner.idSlots.clear()
  c.owner.committedRects.setLen(0)
  c.owner.keyedSeen.clear()
  c.owner.paintSlots.setLen(0)
  c.owner.nodes.add(ElementNode(parent: -1, firstChild: -1,
                                lastChild: -1, nextSibling: -1,
                                identity: rootIdentity,
                                rightToLeft: c.rightToLeft,
                                background: if c.themeBackground:
                                    c.theme.background
                                  else:
                                    transparent,
                                shrink: 1, justify: Align.Start,
                                align: Align.Auto, selfAlign: Align.Auto))
  c.owner.parent = 0
  c.owner.inBuild = true
  c.owner.activeContext = c
  c.owner.reduceMotion = c.reduceMotion
  c.owner.hasFrame = false
  var built = false
  try:
    if view != nil:
      view(c)
    c.buildTooltips()
    for index in 0..<c.owner.actions.len:
      if c.owner.actions[index].kind == actionShortcut and
          c.owner.actions[index].handle != nil:
        let binding = c.owner.actions[index].handle.handleBinding(
          c.owner, false)
        if binding != nil and binding.generation == c.owner.generation:
          c.owner.actions[index].identity = binding.identity
          c.owner.actions[index].generation = binding.generation
        c.owner.actions[index].handle = nil
    for slot, node in c.owner.nodes:
      c.owner.idSlots[node.identity] = slot
    c.owner.identityParents.clear()
    for node in c.owner.nodes:
      if node.parent >= 0:
        c.owner.identityParents[node.identity] =
          c.owner.nodes[int(node.parent)].identity
    var staleBounds: seq[uint64]
    for identity in c.owner.trackedBounds:
      if not c.owner.idSlots.hasKey(identity):
        staleBounds.add(identity)
    for identity in staleBounds:
      c.owner.trackedBounds.excl(identity)
      c.owner.lastBounds.del(identity)
    var staleAccordions: seq[uint64]
    for identity in c.accordionHeaders.keys:
      if not c.owner.idSlots.hasKey(identity):
        staleAccordions.add(identity)
    for identity in staleAccordions:
      c.accordionHeaders.del(identity)
    var staleAnimations: seq[uint64]
    for identity in c.owner.animations.keys:
      if not c.owner.idSlots.hasKey(identity):
        staleAnimations.add(identity)
    for identity in staleAnimations:
      c.owner.animations.del(identity)
    var staleColorMotions: seq[uint64]
    for identity in c.owner.colorMotions.keys:
      if not c.owner.idSlots.hasKey(identity):
        staleColorMotions.add(identity)
    for identity in staleColorMotions:
      c.owner.colorMotions.del(identity)
    var staleKeyframes: seq[uint64]
    for identity in c.owner.keyframes.keys:
      if not c.owner.idSlots.hasKey(identity):
        staleKeyframes.add(identity)
    for identity in staleKeyframes:
      c.owner.keyframes.del(identity)
    var staleStepperRepeats: seq[uint64]
    for identity in c.owner.stepperRepeats.keys:
      let slot = c.owner.idSlots.getOrDefault(identity, -1)
      if slot <= 0 or slot >= c.owner.nodes.len or
          not c.owner.nodes[slot].stepper:
        staleStepperRepeats.add(identity)
    for identity in staleStepperRepeats:
      c.owner.stepperRepeats.del(identity)
    var staleRangeSliderDrags: seq[uint64]
    for identity in c.owner.rangeSliderDrags.keys:
      let slot = c.owner.idSlots.getOrDefault(identity, -1)
      if slot <= 0 or slot >= c.owner.nodes.len or
          not c.owner.nodes[slot].rangeSlider:
        staleRangeSliderDrags.add(identity)
    for identity in staleRangeSliderDrags:
      c.owner.rangeSliderDrags.del(identity)
    var staleNumberInputs: seq[uint64]
    for identity in c.owner.numberInputStates.keys:
      let slot = c.owner.idSlots.getOrDefault(identity, -1)
      if slot <= 0 or slot >= c.owner.nodes.len or
          not c.owner.nodes[slot].numberInput:
        staleNumberInputs.add(identity)
    for identity in staleNumberInputs:
      c.owner.numberInputStates.del(identity)
    built = true
  finally:
    c.owner.inBuild = false
    c.owner.activeContext = nil
    c.owner.parent = -1
    c.owner.hasFrame = built
    if not built:
      c.owner.actions.setLen(0)
    c.owner.pendingNotices.clear()
    c.owner.pendingTextCallbacks.clear()
    c.owner.pendingTextSubmitCallbacks.clear()
    if built:
      c.owner.pendingSliderValues.clear()
    c.hasPendingKey = false
    c.pendingKey.setLen(0)
    c.owner.previousInteraction.clear()
    c.owner.keyedSeen.clear()
    c.owner.hoveredSlots.setLen(0)
    c.owner.pressedSlots.setLen(0)
    c.owner.clickedSlots.setLen(0)
    c.themeBackground = false

proc close*(c: Context) =
  ## Detaches saved handles and releases frame storage when the context closes.
  if c == nil or c.owner.closed:
    return
  c.owner.actions.setLen(0)
  c.accordion = nil
  c.accordionHeaders.clear()
  c.owner.retire()
