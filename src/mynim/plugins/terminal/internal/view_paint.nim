## Paints owned Ghostty terminal frames through Mynim's native UI painter.

import std/[math, options, strutils, tables, unicode]
import mynim/ui as ui
import ./vt/[frame, render, terminal]

type
  TerminalPaintOptions* = object
    fontFamily*: string
    fontFeatures*: string
    preedit*: string
    preeditCaret*: int
    fontSize*: float32
    fontWeight*: int
    lineHeight*: float32
    paddingX*, paddingY*: float32
    transparent*: bool
    focused*, cursorBlinkOn*: bool
    selection*, selectionText*: ui.Color
    cursor*, cursorText*: ui.Color

  TerminalGrid* = object
    cols*, rows*: int
    cellWidth*, cellHeight*: float32
    cellWidthPixels*, cellHeightPixels*: int
    textOffsetY*: float32
    baselineOffset*: float32

  ShapeKey = tuple[text, family, features, lang: string, size: float32,
    weight: int, italic, thicken, antialiased: bool]

  TerminalPaintCache* = ref object
    ## UI-thread cache of shaped terminal runs, bounded to recent content.
    shapes: Table[ShapeKey, seq[ui.Glyph]]
    order: seq[ShapeKey]

  TerminalScrollbarGeometry* = object
    track*, thumb*: ui.Rect
    maxOffset*: uint64

  PaintedCell = object
    foreground, background, underlineColor: ui.Color
    hasBackground, invisible: bool
    bold, italic, strike, overline: bool
    underline: int

  TextStyle = object
    foreground: ui.Color
    bold, italic: bool

  PaintedGlyphRun = object
    glyphs: seq[ui.Glyph]
    columns: seq[int]
    foreground: ui.Color

  DecorationSpan = object
    first, past: int
    kind: int
    color: ui.Color

const printableAscii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

