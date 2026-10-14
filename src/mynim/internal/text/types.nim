## Shared types of internal/text (layout.go, caret.go, edit.go,
## raster.go, decoration.go, engine.go).

type
  Style* = object
    ## Selects the font of a text.
    family*: string ## comma-separated families; "" is the system UI font
    size*: float32  ## in DIPs; 0 is 14
    weight*: int    ## 100 (thin) to 900 (black); 0 is 400
    italic*: bool
    lineHeight*: float32 ## multiple of size; 0 is the font's own spacing
    letterSpacing*: float32 ## DIPs added after every character
    features*: string ## OpenType features, comma separated
    lang*: string ## BCP 47 tag; "" is the System's language

  Align* = uint8

  Params* = object
    ## Describe a text to lay out.
    text*: string
    style*: Style
    width*: float32 ## wraps lines; 0 or less only breaks at newlines
    maxLines*: int ## truncates, ending with ellipsis ("…" when empty)
    ellipsis*: string
    noWrap*: bool ## breaks lines only at newlines
    align*: Align
    rtl*: bool ## makes neutral paragraphs right-to-left
    keepSpaces*: bool ## keeps the advance of whitespace at line ends
    noBreakWords*: bool ## only breaks lines between words
    spans*: string ## styles runs of the text, as encodeSpans writes

  Span* = object
    ## Styles the runes of a text before `end`, after the spans before
    ## it. What it sets replaces the Style of the layout.
    `end`*: int
    family*: string
    size*: float32
    weight*: int
    italic*: bool
    letterSpacing*: float32
    features*: string
    lang*: string
    ## objectWidth/objectHeight, when objectWidth is set, make each rune
    ## of the span (U+FFFC) an inline object: a box that wide, standing
    ## that high on the baseline, which draws no glyph.
    objectWidth*, objectHeight*: float32

  Glyph* = object
    ## A positioned glyph.
    font*: Font
    id*: uint32
    size*: float32 ## the font size in DIPs
    ## x is the glyph's drawing origin including shaping offsets, y its
    ## baseline; advance moves the pen independently of the offsets.
    x*, y*: float32
    advance*: float32
    ## cluster is the first rune of the glyph's cluster, runes how many
    ## the cluster holds; glyphs of the ellipsis have runes 0.
    cluster*, runes*: int
    rtl*: bool
    ## object marks the box of an inline object (Span.objectWidth),
    ## which draws no glyph: what shows there is the caller's.
    `object`*: bool

  Line* = object
    ## A line of a Layout.
    x*, y*, width*, height*: float32
    ## baseline is the y of the baseline; ascent and descent the extent
    ## of the fonts above and below it.
    baseline*, ascent*, descent*: float32
    ## start and end are the line's runes; a newline ending it is not
    ## included.
    start*, `end`*: int
    rtl*: bool ## a right-to-left paragraph
    glyphs*: seq[Glyph]
    carets: seq[float32]
    stops: seq[caretStop]
    upstream: seq[float32]

  Layout* = ref object
    ## Shaped and wrapped text. Positions are in DIPs from the top-left.
    params*: Params
    runes*: seq[Rune]
    lines*: seq[Line]
    ## width is the longest line's; height the sum of the line heights.
    width*, height*: float32
    boundaries: seq[int] ## retained whole-grapheme offsets
    truncated*: bool ## maxLines cut the text

  Rect* = object
    ## A rectangle in DIPs relative to the layout.
    x*, y*, w*, h*: float32

  Affinity* = uint8
  CaretPosition* = object
    index*: int
    affinity*: Affinity
  Range* = object
    start*, `end`*: int

  caretStop = object
    position: CaretPosition
    x: float32
    arrival: int

  Shade* = uint8

  GlyphImage* = object
    ## A rasterized glyph in an atlas.
    ok*: bool ## false for glyphs without pixels, such as spaces
    colored*, subpixel*: bool ## in the color atlas
    thin*: bool ## of a font too thin for antialiasing
    x*, y*, w*, h*: uint16 ## the bitmap's rectangle in its atlas
    ## left and top place the bitmap relative to the glyph's origin on
    ## the baseline, in pixels; top is usually negative.
    left*, top*: float32

  Decoration* = uint8
  Stroke* = object
    x0*, x1*, top*, bottom*: float32

  decoRange* = object
    ## What an engine decorates: glyphs [i, j) of a line of a layout
    ## whose origin is at (x, y) DIPs, runes of one style whose font is
    ## font, at scale pixels per DIP, with decoration d.
    l*: Layout
    line*: ptr Line
    i*, j*: int
    font*: Font
    x*, y*: float32
    scale*: float32
    d*: Decoration

  Font* = ref object
    ## A font of the system, or of the app, at a size. Layouts and
    ## glyphs refer to fonts by reference.
    size*: float32 ## the em size in DIPs
    ascent*, descent*, lineGap*: float32 ## vertical metrics in DIPs
    native*: uint ## the engine's font
    ## shaded fonts' glyphs differ by the shade of the text; thin ones
    ## are too thin for antialiasing; engines draw thickens' thicker for
    ## Thick.
    shaded*, thin*, thickens*: bool
    ## The tops of the font's underline and strikethrough, in DIPs above
    ## the baseline, and their thickness, for engines that decorate with
    ## them (DirectWrite and Pango).
    underlineTop*, underlineThick*, strikeTop*, strikeThick*: float32

  feature = object
    ## An OpenType feature of Style.features: its tag and value.
    tag: array[4, byte]
    value: uint32

  shapedLine = object
    ## A line of a paragraph as an engine laid it out: the runes of the
    ## paragraph it holds, whitespace ending it included.
    start, `end`: int
    runs: seq[shapedRun]

  shapedRun = object
    ## A run of glyphs of one font and direction.
    font: Font
    start, `end`: int ## the runes of the paragraph the run holds
    ## glyphs are positioned relative to the start of the line's pen, Y
    ## down from the baseline, with Cluster the paragraph's rune that
    ## starts the glyph's cluster; Runes is set later.
    glyphs: seq[Glyph]

  bitmap* = object
    ## A rasterized glyph.
    left*, top*, w*, h*: int ## box in pixels relative to the origin
    ## pix holds a byte of coverage per pixel, or for color glyphs four
    ## bytes of premultiplied RGBA, or for subpixel ones the coverage of
    ## the red, green and blue subpixels and a fourth byte.
    pix*: seq[byte]
    color*, subpixel*: bool

  langRun = object
    ## A run of runes of a text in one language as the engine is told.
    start, `end`: int
    lang: string

  glyphKey = object
    font: Font
    id: uint32
    scale: uint32 ## pixels per DIP, in 1/256
    subX: uint8 ## the position within a pixel, of placement.n
    shade: Shade
    subpixel: bool

  placement = object
    n: int
    round: bool

  placeKey = object
    font: Font
    scale: uint32
    subpixel: bool

  runKey = object
    font: Font
    key: string

  markKey = object
    style: Style
    mark: string ## Params.ellipsis
    rtl: bool

  atlasEntry = ref object
    img: GlyphImage
    used: uint64 ## the last frame that drew it

  lineMetrics = object
    ascent, descent, lineHeight: float32

  cached = ref object
    layout: Layout
    used: uint64
    bytes: int
    prev, next: cached

