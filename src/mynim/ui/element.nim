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

  ScrollState* = ref object ## Persistent offset for one scroll container.
    offsetX, offsetY: float32
    maxX, maxY: float32
    scrollbarDragging: bool

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

func offset*(state: ScrollState): tuple[x, y: float32] =
  ## Returns the current horizontal and vertical offsets in DIPs.
  if state == nil: return
  (x: state.offsetX, y: state.offsetY)

func maxOffset*(state: ScrollState): tuple[x, y: float32] =
  ## Returns the greatest horizontal and vertical offsets in DIPs.
  if state == nil: return
  (x: state.maxX, y: state.maxY)

proc scrollTo*(state: ScrollState; x, y: float32) =
  ## Sets the requested offsets; layout clamps them to the content range.
  if state == nil:
    raise newException(ValueError, "ui: scroll state cannot be nil")
  if classify(x) in {fcNan, fcInf, fcNegInf} or
      classify(y) in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "ui: scroll offsets must be finite")
  state.offsetX = max(x, 0'f32)
  state.offsetY = max(y, 0'f32)