proc defaultTerminalPaintOptions*(fontSize = 13'f32): TerminalPaintOptions =
  ## Returns the default monospace terminal text options.
  TerminalPaintOptions(
    fontFamily: "monospace",
    fontFeatures: "",
    fontSize: fontSize,
    fontWeight: 400,
    lineHeight: 1,
    paddingX: 6,
    paddingY: 4,
    focused: true,
    cursorBlinkOn: true)

proc newTerminalPaintCache*(): TerminalPaintCache =
  ## Creates a bounded shape cache for one terminal view.
  TerminalPaintCache(shapes: initTable[ShapeKey, seq[ui.Glyph]]())

proc shape(cache: TerminalPaintCache; text: string;
           font: ui.Font): seq[ui.Glyph] =
  if cache == nil:
    return ui.shape(text, font)
  let key: ShapeKey = (text, font.family, font.features, font.lang, font.size,
    font.weight, font.italic, font.thicken, font.antialiased)
  if cache.shapes.hasKey(key):
    return cache.shapes[key]
  result = ui.shape(text, font)
  const maxCachedShapes = 512
  if cache.order.len >= maxCachedShapes:
    cache.shapes.del(cache.order[0])
    cache.order.delete(0)
  cache.shapes[key] = result
  cache.order.add(key)

proc uiColor(value: RGB): ui.Color = ui.rgb(value.r, value.g, value.b)

proc finite(value: float32): bool =
  classify(value) notin {fcNan, fcInf, fcNegInf}

proc normalized(options: TerminalPaintOptions): TerminalPaintOptions =
  result = options
  result.fontFamily = strutils.strip(options.fontFamily)
  if result.fontFamily.len == 0:
    result.fontFamily = "monospace"
  if not result.fontSize.finite or result.fontSize <= 0:
    result.fontSize = 13
  if result.fontWeight <= 0:
    result.fontWeight = 400
  else:
    result.fontWeight = min(max(result.fontWeight, 100), 900)
  if not result.lineHeight.finite or result.lineHeight <= 0:
    result.lineHeight = 1
  if not result.paddingX.finite or result.paddingX < 0:
    result.paddingX = 0
  if not result.paddingY.finite or result.paddingY < 0:
    result.paddingY = 0

proc resolveColor(value: RenderColor; fallback: ui.Color;
                   colors: RenderColors): ui.Color =
  case value.kind
  of renderColorNone: fallback
  of renderColorPalette: uiColor(colors.palette[value.paletteIndex])
  of renderColorRgb: uiColor(value.rgb)

proc paintCell(cell: TerminalFrameCell; colors: RenderColors): PaintedCell =
  let defaultForeground = uiColor(colors.foreground)
  let defaultBackground = uiColor(colors.background)
  let style = cell.style
  result.foreground = resolveColor(style.foreground, defaultForeground, colors)
  result.background = resolveColor(style.background, defaultBackground, colors)
  result.hasBackground = style.background.kind != renderColorNone
  result.underlineColor = resolveColor(style.underlineColor,
    result.foreground, colors)
  if style.inverse:
    let foreground = result.foreground
    result.foreground = if result.hasBackground:
        result.background else: defaultBackground
    result.background = foreground
    result.hasBackground = true
  if cell.cell.hasBackground:
    result.background = if cell.cell.paletteBackground:
        uiColor(colors.palette[cell.cell.background.r])
      else: uiColor(cell.cell.background)
    result.hasBackground = true
  if style.faint:
    result.foreground = result.foreground.alpha(0.5'f32)
  result.invisible = style.invisible
  result.bold = style.bold
  result.italic = style.italic
  result.strike = style.strikethrough
  result.overline = style.overline
  result.underline = style.underline

proc grid*(painter: var ui.Painter; bounds: ui.Rect;
    options: TerminalPaintOptions; cache: TerminalPaintCache = nil): TerminalGrid =
  ## Measures the fixed-width cell grid that fits in an element's bounds.
  let options = options.normalized()
  let fontFamily = options.fontFamily
  let fontSize = options.fontSize
  let fontWeight = options.fontWeight
  let features = options.fontFeatures
  let font = ui.Font(family: fontFamily, features: features,
    size: fontSize, weight: fontWeight)
  let fontMetrics = font.metrics()
  let naturalHeight = fontMetrics.ascent + fontMetrics.descent +
    fontMetrics.lineGap
  var maxAdvance = 0'f32
  for glyph in cache.shape(printableAscii, font):
    maxAdvance = max(maxAdvance, glyph.advance)
  let lineHeight = if options.lineHeight > 0: options.lineHeight else: 1'f32
  let scale = max(painter.scale(), 0.01'f32)
  result.cellWidthPixels = max(1, int(ceil(float64(maxAdvance * scale -
    0.05'f32))))
  result.cellHeightPixels = max(1, int(ceil(float64(naturalHeight *
    lineHeight * scale - 0.05'f32))))
  result.cellWidth = float32(result.cellWidthPixels) / scale
  result.cellHeight = float32(result.cellHeightPixels) / scale
  result.textOffsetY = max((result.cellHeight - naturalHeight) / 2, 0'f32)
  result.baselineOffset = float32(round((float32(result.cellHeightPixels) -
    (fontMetrics.ascent + fontMetrics.descent) * scale) / 2 +
    fontMetrics.ascent * scale)) / scale
  let paddingX = max(0, int(round(max(options.paddingX, 0'f32) * scale)))
  let paddingY = max(0, int(round(max(options.paddingY, 0'f32) * scale)))
  let width = max(0, int(round(max(bounds.w, 0'f32) * scale)) - 2 * paddingX)
  let height = max(0, int(round(max(bounds.h, 0'f32) * scale)) - 2 * paddingY)
  result.cols = max(1, width div result.cellWidthPixels)
  result.rows = max(1, height div result.cellHeightPixels)

proc scrollbarGeometry*(bounds: ui.Rect; scrollbar: TerminalScrollbar;
    width, paddingX, paddingY: float32; minimumThumb = 18'f32):
    TerminalScrollbarGeometry =
  ## Computes a terminal scrollbar thumb from Ghostty's viewport counts.
  if scrollbar.total <= scrollbar.len or scrollbar.len == 0:
    return
  let requestedWidth = if width.finite and width > 0: width else: 6'f32
  let horizontalPadding = if paddingX.finite: max(paddingX, 0'f32) else: 0'f32
  let verticalPadding = if paddingY.finite: max(paddingY, 0'f32) else: 0'f32
  let barWidth = min(requestedWidth, max(bounds.w, 0'f32))
  let trackHeight = max(bounds.h - 2 * verticalPadding, 0'f32)
  if barWidth <= 0 or trackHeight <= 0:
    return
  result.maxOffset = scrollbar.total - scrollbar.len
  result.track = ui.Rect(x: bounds.x + bounds.w - horizontalPadding -
      barWidth, y: bounds.y + verticalPadding, w: barWidth, h: trackHeight)
  let proportional = trackHeight *
    (float64(scrollbar.len) / float64(scrollbar.total)).float32
  let thumbMinimum = if minimumThumb.finite:
      max(minimumThumb, 0'f32) else: 18'f32
  let thumbHeight = min(trackHeight, max(thumbMinimum, proportional))
  let travel = max(trackHeight - thumbHeight, 0'f32)
  let offset = min(scrollbar.offset, result.maxOffset)
  let fromTop =
    (float64(offset) / float64(result.maxOffset)).float32
  result.thumb = ui.Rect(x: result.track.x,
    y: result.track.y + travel * fromTop,
    w: barWidth, h: thumbHeight)

proc scrollbarOffsetAt*(geometry: TerminalScrollbarGeometry; y,
                        grabOffset: float32): uint64 =
  ## Maps a pointer position on the track to Ghostty's scrollback offset.
  if geometry.maxOffset == 0:
    return 0
  let travel = max(geometry.track.h - geometry.thumb.h, 0'f32)
  if travel == 0:
    return 0
  let grab = min(max(grabOffset, 0'f32), geometry.thumb.h)
  let thumbTop = min(max(y - grab, geometry.track.y),
    geometry.track.y + travel)
  let fractionFromTop = (thumbTop - geometry.track.y) / travel
  let offset = float64(geometry.maxOffset) * float64(fractionFromTop)
  uint64(max(0'f64, min(offset, float64(geometry.maxOffset))).round())

proc paintScrollbar*(painter: var ui.Painter; bounds: ui.Rect;
    scrollbar: TerminalScrollbar; color: ui.Color; width, paddingX,
    paddingY: float32) =
  ## Paints the scrollback thumb over the right edge of the terminal view.
  let geometry = scrollbarGeometry(bounds, scrollbar, width, paddingX,
    paddingY)
  if geometry.thumb.w > 0 and geometry.thumb.h > 0:
    painter.fill(geometry.thumb, color, geometry.thumb.w / 2)

proc cellText(cell: TerminalFrameCell; style: PaintedCell): string =
  if cell.cell.wide in {cellSpacerTail, cellSpacerHead}:
    return
  if style.invisible:
    result = if cell.cell.wide == cellWide: "  " else: " "
    return
  for codepoint in cell.codepoints:
    if codepoint == 0 or codepoint > 0x10FFFF or
        codepoint in 0xD800'u32 .. 0xDFFF'u32:
      continue
    result.add(toUTF8(Rune(codepoint)))
  if result.len == 0:
    result = " "

proc onlySpaces(value: string): bool =
  if value.len == 0:
    return false
  for rune in value.runes:
    if rune != Rune(0x20):
      return false
  true

proc shapedRun(cache: TerminalPaintCache; text: string;
    columns, widths: openArray[int]; color: ui.Color; bold, italic: bool;
    cellWidth, scale: float32; options: TerminalPaintOptions): PaintedGlyphRun =
  if text.len == 0 or columns.len == 0:
    return
  let font = ui.Font(family: options.fontFamily,
    features: options.fontFeatures, size: options.fontSize,
    weight: if bold: min(max(options.fontWeight + 300, 700), 900)
      else: options.fontWeight,
    italic: italic)
  let shaped = cache.shape(text, font)
  result.foreground = color
  var i = 0
  while i < shaped.len:
    let firstRune = max(0, min(shaped[i].cluster, columns.high))
    let col = columns[firstRune]
    var lastRune = firstRune
    var j = i
    var x0 = shaped[i].x
    var x1 = shaped[i].x + shaped[i].advance
    while true:
      let glyph = shaped[j]
      let glyphEnd = min(glyph.cluster + max(glyph.runes, 1), columns.len)
      lastRune = max(lastRune, glyphEnd - 1)
      x0 = min(x0, glyph.x)
      x1 = max(x1, glyph.x + glyph.advance)
      if j + 1 >= shaped.len:
        break
      let nextRune = max(0, min(shaped[j + 1].cluster, columns.high))
      if columns[nextRune] != col:
        break
      inc j

    var span = 0
    for runeIndex in firstRune .. lastRune:
      span += widths[runeIndex]
    let room = float32(max(span, 1)) * cellWidth
    var group = shaped[i .. j]
    if x1 > x0 and room / (x1 - x0) < 0.95'f32:
      let smallText = text.runeSubStr(firstRune, lastRune - firstRune + 1)
      var smallFont = font
      smallFont.size *= max(room / (x1 - x0), 0.5'f32)
      let smaller = cache.shape(smallText, smallFont)
      if smaller.len > 0:
        group = smaller
        x0 = smaller[0].x
        x1 = smaller[0].x + smaller[0].advance
        for glyph in smaller:
          x0 = min(x0, glyph.x)
          x1 = max(x1, glyph.x + glyph.advance)
    var offset = (room - (x1 - x0)) / 2
    if abs(float64(offset)) < 0.5 / float64(scale):
      offset = 0
    let cellX = float32(col) * cellWidth
    for source in group:
      var glyph = source
      glyph.x = cellX + offset + (glyph.x - x0)
      result.glyphs.add(glyph)
      result.columns.add(col)
    i = j + 1

proc addShapedRun(runs: var seq[PaintedGlyphRun]; cache: TerminalPaintCache;
    text: string; columns, widths: openArray[int]; color: ui.Color;
    bold, italic: bool; cellWidth, scale: float32;
    options: TerminalPaintOptions) =
  if text.len == 0:
    return
  let run = shapedRun(cache, text, columns, widths, color, bold, italic,
    cellWidth, scale, options)
  if run.glyphs.len > 0:
    runs.add(run)

proc paintBackgrounds(painter: var ui.Painter; row: TerminalFrameRow;
                      y, x, cellWidth, cellHeight: float32;
                      defaultBackground: ui.Color; colors: RenderColors) =
  var start = -1
  var color = defaultBackground
  for col in 0 .. row.cells.len:
    if col < row.cells.len and
        row.cells[col].cell.wide in {cellSpacerTail, cellSpacerHead}:
      continue
    var nextColor = color
    var hasColor = false
    if col < row.cells.len and
        row.cells[col].cell.wide notin {cellSpacerTail, cellSpacerHead}:
      let cell = row.cells[col].paintCell(colors)
      hasColor = cell.hasBackground and cell.background != defaultBackground
      if hasColor:
        nextColor = cell.background
    if start >= 0 and (not hasColor or nextColor != color):
      painter.fill(ui.Rect(x: x + float32(start) * cellWidth, y: y,
        w: float32(col - start) * cellWidth, h: cellHeight), color, 0)
      start = -1
    if hasColor and start < 0:
      start = col
      color = nextColor

proc paintSelection(painter: var ui.Painter; row: TerminalFrameRow;
                    y, x, cellWidth, cellHeight: float32;
                    selection: ui.Color) =
  if row.selection.isNone or row.cells.len == 0:
    return
  let range = row.selection.get()
  let first = max(0, range.start)
  let last = min(row.cells.high, range.finish)
  if first <= last:
    painter.fill(ui.Rect(x: x + float32(first) * cellWidth, y: y,
      w: float32(last - first + 1) * cellWidth, h: cellHeight), selection, 0)

proc addDecoration(spans: var seq[DecorationSpan]; first, past, kind: int;
                   color: ui.Color) =
  if first >= past:
    return
  if spans.len > 0 and spans[^1].past == first and
      spans[^1].kind == kind and spans[^1].color == color:
    spans[^1].past = past
  else:
    spans.add(DecorationSpan(first: first, past: past, kind: kind,
      color: color))

proc paintDecoration(painter: var ui.Painter; span: DecorationSpan;
    x, rowY, cellWidth, baseline, scale, fontSize: float32) =
  let
    x0 = x + float32(span.first) * cellWidth
    x1 = x + float32(span.past) * cellWidth
    pixel = 1 / scale
    thickness = max(round(fontSize * scale / 14), 1'f32) * pixel
    underlineY = rowY + baseline +
      max(round(fontSize * scale / 10), 1'f32) * pixel
  case span.kind
  of 10: # strikethrough
    painter.fill(ui.Rect(x: x0, y: rowY + baseline - fontSize * 0.3'f32,
      w: x1 - x0, h: thickness), span.color, 0)
  of 11: # overline
    painter.fill(ui.Rect(x: x0, y: rowY, w: x1 - x0, h: thickness),
      span.color, 0)
  of 2: # double underline
    painter.fill(ui.Rect(x: x0, y: underlineY - thickness,
      w: x1 - x0, h: thickness), span.color, 0)
    painter.fill(ui.Rect(x: x0, y: underlineY + thickness,
      w: x1 - x0, h: thickness), span.color, 0)
  of 3: # curly underline
    let count = int((x1 - x0) / cellWidth * 8)
    if count > 0:
      let amplitude = 1.5'f32 * thickness
      let path = ui.newPath()
      discard path.moveTo(x0, underlineY)
      for i in 1 .. count:
        let at = x0 + (x1 - x0) * float32(i) / float32(count)
        discard path.lineTo(at, underlineY + amplitude * float32(sin(
          float64((at - x0) / cellWidth * 2 * PI))))
      painter.strokePath(path, thickness, span.color)
    else:
      painter.fill(ui.Rect(x: x0, y: underlineY, w: x1 - x0,
        h: thickness), span.color, 0)
  of 4, 5: # dotted and dashed underline
    let step = if span.kind == 5: cellWidth / 2 else: 2 * thickness
    let dash = if span.kind == 5: cellWidth / 4 else: thickness
    var at = x0
    while at < x1:
      painter.fill(ui.Rect(x: at, y: underlineY, w: min(dash, x1 - at),
        h: thickness), span.color, 0)
      at += step
  else: # single underline
    painter.fill(ui.Rect(x: x0, y: underlineY, w: x1 - x0,
      h: thickness), span.color, 0)

proc paintDecorations(painter: var ui.Painter; row: TerminalFrameRow;
    x, rowY, cellWidth, baseline, scale: float32; colors: RenderColors;
    selectedStart, selectedFinish: int; selectionText: ui.Color;
    options: TerminalPaintOptions) =
  var underlines, strikes, overlines: seq[DecorationSpan]
  for col, cell in row.cells:
    if cell.cell.wide in {cellSpacerTail, cellSpacerHead}:
      continue
    let resolved = cell.paintCell(colors)
    let selected = selectionText.a > 0 and col >= selectedStart and
      col <= selectedFinish
    let foreground = if selected: selectionText else: resolved.foreground
    let width = if cell.cell.wide == cellWide: 2 else: 1
    let past = col + width
    if resolved.underline > 0:
      underlines.addDecoration(col, past, resolved.underline,
        if selected: selectionText else: resolved.underlineColor)
    if resolved.strike:
      strikes.addDecoration(col, past, 10, foreground)
    if resolved.overline:
      overlines.addDecoration(col, past, 11, foreground)
  for span in underlines:
    painter.paintDecoration(span, x, rowY, cellWidth, baseline, scale,
      options.fontSize)
  for span in strikes:
    painter.paintDecoration(span, x, rowY, cellWidth, baseline, scale,
      options.fontSize)
  for span in overlines:
    painter.paintDecoration(span, x, rowY, cellWidth, baseline, scale,
      options.fontSize)

proc paintGlyphRuns(painter: var ui.Painter; runs: openArray[PaintedGlyphRun];
    x, baseline: float32; override = ui.transparent) =
  for run in runs:
    painter.glyphs(run.glyphs, x, baseline,
      if override.a > 0: override else: run.foreground)

proc paintRowText(painter: var ui.Painter; bounds: ui.Rect;
    row: TerminalFrameRow; x, rowY, baseline, cellWidth, cellHeight,
    scale: float32; colors: RenderColors; selectionText, cursorText: ui.Color;
    selectedStart, selectedFinish, cursorColumn: int; blockCursor: bool;
    options: TerminalPaintOptions; cache: TerminalPaintCache) =
  var
    runs: seq[PaintedGlyphRun]
    runText = ""
    runColumns, runWidths: seq[int]
    activeStyle: TextStyle
    hasStyle = false
  for col, cell in row.cells:
    if cell.cell.wide in {cellSpacerTail, cellSpacerHead}:
      continue
    let resolved = cell.paintCell(colors)
    let value = cell.cellText(resolved)
    if value.len == 0:
      continue
    let nextStyle = TextStyle(foreground: resolved.foreground,
      bold: resolved.bold, italic: resolved.italic)
    if hasStyle and activeStyle != nextStyle and not value.onlySpaces:
      runs.addShapedRun(cache, runText, runColumns, runWidths,
        activeStyle.foreground, activeStyle.bold, activeStyle.italic,
        cellWidth, scale, options)
      runText.setLen(0)
      runColumns.setLen(0)
      runWidths.setLen(0)
      hasStyle = false
    if not hasStyle:
      activeStyle = nextStyle
      hasStyle = true
    let cellsWide = if cell.cell.wide == cellWide: 2 else: 1
    for runeIndex in 0 ..< value.runeLen:
      runColumns.add(col)
      runWidths.add(if runeIndex == 0: cellsWide else: 0)
    runText.add(value)
  if hasStyle:
    runs.addShapedRun(cache, runText, runColumns, runWidths,
      activeStyle.foreground, activeStyle.bold, activeStyle.italic,
      cellWidth, scale, options)

  let firstSelected = max(0, selectedStart)
  let lastSelected = min(row.cells.high, selectedFinish)
  if selectionText.a == 0 or firstSelected > lastSelected:
    painter.paintGlyphRuns(runs, x, baseline)
  else:
    let selectedX0 = x + float32(firstSelected) * cellWidth
    let selectedX1 = x + float32(lastSelected + 1) * cellWidth
    let left = ui.Rect(x: bounds.x, y: rowY,
      w: max(selectedX0 - bounds.x, 0'f32), h: cellHeight)
    let middle = ui.Rect(x: selectedX0, y: rowY,
      w: selectedX1 - selectedX0, h: cellHeight)
    let right = ui.Rect(x: selectedX1, y: rowY,
      w: max(bounds.x + bounds.w - selectedX1, 0'f32), h: cellHeight)
    if left.w > 0:
      painter.clip(left, 0, proc(target: var ui.Painter) =
        target.paintGlyphRuns(runs, x, baseline))
    if middle.w > 0:
      painter.clip(middle, 0, proc(target: var ui.Painter) =
        target.paintGlyphRuns(runs, x, baseline, selectionText))
    if right.w > 0:
      painter.clip(right, 0, proc(target: var ui.Painter) =
        target.paintGlyphRuns(runs, x, baseline))

  if blockCursor and cursorColumn >= 0 and cursorColumn < row.cells.len:
    let wide = row.cells[cursorColumn].cell.wide == cellWide
    let cursor = ui.Rect(x: x + float32(cursorColumn) * cellWidth,
      y: rowY, w: cellWidth * (if wide: 2'f32 else: 1'f32), h: cellHeight)
    painter.clip(cursor, 0, proc(target: var ui.Painter) =
      for run in runs:
        for i, col in run.columns:
          if col == cursorColumn:
            target.glyphs(run.glyphs[i .. i], x, baseline, cursorText))

  painter.paintDecorations(row, x, rowY, cellWidth, baseline - rowY, scale,
    colors, selectedStart, selectedFinish, selectionText, options)

proc paintFrame*(painter: var ui.Painter; bounds: ui.Rect;
    frame: TerminalFrame; options: TerminalPaintOptions;
    cache: TerminalPaintCache = nil) =
  ## Paints terminal backgrounds, selections, text decorations, and cursor.
  let options = options.normalized()
  let grid = painter.grid(bounds, options, cache)
  let background = uiColor(frame.colors.background)
  let foreground = uiColor(frame.colors.foreground)
  let selection = if options.selection.a > 0:
      options.selection else: foreground.alpha(0.3'f32)
  let cursorColor = if options.cursor.a > 0:
      options.cursor
    elif frame.colors.hasCursor: uiColor(frame.colors.cursor)
    else: foreground
  let cursorText = if options.cursorText.a > 0:
      options.cursorText else: background
  let scale = max(painter.scale(), 0.01'f32)
  let originX = (float32(round(float64(bounds.x * scale))) +
    float32(round(float64(max(options.paddingX, 0'f32) * scale)))) / scale
  let originY = (float32(round(float64(bounds.y * scale))) +
    float32(round(float64(max(options.paddingY, 0'f32) * scale)))) / scale
  painter.clip(bounds, 0, proc(target: var ui.Painter) =
    if not options.transparent:
      target.fill(bounds, background, 0)
    for y in 0 ..< min(frame.rows, frame.viewport.len):
      let row = frame.viewport[y]
      let rowY = originY + float32(y) * grid.cellHeight
      target.paintBackgrounds(row, rowY, originX, grid.cellWidth,
        grid.cellHeight, background, frame.colors)
      target.paintSelection(row, rowY, originX, grid.cellWidth,
        grid.cellHeight, selection)

    var cursorColumn = -1
    var cursorRow = -1
    var blockCursor = false
    var cursorRect = ui.Rect()
    var cursorStyle = cursorBlock
    let cursorOn = options.preedit.len == 0 and
      (options.cursorBlinkOn or not frame.cursor.blinking)
    if cursorOn and frame.cursor.inView and frame.cursor.visible and
        frame.cursor.y >= 0 and frame.cursor.y < min(frame.rows,
            frame.viewport.len):
      cursorColumn = frame.cursor.x
      if frame.cursor.wideTail and cursorColumn > 0:
        dec cursorColumn
      cursorRow = frame.cursor.y
      if cursorColumn >= 0 and
          cursorColumn < frame.viewport[cursorRow].cells.len:
        cursorStyle = frame.cursor.style
        if not options.focused and cursorStyle == cursorBlock:
          cursorStyle = cursorBlockHollow
        let wide = frame.viewport[cursorRow].cells[cursorColumn].cell.wide ==
          cellWide
        cursorRect = ui.Rect(x: originX + float32(cursorColumn) *
            grid.cellWidth,
          y: originY + float32(cursorRow) * grid.cellHeight,
          w: grid.cellWidth * (if wide: 2'f32 else: 1'f32),
          h: grid.cellHeight)
        blockCursor = cursorStyle == cursorBlock
      else:
        cursorRow = -1
      if blockCursor:
        target.fill(cursorRect, cursorColor, 0)

    for y in 0 ..< min(frame.rows, frame.viewport.len):
      let row = frame.viewport[y]
      let rowY = originY + float32(y) * grid.cellHeight
      let (selectedStart, selectedFinish) = if row.selection.isSome:
          (row.selection.get().start, row.selection.get().finish)
        else: (-1, -1)
      target.paintRowText(bounds, row, originX, rowY,
        rowY + grid.baselineOffset, grid.cellWidth, grid.cellHeight, scale,
        frame.colors,
        options.selectionText, cursorText,
        selectedStart, selectedFinish,
        if y == cursorRow: cursorColumn else: -1, blockCursor and y ==
        cursorRow,
        options, cache)
    if cursorRow >= 0 and not blockCursor:
      case cursorStyle
      of cursorBlockHollow:
        target.stroke(cursorRect, cursorColor, 0, 1 / scale)
      of cursorBar:
        target.fill(ui.Rect(x: cursorRect.x, y: cursorRect.y,
          w: max(round(1.5'f32 * scale), 1'f32) / scale,
          h: cursorRect.h), cursorColor, 0)
      of cursorUnderline:
        let thickness = max(round(1.5'f32 * scale), 1'f32) / scale
        target.fill(ui.Rect(x: cursorRect.x,
          y: cursorRect.y + cursorRect.h - thickness,
          w: cursorRect.w, h: thickness), cursorColor, 0)
      of cursorBlock:
        discard
    if options.preedit.len > 0 and options.focused and
        frame.cursor.inView and frame.cursor.visible and
        frame.cursor.y >= 0 and frame.cursor.y < min(frame.rows,
            frame.viewport.len):
      var preeditColumn = frame.cursor.x
      if frame.cursor.wideTail and preeditColumn > 0:
        dec preeditColumn
      let preeditX = originX + float32(preeditColumn) * grid.cellWidth
      let preeditY = originY + float32(frame.cursor.y) * grid.cellHeight
      let span = ui.Span(text: options.preedit, font: options.fontFamily,
        features: options.fontFeatures, size: options.fontSize,
        weight: options.fontWeight, color: foreground)
      let preeditSize = target.measureText(0, span)
      let preeditWidth = max(preeditSize.width, grid.cellWidth)
      target.fill(ui.Rect(x: preeditX, y: preeditY, w: preeditWidth,
        h: grid.cellHeight), background, 0)
      discard target.richText(preeditX, preeditY + grid.textOffsetY, 0, span)
      let thickness = 1 / scale
      target.fill(ui.Rect(x: preeditX,
        y: preeditY + grid.cellHeight - thickness,
        w: preeditWidth, h: thickness), foreground, 0)
      var prefix = ""
      var runeIndex = 0
      let caret = max(0, options.preeditCaret)
      for rune in options.preedit.runes:
        if runeIndex >= caret:
          break
        prefix.add(toUTF8(rune))
        inc runeIndex
      let caretWidth = target.measureText(0, ui.Span(text: prefix,
        font: options.fontFamily, features: options.fontFeatures,
        size: options.fontSize, weight: options.fontWeight)).width
      target.fill(ui.Rect(x: preeditX + caretWidth, y: preeditY,
        w: 1 / scale, h: grid.cellHeight), foreground, 0)
  )
