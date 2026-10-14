## compile.go: compiling the document's elements into nodes.

## node is a drawing compiled from an element: a shape, or a group of
## nodes. m maps its user space to its parent's. clipDef is a
## clipPath: the union of its shapes clips. maskDef is a mask: the
## luminance, or alpha, of its content masks, within its region.
## Doc is a parsed SVG document. Draw may draw it from any thread.
type
  node = ref object
    m: matrix
    opacity: float64
    clip: clipDef
    mask: maskDef
    shape: ref shape
    kids: seq[node]
    ## bbox is the box around its geometry in its user space, for what
    ## is in objectBoundingBox units.
    bbox: box
    hasBox: bool
    ## single is true when the node paints one thing at most, so that
    ## its opacity can apply to it instead of to a layer; flat is true
    ## when its parent's opacity can apply to it instead.
    single, flat: bool
  paint = object
    kind: uint8
    color: rgba
    grad: ref gradient
  shape = object
    path: path
    fill, stroke: paint
    fillOpacity: float64
    strokeOpacity: float64
    evenOdd: bool
    width, miter: float64
    cap, join: uint8
    dashes: seq[float64]
    dashOffset: float64
    strokeFirst: bool
  stop = object
    offset: float64
    color: rgba
    current: bool ## the color the document is drawn with
    opacity: float64
  gradient = object
    radial: bool
    bbox: bool   ## in objectBoundingBox units
    m: matrix    ## gradientTransform
    spread: uint8
    ## The line of a linear gradient, the circles of a radial one.
    x1, y1, x2, y2: float64
    cx, cy, r, fx, fy, fr: float64
    stops: seq[stop]
  clipDef = ref object
    bbox: bool   ## clipPathUnits is objectBoundingBox
    m: matrix    ## its transform
    kids: seq[node]
    clip: clipDef ## its own clip-path
  maskDef = ref object
    units, content: bool ## maskUnits and maskContentUnits are objectBoundingBox
    region: box
    alpha: bool
    kids: seq[node]
  Doc* = ref object
    root: node
    view: box
    par: aspect
    w, h: float64
    ## current is true when something is painted with currentColor.
    current: bool
  compiler = object
    root: elem
    ids: Table[string, elem]
    styles: Table[elem, ref style]
    grads: Table[elem, ref gradient]
    clips: Table[elem, clipDef]
    masks: Table[elem, maskDef]
    ## `using` holds the elements being drawn by use elements, which
    ## may not use themselves.
    `using`: seq[elem]
    ## budget is how many more nodes the document may compile to.
    budget: int
    ## vw and vh are the size of the viewport, for percentages.
    vw, vh: float64
    base: style
    ## current is set once a paint is currentColor.
    current: bool

## Kinds of paint.
const
  paintNone = 0'u8
  paintColor = 1'u8
  paintCurrent = 2'u8 ## the color the document is drawn with
  paintGradient = 3'u8

## Spread methods.
const
  spreadPad = 0'u8
  spreadReflect = 1'u8
  spreadRepeat = 2'u8

proc hash(e: elem): Hash = hash(cast[uint](e))

proc newCompiler(root: elem): compiler =
  var c = compiler(
    root: root, budget: 1 shl 17, base: initialStyle())
  c.ids = initTable[string, elem]()
  c.styles = initTable[elem, ref style]()
  c.grads = initTable[elem, ref gradient]()
  c.clips = initTable[elem, clipDef]()
  c.masks = initTable[elem, maskDef]()
  walk(root, proc(e: elem) =
    let id = e.attrs.getOrDefault("id")
    if id != "" and not c.ids.hasKey(id):
      c.ids[id] = e)
  c

proc diag(c: compiler): float64 = sqrt((c.vw * c.vw + c.vh * c.vh) / 2)