const
  Start* = Align(0)
  Center* = Align(1)
  End* = Align(2)
  Left* = Align(3)
  Right* = Align(4)

  Downstream* = Affinity(0)
  Upstream* = Affinity(1)

  Underline* = Decoration(0)
  Strikethrough* = Decoration(1)

  Shades* = 4
  Thick* = Shade(Shades)
  Flat* = Shade(Shades + 1)

## Affinity chooses the preceding or following logical text at a boundary.
## The two edges can occupy different positions in bidi text or at a wrap.

proc hash*(f: Font): Hash = hash(cast[uint](f))

proc hash(s: Style): Hash =
  var h = hash(s.family) !& hash(s.weight) !& hash(s.italic) !&
    hash(s.features) !& hash(s.lang)
  h = h !& hash(s.size) !& hash(s.lineHeight) !& hash(s.letterSpacing)
  !$h

proc hash(p: Params): Hash =
  var h = hash(p.text) !& hash(p.style) !& hash(p.ellipsis) !&
    hash(p.maxLines) !& hash(p.noWrap) !& hash(p.align) !&
    hash(p.rtl) !& hash(p.keepSpaces) !& hash(p.noBreakWords) !& hash(p.spans)
  h = h !& hash(p.width)
  !$h

proc hash(k: glyphKey): Hash =
  hash(cast[uint](k.font)) !& hash(k.id) !& hash(k.scale) !&
    hash(k.subX) !& hash(k.shade) !& hash(k.subpixel)

proc hash(k: placeKey): Hash =
  hash(cast[uint](k.font)) !& hash(k.scale) !& hash(k.subpixel)

proc hash(k: runKey): Hash =
  hash(cast[uint](k.font)) !& hash(k.key)

proc hash(k: markKey): Hash =
  hash(k.style) !& hash(k.mark) !& hash(k.rtl)

proc `==`(a, b: glyphKey): bool =
  cast[uint](a.font) == cast[uint](b.font) and a.id == b.id and
    a.scale == b.scale and a.subX == b.subX and a.shade == b.shade and
    a.subpixel == b.subpixel

proc `==`(a, b: placeKey): bool =
  cast[uint](a.font) == cast[uint](b.font) and a.scale == b.scale and
    a.subpixel == b.subpixel

proc `==`(a, b: runKey): bool =
  cast[uint](a.font) == cast[uint](b.font) and a.key == b.key

proc `==`(a, b: markKey): bool =
  a.style == b.style and a.mark == b.mark and a.rtl == b.rtl

proc inColor*(g: GlyphImage): bool = g.colored or g.subpixel
