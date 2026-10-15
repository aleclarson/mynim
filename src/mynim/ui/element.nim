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

const
  Auto* = Inf.float32 ## Automatic length, used by margins.

proc contains*(r: Rect; x, y: float32): bool =
  ## Reports whether the point is inside r, including its top and left edges.
  x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h