## length parses the attribute name of e as a length, with def when it
## is missing or in error, percentages of base.
proc length(c: compiler; e: elem; name: string; base, def: float64): float64 =
  if e.attrs.hasKey(name):
    let (l, ok) = parseLength(e.attrs[name], base)
    if ok:
      return l
  def

proc styleOf(c: var compiler; e: elem; parent: ptr style): style =
  computeStyle(e, parent, c.vw, c.vh)

## domStyle returns the style of e where the document has it: for the
## content of gradients, clip paths and masks, which inherit from
## where they are, not from what they paint.
proc domStyle(c: var compiler; e: elem): ptr style =
  if c.styles.hasKey(e):
    return addr c.styles[e][]
  var parent: ptr style = addr c.base
  if not e.parent.isNil:
    parent = c.domStyle(e.parent)
  let s = new(style)
  s[] = c.styleOf(e, parent)
  c.styles[e] = s
  addr s[]

## absLength parses an absolute length, ignoring percentages.
proc absLength(v: string): tuple[l: float64, ok: bool] =
  if v.strip().endsWith("%"):
    return (0, false)
  parseLength(v, 0)

proc finish(c: var compiler; n: node; st: ptr style)
proc group(c: var compiler; n: node; e: elem; st: ptr style)
proc element(c: var compiler; e: elem; parent: ptr style): node
proc viewport(c: var compiler; e: elem; st: ptr style;
              x, y, w, h: float64): seq[node]
proc `use`(c: var compiler; n: node; e: elem; st: ptr style): bool
proc shapePath(c: compiler; e: elem): path
proc painted(c: var compiler; ps: paintSpec; st: ptr style): paint
proc gradientDef(c: var compiler; e: elem): ref gradient
proc stops(c: var compiler; e: elem): seq[stop]
proc clipRef(c: var compiler; id: string): clipDef
proc clipKid(c: var compiler; k: elem; parent: ptr style;
             depth: int): node
proc maskRef(c: var compiler; id: string): maskDef
proc radii(c: compiler; e: elem; vw, vh: float64): tuple[rx, ry: float64]
proc hrefID(e: elem): string

## group compiles the children of e into n.

## doc compiles the document.
proc doc(c: var compiler): Doc =
  let root = c.root
  let (vb0, hasVB) = parseViewBox(root.attrs.getOrDefault("viewBox"))
  var vb = vb0
  let (w0, wok) = absLength(root.attrs.getOrDefault("width"))
  let (h0, hok) = absLength(root.attrs.getOrDefault("height"))
  var w = w0
  var h = h0
  if wok and hok:
    discard
  elif hasVB and wok:
    h = w * vb.h / vb.w
  elif hasVB and hok:
    w = h * vb.w / vb.h
  elif hasVB:
    w = vb.w
    h = vb.h
  else:
    if not wok: w = 300
    if not hok: h = 150
  if not hasVB:
    vb = box(x: 0, y: 0, w: w, h: h)
  c.vw = vb.w
  c.vh = vb.h
  let d = Doc(view: vb,
              par: parseAspect(root.attrs.getOrDefault("preserveAspectRatio")),
              w: max(w, 0), h: max(h, 0))
  var st = c.styleOf(root, addr c.base)
  if not st.display:
    return d
  let n = node(m: identity)
  c.group(n, root, addr st)
  c.finish(n, addr st)
  d.root = n
  d.current = c.current
  d

