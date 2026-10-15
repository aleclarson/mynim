## Frame scope and checked handles for elements in the current UI pass.

type
  Context* = ref ContextObj ## Stable context for one window's UI builds.

  ContextObj = object
    owner: ElementOwner
    theme: Theme
    rightToLeft: bool
    themeEnabled, themeBackground: bool

  ElementOwner = ref object
    nodes: seq[ElementNode]
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
    inBuild: bool
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
    row, reverse, wrap, wrapReverse, grid, absolute, alignSet,
      justifySet, focusable, focused, focusVisible, focusRingDisabled,
      scrollX, scrollY,
      revealInScroll, rightToLeft, directionSet: bool
    logical: uint8
    clipX, clipY, hasFollowScroll: bool
    followScrollSlot: int32
    gridCol, gridRow, gridColSpan, gridRowSpan: int
    hasText, textColorSet, listRowSelected, listRowFocusVisible,
      listRowHeader, listRowPinnedHeader: bool
    textAlign: Align
    hovered, pressed, clicked: bool
    label: string
    textValue: string
    textStyle: textStack.Style
    textColor: Color
    shapedText: textStack.Layout
    textClient: platform.TextInputClient
    clickHandler: proc(mods: platform.Modifiers) {.closure.}
    accessRole: platform.AccessRole
    accessSort: platform.AccessStates
    accessRoleSet: bool
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

proc newContext*(): Context =
  ## Creates a stable context. Call close when its owner shuts down.
  new(result)
  new(result.owner)
  result.theme = lightTheme()

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

proc valid*(e: Element): bool =
  ## Reports whether e belongs to the active build callback.
  e.node != nil

proc newElement(c: Context; row: bool): Element =
  if c == nil or c.owner.closed or not c.owner.inBuild or c.owner.parent < 0:
    raise newException(ValueError, "ui: element created outside a frame build")
  if int64(c.owner.nodes.len) > int64(high(int32)):
    raise newException(ValueError, "ui: too many elements in one frame")

  let slot = uint32(c.owner.nodes.len)
  let index = int(slot)
  let node = ElementNode(parent: c.owner.parent, firstChild: -1,
                         lastChild: -1, nextSibling: -1, row: row,
                         rightToLeft:
                           c.owner.nodes[int(c.owner.parent)].rightToLeft,
                         hovered: index in c.owner.hoveredSlots,
                         pressed: index in c.owner.pressedSlots,
                         clicked: index in c.owner.clickedSlots,
                         focused: index in c.owner.focusedSlots,
                         focusVisible: index in c.owner.focusVisibleSlots,
                         focusRingColor: c.theme.focus,
                         scrollbarColor: c.theme.scrollbar,
                         scrollbarWidth: c.theme.scrollbarWidth,
                         shrink: 1, justify: Align.Start,
                         align: if row: Align.Center else: Align.Auto,
                         selfAlign: Align.Auto,
                         alignContent: Align.Auto,
                         justifyItems: Align.Auto,
                         justifySelf: Align.Auto)
  c.owner.nodes.add(node)
  let p = int(c.owner.parent)
  if c.owner.nodes[p].lastChild >= 0:
    c.owner.nodes[int(c.owner.nodes[p].lastChild)].nextSibling = int32(slot)
  else:
    c.owner.nodes[p].firstChild = int32(slot)
  c.owner.nodes[p].lastChild = int32(slot)
  result = Element(owner: c.owner, slot: slot,
                   generation: c.owner.generation)

proc box*(c: Context): Element =
  ## Adds a box container to the current parent.
  c.newElement(false)

proc row*(c: Context): Element =
  ## Adds a row container to the current parent.
  c.newElement(true)

proc column*(c: Context): Element =
  ## Adds a column container to the current parent.
  c.newElement(false)

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
  result = c.newElement(false)
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
  result = c.newElement(false)
  let n = result.node
  if n != nil:
    n.vector = vector
    n.vectorColor = rgb(0, 0, 0)
    n.fit = Fit.Contain

proc text*(c: Context; value: string): Element =
  ## Adds a text element using the system UI font at its natural size.
  result = c.newElement(false)
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

proc build*(c: Context; view: proc(c: Context) {.closure.}) =
  ## Runs one view build pass. Elements made in view expire when it returns.
  if c == nil or c.owner.closed:
    raise newException(ValueError, "ui: cannot build with a closed context")
  if c.owner.inBuild:
    raise newException(ValueError, "ui: nested frame build")
  if c.owner.generation == high(uint32):
    c.owner.retire()
    new(c.owner)
  inc c.owner.generation
  c.owner.nodes.setLen(0)
  c.owner.paintSlots.setLen(0)
  c.owner.nodes.add(ElementNode(parent: -1, firstChild: -1,
                                lastChild: -1, nextSibling: -1,
                                rightToLeft: c.rightToLeft,
                                background: if c.themeBackground:
                                    c.theme.background
                                  else:
                                    transparent,
                                shrink: 1, justify: Align.Start,
                                align: Align.Auto, selfAlign: Align.Auto))
  c.owner.parent = 0
  c.owner.inBuild = true
  c.owner.hasFrame = false
  var built = false
  try:
    if view != nil:
      view(c)
    built = true
  finally:
    c.owner.inBuild = false
    c.owner.parent = -1
    c.owner.hasFrame = built
    c.owner.hoveredSlots.setLen(0)
    c.owner.pressedSlots.setLen(0)
    c.owner.clickedSlots.setLen(0)
    c.themeBackground = false

proc close*(c: Context) =
  ## Detaches saved handles and releases frame storage when the context closes.
  if c == nil or c.owner.closed:
    return
  c.owner.retire()
