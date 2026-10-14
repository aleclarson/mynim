## platform/flyout.go — flyout placement: a borderless window owned by its
## parent and placed next to a rectangle of it.

type
  Flyout* = ref object
    ## Makes a window a flyout (WindowOptions.flyout): a borderless
    ## window owned by its parent and placed next to a rectangle of it,
    ## which may extend beyond the parent but stays in the work area of
    ## a display.
    ## anchor is the rectangle the flyout is placed against, in DIPs
    ## relative to the parent's content area.
    anchor*: Rect
    ## tray anchors the flyout to a tray icon, where it shows without a
    ## parent, above the windows of other apps.
    tray*: Tray
    ## side is where the flyout goes from anchor, and align how it lines
    ## up with it along that side.
    side*: Side
    align*: Align
    ## gap is the distance between anchor and the flyout, in DIPs.
    gap*: int
    ## focusable makes the flyout take the keyboard as it shows, and
    ## close (WindowHandler.shouldClose) when the user presses outside
    ## it or another window takes the keyboard.
    focusable*: bool
    ## popover shows the flyout in a popover of the system, which draws
    ## its background and an arrow pointing at the middle of anchor
    ## (macOS); align and gap do not apply. Elsewhere it is ignored.
    popover*: bool

  Side* = enum
    ## The side of the anchor a flyout goes to.
    sideBottom
    sideTop
    sideRight
    sideLeft

  Align* = enum
    ## Lines a flyout up with its anchor along the side it goes to.
    alignStart
    alignCenter
    alignEnd

  Gravity* = object
    ## One of the nine points of a rectangle: its corners, the middles of
    ## its edges and its center, as GdkGravity and Wayland's
    ## xdg_positioner anchors and gravities name them.
    ## x and y are -1 for the left or top, 0 for the middle, 1 for the
    ## right or bottom.
    x*, y*: int

proc gravities*(f: Flyout): tuple[anchor, window: Gravity, dx, dy: int] =
  ## The point of the anchor the flyout is placed at, the point of the
  ## flyout that goes there, and the offset between them.
  let cross = int(f.align) - 1 # alignStart..alignEnd: -1, 0, 1
  case f.side
  of sideTop:
    (Gravity(x: cross, y: -1), Gravity(x: cross, y: 1), 0, -f.gap)
  of sideRight:
    (Gravity(x: 1, y: cross), Gravity(x: -1, y: cross), f.gap, 0)
  of sideLeft:
    (Gravity(x: -1, y: cross), Gravity(x: 1, y: cross), -f.gap, 0)
  else:
    (Gravity(x: cross, y: 1), Gravity(x: cross, y: -1), 0, f.gap)

proc flipPosition(boundsPos, boundsSize, rectPos, rectSize, size, rectSign,
                  windowSign, offset: int): tuple[pos: int, flipped: bool] =
  ## GDK's maybe_flip_position on one axis.
  let primary = rectPos + (1 + rectSign) * rectSize div 2 + offset -
    (1 + windowSign) * size div 2
  template fits(p: int): bool = p >= boundsPos and p + size <= boundsPos + boundsSize
  if fits(primary): return (primary, false)
  let secondary = rectPos + (1 - rectSign) * rectSize div 2 - offset -
    (1 - windowSign) * size div 2
  if fits(secondary): return (secondary, true)
  (primary, false)

proc slideAndResize(boundsPos, boundsSize, pos, size: int): tuple[pos, size: int] =
  ## Moves a span back into bounds, its start first when it is longer,
  ## then cuts what still sticks out.
  var pos = pos
  var size = size
  if pos + size > boundsPos + boundsSize:
    pos = boundsPos + boundsSize - size
  if pos < boundsPos:
    pos = boundsPos
  if pos + size > boundsPos + boundsSize:
    size = boundsPos + boundsSize - pos
  (pos, max(size, 1))

proc place*(f: Flyout, anchor: Rect, size: Size, work: Rect):
    tuple[r: Rect, flippedX, flippedY: bool] =
  ## Where a flyout of the given size goes, its anchor being at anchor on
  ## the screen, in the work area of the display that work returns for
  ## anchor. Resolves the placement as GTK places popups on X11 and
  ## Wayland compositors do (xdg_positioner): on each axis the flyout
  ## flips to the other side of the anchor, or to the other end of it,
  ## where it would not fit and the flipped one would; then it slides
  ## along the edge it would cross, back into the work area; then it
  ## shrinks to it.
  let (ra, wa, dx, dy) = f.gravities()
  var r = Rect(width: size.width, height: size.height)
  (r.x, result.flippedX) = flipPosition(work.x, work.width, anchor.x, anchor.width,
                                        r.width, ra.x, wa.x, dx)
  (r.y, result.flippedY) = flipPosition(work.y, work.height, anchor.y, anchor.height,
                                        r.height, ra.y, wa.y, dy)
  (r.x, r.width) = slideAndResize(work.x, work.width, r.x, r.width)
  (r.y, r.height) = slideAndResize(work.y, work.height, r.y, r.height)
  result.r = r

proc overlap(a, b: Rect): int =
  let w = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
  let h = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
  if w <= 0 or h <= 0: 0 else: w * h

proc workAreaFor*(r: Rect, displays: seq[Display]): Rect =
  ## The work area of the display a flyout anchored at r goes to, as GDK
  ## picks it: the one whose work area overlaps r the most, else the one
  ## nearest to r's center.
  var best = -1
  var bestArea = 0
  for i, d in displays:
    let a = overlap(d.workArea, r)
    if a > bestArea:
      best = i; bestArea = a
  if best < 0:
    let cx = r.x + r.width div 2
    let cy = r.y + r.height div 2
    var bestDist = -1
    for i, d in displays:
      let b = d.bounds
      let dx = max(max(b.x - cx, 0), cx - (b.x + b.width - 1))
      let dy = max(max(b.y - cy, 0), cy - (b.y + b.height - 1))
      let dist = dx * dx + dy * dy
      if bestDist < 0 or dist < bestDist:
        best = i; bestDist = dist
  if best < 0: return Rect()
  displays[best].workArea

proc centered*(size: Size, work: Rect): Rect =
  ## Where a flyout of the given size goes without an anchor: in the
  ## middle of the work area, as large as it fits.
  var r = Rect(width: min(size.width, work.width),
               height: min(size.height, work.height))
  r.x = work.x + (work.width - r.width) div 2
  r.y = work.y + (work.height - r.height) div 2
  r

proc primaryWorkArea*(displays: seq[Display]): Rect =
  ## The work area of the primary display.
  for d in displays:
    if d.primary: return d.workArea
  if displays.len > 0: return displays[0].workArea
  Rect()