## elem compiles a graphics element, or returns nil for others.
proc element(c: var compiler; e: elem; parent: ptr style): node =
  case e.name
  of "g", "a", "switch", "svg", "use", "path", "rect", "circle",
     "ellipse", "line", "polyline", "polygon":
    discard
  else:
    return nil
  if c.budget <= 0:
    return nil
  dec c.budget
  var st = c.styleOf(e, parent)
  if not st.display:
    return nil
  let n = node(m: identity)
  case e.name
  of "g", "a":
    c.group(n, e, addr st)
  of "switch":
    ## The first child whose conditions hold, of which only
    ## requiredExtensions fails: MyGo supports no extension.
    for k in e.kids:
      if k.attrs.getOrDefault("requiredExtensions") != "" or
          k.name == "title" or k.name == "desc" or k.name == "metadata":
        continue
      let kn = c.element(k, addr st)
      if not kn.isNil:
        n.kids.add(kn)
      break
  of "svg":
    let
      x = c.length(e, "x", c.vw, 0)
      y = c.length(e, "y", c.vh, 0)
      w = c.length(e, "width", c.vw, c.vw)
      h = c.length(e, "height", c.vh, c.vh)
    if w <= 0 or h <= 0:
      return nil
    n.kids = c.viewport(e, addr st, x, y, w, h)
  of "use":
    if not c.`use`(n, e, addr st):
      return nil
  else:
    if not st.visible:
      return nil
    let pa = c.shapePath(e)
    if pa.ops.len == 0:
      return nil
    n.shape = (ref shape)(
      path: pa,
      fill: c.painted(st.fill, addr st),
      stroke: c.painted(st.stroke, addr st),
      fillOpacity: st.fillOpacity,
      strokeOpacity: st.strokeOpacity,
      evenOdd: st.fillEvenOdd,
      width: st.strokeWidth,
      miter: st.miterLimit,
      cap: st.cap,
      join: st.join,
      dashes: st.dashes,
      dashOffset: st.dashOffset,
      strokeFirst: st.strokeFirst)
  if n.shape.isNil and n.kids.len == 0:
    return nil
  if e.attrs.hasKey("transform"):
    n.m = parseTransform(e.attrs["transform"]).mul(n.m)
  c.finish(n, addr st)
  n

proc group(c: var compiler; n: node; e: elem; st: ptr style) =
  for k in e.kids:
    let kn = c.element(k, st)
    if not kn.isNil:
      n.kids.add(kn)

## finish gives a node its opacity, clipping and masking, and works
## out its box and whether it is single and flat.
proc finish(c: var compiler; n: node; st: ptr style) =
  n.opacity = st.opacity
  n.clip = c.clipRef(st.clipPath)
  n.mask = c.maskRef(st.mask)
  if not n.shape.isNil:
    (n.bbox, n.hasBox) = n.shape.path.bounds()
    n.single = n.shape.fill.kind == paintNone or
      n.shape.stroke.kind == paintNone
  else:
    for k in n.kids:
      if not k.hasBox:
        continue
      var b = k.bbox.transform(k.m)
      if n.hasBox:
        b = n.bbox.union(b)
      n.bbox = b
      n.hasBox = true
    n.single = n.kids.len == 0 or
      (n.kids.len == 1 and n.kids[0].flat)
  n.flat = not n.clip.isNil or not n.mask.isNil or n.single

## viewport compiles the children of an svg or symbol element e drawn
## in a viewport w×h at (x, y), which clips them.
proc viewport(c: var compiler; e: elem; st: ptr style;
              x, y, w, h: float64): seq[node] =
  let
    vw = c.vw
    vh = c.vh
  defer:
    c.vw = vw
    c.vh = vh
  let inner = node(m: identity)
  let (vb, hasVB) = parseViewBox(e.attrs.getOrDefault("viewBox"))
  if hasVB:
    inner.m = viewBoxTransform(vb,
      parseAspect(e.attrs.getOrDefault("preserveAspectRatio")), w, h)
    c.vw = vb.w
    c.vh = vb.h
  else:
    c.vw = w
    c.vh = h
  c.group(inner, e, st)
  if inner.kids.len == 0:
    return @[]
  c.finish(inner, addr c.base)
  var r: path
  r.rect(0, 0, w, h, 0, 0)
  let clipped = node(m: translate(x, y),
                     kids: @[inner])
  var cs = c.base
  c.finish(clipped, addr cs)
  clipped.clip = clipDef(m: identity,
      kids: @[node(m: identity, shape: (ref shape)(path: r))])
  clipped.flat = true
  @[clipped]

