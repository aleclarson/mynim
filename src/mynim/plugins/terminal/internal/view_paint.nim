## Paints owned Ghostty terminal frames through Mynim's native UI painter.

import std/[math, options, strutils, unicode]
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

  TerminalScrollbarGeometry* = object
    track*, thumb*: ui.Rect
    maxOffset*: uint64

  PaintedCell = object
    foreground, background, underlineColor: ui.Color
    hasBackground, invisible: bool
    bold, italic, strike, overline: bool
    underline: int

  TextStyle = object
    foreground, underlineColor: ui.Color
    bold, italic, strike: bool
    underline: int

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
           options: TerminalPaintOptions): TerminalGrid =
  ## Measures the fixed-width cell grid that fits in an element's bounds.
  let options = options.normalized()
  let fontFamily = options.fontFamily
  let fontSize = options.fontSize
  let fontWeight = options.fontWeight
  let features = options.fontFeatures
  let measured = painter.measureText(0, ui.Span(text: "M", font: fontFamily,
    features: features, size: fontSize, weight: fontWeight))
  let naturalHeight = max(measured.height, fontSize)
  let lineHeight = if options.lineHeight > 0: options.lineHeight else: 1'f32
  let scale = max(painter.scale(), 0.01'f32)
  result.cellWidthPixels = max(1, int(round(
    max(measured.width, max(fontSize * 0.5'f32, 1'f32)) * scale)))
  result.cellHeightPixels = max(1, int(round(
    max(naturalHeight * lineHeight, 1'f32) * scale)))
  result.cellWidth = float32(result.cellWidthPixels) / scale
  result.cellHeight = float32(result.cellHeightPixels) / scale
  result.textOffsetY = max((result.cellHeight - naturalHeight) / 2, 0'f32)
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

proc textStyle(cell: PaintedCell; foreground: ui.Color): TextStyle =
  TextStyle(foreground: foreground, underlineColor: cell.underlineColor,
    bold: cell.bold, italic: cell.italic, strike: cell.strike,
    underline: cell.underline)

proc appendCellText(spans: var seq[ui.Span]; run: var string;
                     activeStyle: var TextStyle; hasStyle: var bool;
                     nextText: string; nextStyle: TextStyle;
                     options: TerminalPaintOptions) =
  if hasStyle and activeStyle != nextStyle:
    spans.add(ui.Span(text: move(run), font: options.fontFamily,
      features: options.fontFeatures, size: options.fontSize,
      weight: if activeStyle.bold: min(max(options.fontWeight + 300, 700), 900)
        else: options.fontWeight,
      italic: activeStyle.italic, color: activeStyle.foreground,
      decorationColor: activeStyle.underlineColor,
      underline: activeStyle.underline > 0,
      wavyUnderline: activeStyle.underline == 3,
      strikethrough: activeStyle.strike))
    run.setLen(0)
    hasStyle = false
  if not hasStyle:
    activeStyle = nextStyle
    hasStyle = true
  run.add(nextText)

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

proc paintOverlines(painter: var ui.Painter; row: TerminalFrameRow;
                    y, x, cellWidth, scale: float32;
                    colors: RenderColors) =
  var start = -1
  var color = ui.transparent
  for col in 0 .. row.cells.len:
    if col < row.cells.len and
        row.cells[col].cell.wide in {cellSpacerTail, cellSpacerHead}:
      continue
    var hasLine = false
    var nextColor = color
    if col < row.cells.len:
      let resolved = row.cells[col].paintCell(colors)
      hasLine = resolved.overline
      nextColor = resolved.foreground
    if start >= 0 and (not hasLine or nextColor != color):
      painter.fill(ui.Rect(x: x + float32(start) * cellWidth, y: y,
        w: float32(col - start) * cellWidth, h: 1 / scale), color, 0)
      start = -1
    if hasLine and start < 0:
      start = col
      color = nextColor

proc paintRowText(painter: var ui.Painter; row: TerminalFrameRow;
                  x, y, cellWidth: float32; colors: RenderColors;
                  selectionText, cursorText: ui.Color;
                  selectedStart, selectedFinish, cursorColumn: int;
                  blockCursor: bool; options: TerminalPaintOptions) =
  var spans: seq[ui.Span]
  var run = ""
  var activeStyle: TextStyle
  var hasStyle = false
  for col, cell in row.cells:
    let resolved = cell.paintCell(colors)
    var foreground = resolved.foreground
    if blockCursor and col == cursorColumn:
      foreground = cursorText
    elif selectionText.a > 0 and col >= selectedStart and col <= selectedFinish:
      foreground = selectionText
    let value = cell.cellText(resolved)
    if value.len == 0:
      continue
    spans.appendCellText(run, activeStyle, hasStyle, value,
      resolved.textStyle(foreground), options)
  if hasStyle:
    spans.add(ui.Span(text: move(run), font: options.fontFamily,
      features: options.fontFeatures, size: options.fontSize,
      weight: if activeStyle.bold: min(max(options.fontWeight + 300, 700), 900)
        else: options.fontWeight,
      italic: activeStyle.italic, color: activeStyle.foreground,
      decorationColor: activeStyle.underlineColor,
      underline: activeStyle.underline > 0,
      wavyUnderline: activeStyle.underline == 3,
      strikethrough: activeStyle.strike))
  if spans.len > 0:
    discard painter.richText(x, y, 0, spans)

proc paintFrame*(painter: var ui.Painter; bounds: ui.Rect;
                 frame: TerminalFrame; options: TerminalPaintOptions) =
  ## Paints terminal backgrounds, selections, text decorations, and cursor.
  let options = options.normalized()
  let grid = painter.grid(bounds, options)
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
      target.paintRowText(row, originX, rowY + grid.textOffsetY,
        grid.cellWidth, frame.colors,
        options.selectionText, cursorText,
        selectedStart, selectedFinish,
        if y == cursorRow: cursorColumn else: -1, blockCursor and y ==
        cursorRow,
        options)
      target.paintOverlines(row, rowY, originX, grid.cellWidth, scale,
        frame.colors)
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
