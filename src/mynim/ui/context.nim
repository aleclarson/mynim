## Frame scope and checked handles for elements in the current UI pass.

type
  Context* = ref ContextObj ## Stable context for one window's UI builds.

  ContextObj = object
    owner: ElementOwner

  ElementOwner = ref object
    nodes: seq[ElementNode]
    natural: seq[NaturalSize]
    rectScratch: seq[Rect]
    flexSizes, flexBases, flexMin, flexMax, flexFactors: seq[float32]
    hoveredSlots, pressedSlots, clickedSlots: seq[int]
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

  ElementNode = object
    parent, firstChild, lastChild, nextSibling: int32
    row, reverse: bool
    hasText: bool
    hovered, pressed, clicked: bool
    label: string
    textValue: string
    textStyle: textStack.Style
    textColor: Color
    shapedText: textStack.Layout
    clickHandler: proc() {.closure.}
    bitmap: Bitmap
    vector: Svg
    vectorColor: Color
    grayscale: bool
    fit: Fit
    width, height, minW, minH, maxW, maxH, basis: UiLength
    aspectRatio: float32
    grow, shrink: float32
    pad, margin: array[4, float32]
    gapX, gapY: float32
    justify, align, selfAlign: Align
    background, borderColor: Color
    radius, border: array[4, float32]
    borderStyle: BorderStyle

  LayoutResult* = object
    ## Snapshot bounds calculated from a completed build.
    root*: Rect
    owner: ElementOwner
    generation: uint32
    rects: seq[Rect]

proc newContext*(): Context =
  ## Creates a stable context. Call close when its owner shuts down.
  new(result)
  new(result.owner)

proc retire(owner: ElementOwner) =
  owner.closed = true
  owner.inBuild = false
  owner.hasFrame = false
  owner.parent = -1
  owner.nodes = @[]
  owner.natural = @[]
  owner.rectScratch = @[]
  owner.flexSizes = @[]
  owner.flexBases = @[]
  owner.flexMin = @[]
  owner.flexMax = @[]
  owner.flexFactors = @[]
  owner.hoveredSlots = @[]
  owner.pressedSlots = @[]
  owner.clickedSlots = @[]

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
                         hovered: index in c.owner.hoveredSlots,
                         pressed: index in c.owner.pressedSlots,
                         clicked: index in c.owner.clickedSlots,
                         shrink: 1, justify: Align.Start,
                         align: if row: Align.Center else: Align.Auto,
                         selfAlign: Align.Auto)
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
    n.textColor = rgb(0, 0, 0)

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
  c.owner.nodes.add(ElementNode(parent: -1, firstChild: -1,
                                lastChild: -1, nextSibling: -1,
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

proc close*(c: Context) =
  ## Detaches saved handles and releases frame storage when the context closes.
  if c == nil or c.owner.closed:
    return
  c.owner.retire()