## `use` compiles the element a use element e draws into n.
proc `use`(c: var compiler; n: node; e: elem; st: ptr style): bool =
  let `ref` = c.ids.getOrDefault(hrefID(e))
  if `ref`.isNil or `ref` in c.`using`:
    return false
  var p = e
  while not p.isNil:
    if p == `ref`:
      return false ## it would draw itself
    p = p.parent
  c.`using`.add(`ref`)
  defer:
    c.`using`.setLen(c.`using`.len - 1)
  let
    x = c.length(e, "x", c.vw, 0)
    y = c.length(e, "y", c.vh, 0)
  if `ref`.name == "symbol":
    var sst = c.styleOf(`ref`, st)
    if not sst.display:
      return false
    let
      w = c.length(e, "width", c.vw, c.vw)
      h = c.length(e, "height", c.vh, c.vh)
    if w <= 0 or h <= 0:
      return false
    n.kids = c.viewport(`ref`, addr sst, x, y, w, h)
    return n.kids.len > 0
  let kid = c.element(`ref`, st)
  if kid.isNil:
    return false
  n.m = translate(x, y)
  n.kids = @[kid]
  true

proc hrefID(e: elem): string =
  let v = e.attrs.getOrDefault("href").strip()
  if not v.startsWith("#"):
    return ""
  v[1 ..< v.len]

proc isShape(name: string): bool =
  case name
  of "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
    true
  else:
    false

## radii returns the rx and ry of a rect or ellipse: one that is
## missing, or in error, is the other.
proc radii(c: compiler; e: elem; vw, vh: float64): tuple[rx, ry: float64] =
  let (rx0, okX0) = parseLength(e.attrs.getOrDefault("rx"), vw)
  let (ry0, okY0) = parseLength(e.attrs.getOrDefault("ry"), vh)
  var
    rx = rx0
    ry = ry0
    okX = okX0 and rx >= 0
    okY = okY0 and ry >= 0
  if okX and not okY:
    ry = rx
  elif okY and not okX:
    rx = ry
  elif not okX and not okY:
    rx = 0
    ry = 0
  (rx, ry)

## shapePath returns the path of a shape element.
proc shapePath(c: compiler; e: elem): path =
  var pa: path
  let
    vw = c.vw
    vh = c.vh
    diag = c.diag()
  case e.name
  of "path":
    pa = parsePath(e.attrs.getOrDefault("d"))
  of "rect":
    let
      x = c.length(e, "x", vw, 0)
      y = c.length(e, "y", vh, 0)
      w = c.length(e, "width", vw, 0)
      h = c.length(e, "height", vh, 0)
    if w <= 0 or h <= 0:
      return pa
    let (rx, ry) = c.radii(e, vw, vh)
    pa.rect(x, y, w, h, min(rx, w / 2), min(ry, h / 2))
  of "circle":
    let r = c.length(e, "r", diag, 0)
    if r > 0:
      pa.ellipse(c.length(e, "cx", vw, 0), c.length(e, "cy", vh, 0), r, r)
  of "ellipse":
    let (rx, ry) = c.radii(e, vw, vh)
    if rx > 0 and ry > 0:
      pa.ellipse(c.length(e, "cx", vw, 0), c.length(e, "cy", vh, 0),
                 rx, ry)
  of "line":
    pa.moveTo(point(x: c.length(e, "x1", vw, 0),
                    y: c.length(e, "y1", vh, 0)))
    pa.lineTo(point(x: c.length(e, "x2", vw, 0),
                    y: c.length(e, "y2", vh, 0)))
  of "polyline", "polygon":
    let n = numbers(e.attrs.getOrDefault("points"))
    var i = 0
    while i + 1 < n.len:
      if i == 0:
        pa.moveTo(point(x: n[i], y: n[i + 1]))
      else:
        pa.lineTo(point(x: n[i], y: n[i + 1]))
      i += 2
    if e.name == "polygon":
      pa.close()
  else:
    discard
  pa

## paint resolves a fill or stroke of an element of style st.
proc painted(c: var compiler; ps: paintSpec; st: ptr style): paint =
  case ps.kind
  of specColor:
    return paint(kind: paintColor, color: ps.color)
  of specCurrent:
    if st.colorSet:
      return paint(kind: paintColor, color: st.color)
    c.current = true
    return paint(kind: paintCurrent)
  of specURL:
    let el = c.ids.getOrDefault(ps.id)
    if not el.isNil and
        (el.name == "linearGradient" or el.name == "radialGradient"):
      let g = c.gradientDef(el)
      if g.isNil or g.stops.len == 0:
        return paint(kind: paintNone)
      return paint(kind: paintGradient, grad: g)
    ## What the reference falls back to, or nothing.
    return c.painted(paintSpec(kind: ps.fallback, color: ps.color), st)
  else:
    paint(kind: paintNone)

## gradient compiles a gradient element, with what it inherits from
## the gradients it refers to.
proc gradientDef(c: var compiler; e: elem): ref gradient =
  if c.grads.hasKey(e):
    return c.grads[e]
  c.grads[e] = nil
  var chain = @[e]
  var cur = e
  while chain.len < 32:
    let `ref` = c.ids.getOrDefault(hrefID(cur))
    if `ref`.isNil or
        (`ref`.name != "linearGradient" and `ref`.name != "radialGradient") or
        `ref` in chain:
      break
    chain.add(`ref`)
    cur = `ref`
  let g = new(gradient)
  g.radial = e.name == "radialGradient"
  g.bbox = true
  g.m = identity
  ## attr finds an attribute along the chain; the coordinates come
  ## from gradients of the same kind only.
  proc attr(name: string; own: bool): tuple[v: string, ok: bool] =
    for el in chain:
      if own and el.name != e.name:
        continue
      if el.attrs.hasKey(name):
        return (el.attrs[name], true)
    ("", false)
  block:
    let (v, ok) = attr("gradientUnits", false)
    if ok:
      g.bbox = v.strip() != "userSpaceOnUse"
  block:
    let (v, ok) = attr("gradientTransform", false)
    if ok:
      g.m = parseTransform(v)
  block:
    let (v, ok) = attr("spreadMethod", false)
    if ok:
      case v.strip()
      of "reflect": g.spread = spreadReflect
      of "repeat": g.spread = spreadRepeat
      else: discard
  proc coord(name, def: string; base: float64): float64 =
    var (v, ok) = attr(name, true)
    if not ok:
      v = def
    var base = base
    if g.bbox:
      base = 1
    let (l, ok2) = parseLength(v, base)
    if ok2:
      return l
    let (l2, _) = parseLength(def, base)
    l2
  let diag = c.diag()
  if g.radial:
    g.cx = coord("cx", "50%", c.vw)
    g.cy = coord("cy", "50%", c.vh)
    g.r = coord("r", "50%", diag)
    g.fx = g.cx
    g.fy = g.cy
    if attr("fx", true).ok:
      g.fx = coord("fx", "50%", c.vw)
    if attr("fy", true).ok:
      g.fy = coord("fy", "50%", c.vh)
    g.fr = coord("fr", "0%", diag)
    ## SVG 1.1 moves a focal point outside the circle onto it.
    let d = hypot(g.fx - g.cx, g.fy - g.cy)
    if d > g.r * 0.999 and d > 0:
      let k = g.r * 0.999 / d
      g.fx = g.cx + (g.fx - g.cx) * k
      g.fy = g.cy + (g.fy - g.cy) * k
  else:
    g.x1 = coord("x1", "0%", c.vw)
    g.y1 = coord("y1", "0%", c.vh)
    g.x2 = coord("x2", "100%", c.vw)
    g.y2 = coord("y2", "0%", c.vh)
  ## The stops of the first gradient along the chain that has some.
  for el in chain:
    g.stops = c.stops(el)
    if g.stops.len > 0:
      break
  c.grads[e] = g
  g

proc stops(c: var compiler; e: elem): seq[stop] =
  var `out`: seq[stop]
  var last = 0.0
  for k in e.kids:
    if k.name != "stop":
      continue
    let st = c.domStyle(k)
    var off = 0.0
    if k.attrs.hasKey("offset"):
      off = parseOpacity(k.attrs["offset"].strip(), 0)
    off = max(off, last)
    last = off
    var s = stop(offset: off, color: st.stopColor.color,
                 opacity: st.stopOpacity)
    if st.stopColor.kind == specCurrent:
      if st.colorSet:
        s.color = st.color
      else:
        s.current = true
        c.current = true
    `out`.add(s)
  `out`

## clipRef compiles the clipPath an element refers to, if it is one.
proc clipRef(c: var compiler; id: string): clipDef =
  let el = c.ids.getOrDefault(id)
  if id == "" or el.isNil or el.name != "clipPath":
    return nil
  if c.clips.hasKey(el):
    return c.clips[el] ## nil while it is being compiled: it clips itself
  c.clips[el] = nil
  let cd = clipDef(
    m: parseTransform(el.attrs.getOrDefault("transform")),
    bbox: el.attrs.getOrDefault("clipPathUnits").strip() == "objectBoundingBox")
  let st = c.domStyle(el)
  for k in el.kids:
    let n = c.clipKid(k, st, 0)
    if not n.isNil:
      cd.kids.add(n)
  cd.clip = c.clipRef(st.clipPath)
  c.clips[el] = cd
  cd

## clipKid compiles a child of a clipPath: a shape, or a use of one.
## Only their geometry clips, filled with the clip-rule.
proc clipKid(c: var compiler; k: elem; parent: ptr style;
             depth: int): node =
  if c.budget <= 0 or depth > 1:
    return nil
  dec c.budget
  var st = c.styleOf(k, parent)
  if not st.display or not st.visible:
    return nil
  let n = node(m: parseTransform(k.attrs.getOrDefault("transform")))
  if k.name == "use":
    let `ref` = c.ids.getOrDefault(hrefID(k))
    if `ref`.isNil or not isShape(`ref`.name):
      return nil
    let kid = c.clipKid(`ref`, addr st, depth + 1)
    if kid.isNil:
      return nil
    n.m = n.m.mul(translate(c.length(k, "x", c.vw, 0),
                            c.length(k, "y", c.vh, 0)))
    n.kids = @[kid]
  elif isShape(k.name):
    let pa = c.shapePath(k)
    if pa.ops.len == 0:
      return nil
    n.shape = (ref shape)(path: pa, evenOdd: st.clipEvenOdd)
  else:
    return nil
  n

## maskRef compiles the mask an element refers to, if it is one.
proc maskRef(c: var compiler; id: string): maskDef =
  let el = c.ids.getOrDefault(id)
  if id == "" or el.isNil or el.name != "mask":
    return nil
  if c.masks.hasKey(el):
    return c.masks[el]
  c.masks[el] = nil
  let md = maskDef(
    units: el.attrs.getOrDefault("maskUnits").strip() != "userSpaceOnUse",
    content: el.attrs.getOrDefault("maskContentUnits").strip() == "objectBoundingBox")
  var
    bw = c.vw
    bh = c.vh
  if md.units:
    bw = 1
    bh = 1
  md.region = box(
    x: c.length(el, "x", bw, -0.1 * bw),
    y: c.length(el, "y", bh, -0.1 * bh),
    w: c.length(el, "width", bw, 1.2 * bw),
    h: c.length(el, "height", bh, 1.2 * bh))
  let st = c.domStyle(el)
  md.alpha = st.maskAlpha
  for k in el.kids:
    let n = c.element(k, st)
    if not n.isNil:
      md.kids.add(n)
  c.masks[el] = md
  md
