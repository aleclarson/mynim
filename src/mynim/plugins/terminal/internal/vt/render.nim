## Frame state copied from a Ghostty terminal for native rendering.

import std/options
import ./[library, terminal]

type
  GhosttyResult = int32
  RenderStateNewProc = proc(allocator: pointer; state: ptr pointer):
    GhosttyResult {.cdecl.}
  RenderStateFreeProc = proc(state: pointer) {.cdecl.}
  RenderStateUpdateProc = proc(state, terminal: pointer):
    GhosttyResult {.cdecl.}
  RenderStateCleanProc = proc(state: pointer): GhosttyResult {.cdecl.}
  RenderStateGetProc = proc(state: pointer; data: int32; value: pointer):
    GhosttyResult {.cdecl.}
  RowIteratorNewProc = proc(allocator: pointer; iteratorHandle: ptr pointer):
    GhosttyResult {.cdecl.}
  RowIteratorFreeProc = proc(iteratorHandle: pointer) {.cdecl.}
  RowIteratorNextProc = proc(iteratorHandle: pointer): bool {.cdecl.}
  RowGetProc = proc(iteratorHandle: pointer; data: int32; value: pointer):
    GhosttyResult {.cdecl.}
  RowCellsNewProc = proc(allocator: pointer; cells: ptr pointer):
    GhosttyResult {.cdecl.}
  RowCellsFreeProc = proc(cells: pointer) {.cdecl.}
  RowCellsSelectProc = proc(cells: pointer; x: uint16): GhosttyResult {.cdecl.}
  RowCellsGetProc = proc(cells: pointer; data: int32; value: pointer):
    GhosttyResult {.cdecl.}

  FfiCursor {.bycopy.} = object
    size: csize_t
    viewportHasValue: bool
    viewportX, viewportY: uint16
    wideTail, visible, blinking, passwordInput: bool
    visualStyle: int32

  FfiColors {.bycopy.} = object
    size: csize_t
    background, foreground, cursor: RGB
    cursorHasValue: bool
    palette: array[256, RGB]

  FfiRowSelection {.bycopy.} = object
    size: csize_t
    startX, endX: uint16

  FfiCellsView {.bycopy.} = object
    data: pointer
    length: csize_t

  FfiRowId {.bycopy.} = object
    bits: array[2, uint64]

  FfiStyleColor {.bycopy.} = object
    tag, padding: int32
    value: array[8, byte]

  FfiStyle {.bycopy.} = object
    size: csize_t
    foreground, background, underlineColor: FfiStyleColor
    bold, italic, faint, blink, inverse, invisible, strikethrough, overline: bool
    underline: int32

  RenderDirty* = enum
    renderClean = 0
    renderPartial = 1
    renderFull = 2

  CursorStyle* = enum
    cursorBar = 0
    cursorBlock = 1
    cursorUnderline = 2
    cursorBlockHollow = 3

  CellWidth* = enum
    cellNarrow = 0
    cellWide = 1
    cellSpacerTail = 2
    cellSpacerHead = 3

  RenderColorKind* = enum
    renderColorNone = 0
    renderColorPalette = 1
    renderColorRgb = 2

  RGB* = object
    r*, g*, b*: uint8

  RenderColors* = object
    background*, foreground*, cursor*: RGB
    hasCursor*: bool
    palette*: array[256, RGB]

  RenderCursor* = object
    inView*: bool
    x*, y*: int
    wideTail*: bool
    visible*, blinking*, password*: bool
    style*: CursorStyle

  RowID* = object
    bits*: array[2, uint64]

  RenderCell* = object
    codepoint*: uint32
    grapheme*: bool
    styleId*: uint16
    wide*: CellWidth
    hyperlink*: bool
    background*: RGB
    hasBackground*, paletteBackground*: bool

  RowSelection* = object
    start*, finish*: int

  RenderColor* = object
    kind*: RenderColorKind
    paletteIndex*: uint8
    rgb*: RGB

  RenderStyle* = object
    foreground*, background*, underlineColor*: RenderColor
    bold*, italic*, faint*, blink*, inverse*, invisible*: bool
    strikethrough*, overline*: bool
    underline*: int

  GhosttyRenderState* = ref object
    library: GhosttyVT
    handle: pointer
    rowIterator: pointer
    rowCellsHandle: pointer
    iteratorReady, rowPositioned: bool
    rowCellsReady: bool

static:
  doAssert sizeof(FfiCursor) == 24
  doAssert offsetOf(FfiCursor, viewportX) == 10
  doAssert offsetOf(FfiCursor, visualStyle) == 20
  doAssert sizeof(RGB) == 3
  doAssert sizeof(FfiColors) == 792
  doAssert offsetOf(FfiColors, palette) == 18
  doAssert sizeof(FfiRowSelection) == 16
  doAssert offsetOf(FfiRowSelection, startX) == 8
  doAssert sizeof(FfiCellsView) == 16
  doAssert offsetOf(FfiCellsView, length) == 8
  doAssert sizeof(FfiRowId) == 16
  doAssert sizeof(FfiStyleColor) == 16
  doAssert offsetOf(FfiStyleColor, value) == 8
  doAssert sizeof(FfiStyle) == 72
  doAssert offsetOf(FfiStyle, foreground) == 8
  doAssert offsetOf(FfiStyle, bold) == 56
  doAssert offsetOf(FfiStyle, underline) == 64

const
  success: GhosttyResult = 0
  dataCols = 1'i32
  dataRows = 2'i32
  dataDirty = 3'i32
  dataRowIterator = 4'i32
  dataCursor = 18'i32
  dataColors = 19'i32
  rowDataDirty = 1'i32
  rowDataSelection = 4'i32
  rowDataCellsRaw = 5'i32
  rowDataViewportY = 6'i32
  rowDataID = 7'i32
  rowDataCells = 3'i32
  cellDataStyle = 2'i32
  cellDataGraphemesLen = 3'i32
  cellDataGraphemesBuf = 4'i32
  noValue: GhosttyResult = -4

proc requiredSymbol(library: GhosttyVT; name: string): pointer =
  result = library.symbol(name)
  if result.isNil:
    raise newException(IOError, "libghostty-vt is missing " & name)

proc checkResult(operation: string; status: GhosttyResult) =
  if status != success:
    raise newException(IOError,
      "libghostty-vt " & operation & " failed with result " & $status)

proc requireHandle(state: GhosttyRenderState): pointer =
  if state.isNil or state.handle.isNil:
    raise newException(IOError, "render state is closed")
  state.handle

proc newGhosttyRenderState*(library: GhosttyVT): GhosttyRenderState =
  ## Creates an empty render state associated with a loaded Ghostty library.
  if library.isNil:
    raise newException(ValueError, "render state Ghostty library is nil")
  let create = cast[RenderStateNewProc](requiredSymbol(library,
    "ghostty_render_state_new"))
  let free = cast[RenderStateFreeProc](requiredSymbol(library,
    "ghostty_render_state_free"))
  let createIterator = cast[RowIteratorNewProc](requiredSymbol(library,
    "ghostty_render_state_row_iterator_new"))
  let freeIterator = cast[RowIteratorFreeProc](requiredSymbol(library,
    "ghostty_render_state_row_iterator_free"))
  let createCells = cast[RowCellsNewProc](requiredSymbol(library,
    "ghostty_render_state_row_cells_new"))
  var handle: pointer
  checkResult("render-state creation", create(nil, addr handle))
  if handle.isNil:
    raise newException(IOError,
      "libghostty-vt created a render state without a handle")
  new(result)
  result.library = library
  result.handle = handle
  var newIterator: pointer
  try:
    checkResult("row-iterator creation",
      createIterator(nil, addr newIterator))
  except CatchableError:
    free(result.handle)
    result.handle = nil
    raise
  if newIterator.isNil:
    free(result.handle)
    result.handle = nil
    raise newException(IOError,
      "libghostty-vt created a row iterator without a handle")
  result.rowIterator = newIterator
  var newCells: pointer
  try:
    checkResult("row-cells creation", createCells(nil, addr newCells))
  except CatchableError:
    freeIterator(result.rowIterator)
    result.rowIterator = nil
    free(result.handle)
    result.handle = nil
    raise
  if newCells.isNil:
    freeIterator(result.rowIterator)
    result.rowIterator = nil
    free(result.handle)
    result.handle = nil
    raise newException(IOError,
      "libghostty-vt created row cells without a handle")
  result.rowCellsHandle = newCells

proc close*(state: GhosttyRenderState) =
  ## Frees render-state memory; close it before unloading its library.
  if state.isNil or state.handle.isNil:
    return
  let free = cast[RenderStateFreeProc](requiredSymbol(state.library,
    "ghostty_render_state_free"))
  var freeIterator: RowIteratorFreeProc
  var freeCells: RowCellsFreeProc
  if not state.rowCellsHandle.isNil:
    freeCells = cast[RowCellsFreeProc](requiredSymbol(state.library,
      "ghostty_render_state_row_cells_free"))
  if not state.rowIterator.isNil:
    freeIterator = cast[RowIteratorFreeProc](requiredSymbol(state.library,
      "ghostty_render_state_row_iterator_free"))
  if not state.rowCellsHandle.isNil:
    freeCells(state.rowCellsHandle)
    state.rowCellsHandle = nil
  if not state.rowIterator.isNil:
    freeIterator(state.rowIterator)
    state.rowIterator = nil
  let handle = state.handle
  state.handle = nil
  free(handle)

proc update*(state: GhosttyRenderState; terminal: GhosttyTerminal) =
  ## Copies terminal state for a frame. Calls must be serialized per object.
  let stateHandle = requireHandle(state)
  if terminal.isNil or not terminal.belongsToLibrary(state.library):
    raise newException(ValueError,
      "render state and terminal must use the same Ghostty library")
  let updateState = cast[RenderStateUpdateProc](requiredSymbol(state.library,
    "ghostty_render_state_update"))
  checkResult("render-state update",
    updateState(stateHandle, terminal.rawHandle()))
  state.iteratorReady = false
  state.rowPositioned = false
  state.rowCellsReady = false

proc clean*(state: GhosttyRenderState) =
  ## Marks the current frame as fully drawn after a successful render.
  let handle = requireHandle(state)
  let markClean = cast[RenderStateCleanProc](requiredSymbol(state.library,
    "ghostty_render_state_clean"))
  checkResult("render-state clean", markClean(handle))

proc getUint16(state: GhosttyRenderState; key: int32): int =
  let handle = requireHandle(state)
  var value: uint16
  let getData = cast[RenderStateGetProc](requiredSymbol(state.library,
    "ghostty_render_state_get"))
  checkResult("render-state query",
    getData(handle, key, addr value))
  int(value)

proc size*(state: GhosttyRenderState): tuple[cols, rows: int] =
  ## Returns the viewport size in cells.
  (getUint16(state, dataCols), getUint16(state, dataRows))

proc dirty*(state: GhosttyRenderState): RenderDirty =
  ## Reports whether none, some, or all of the frame needs drawing.
  let handle = requireHandle(state)
  var value: int32
  let getData = cast[RenderStateGetProc](requiredSymbol(state.library,
    "ghostty_render_state_get"))
  checkResult("render-state dirty query",
    getData(handle, dataDirty, addr value))
  if value < int32(low(RenderDirty)) or value > int32(high(RenderDirty)):
    raise newException(IOError, "libghostty-vt returned an unknown dirty state")
  RenderDirty(value)

proc cursor*(state: GhosttyRenderState): RenderCursor =
  ## Returns viewport cursor state from the copied frame.
  let handle = requireHandle(state)
  var value = FfiCursor(size: csize_t(sizeof(FfiCursor)))
  let getData = cast[RenderStateGetProc](requiredSymbol(state.library,
    "ghostty_render_state_get"))
  checkResult("render-state cursor query",
    getData(handle, dataCursor, addr value))
  if value.visualStyle < int32(low(CursorStyle)) or
      value.visualStyle > int32(high(CursorStyle)):
    raise newException(IOError, "libghostty-vt returned an unknown cursor style")
  result.inView = value.viewportHasValue
  if result.inView:
    result.x = int(value.viewportX)
    result.y = int(value.viewportY)
    result.wideTail = value.wideTail
  result.visible = value.visible
  result.blinking = value.blinking
  result.password = value.passwordInput
  result.style = CursorStyle(value.visualStyle)

proc colors*(state: GhosttyRenderState): RenderColors =
  ## Returns the resolved frame colors and active 256-color palette.
  let handle = requireHandle(state)
  var value = FfiColors(size: csize_t(sizeof(FfiColors)))
  let getData = cast[RenderStateGetProc](requiredSymbol(state.library,
    "ghostty_render_state_get"))
  checkResult("render-state color query",
    getData(handle, dataColors, addr value))
  result.background = value.background
  result.foreground = value.foreground
  result.cursor = value.cursor
  result.hasCursor = value.cursorHasValue
  result.palette = value.palette

proc rows*(state: GhosttyRenderState) =
  ## Positions the row iterator before the first row of the current frame.
  let stateHandle = requireHandle(state)
  if state.rowIterator.isNil:
    raise newException(IOError, "render-state row iterator is closed")
  let getData = cast[RenderStateGetProc](requiredSymbol(state.library,
    "ghostty_render_state_get"))
  checkResult("render-state rows query",
    getData(stateHandle, dataRowIterator, addr state.rowIterator))
  state.iteratorReady = true
  state.rowPositioned = false

proc nextRow*(state: GhosttyRenderState): bool =
  ## Advances to the next viewport row, top to bottom.
  discard requireHandle(state)
  if not state.iteratorReady or state.rowIterator.isNil:
    raise newException(IOError, "call rows() before advancing the row iterator")
  let next = cast[RowIteratorNextProc](requiredSymbol(state.library,
    "ghostty_render_state_row_iterator_next"))
  result = next(state.rowIterator)
  state.rowPositioned = result
  state.rowCellsReady = false
  if not result:
    state.iteratorReady = false

proc rowGet(state: GhosttyRenderState; key: int32; output: pointer): bool =
  discard requireHandle(state)
  if not state.rowPositioned or state.rowIterator.isNil:
    raise newException(IOError, "row data requested without a current row")
  let getData = cast[RowGetProc](requiredSymbol(state.library,
    "ghostty_render_state_row_get"))
  let status = getData(state.rowIterator, key, output)
  if status == noValue:
    return false
  checkResult("render-state row query", status)
  true

proc rowDirty*(state: GhosttyRenderState): bool =
  ## Reports whether the current row changed since the last clean().
  discard rowGet(state, rowDataDirty, addr result)

proc rowViewportY*(state: GhosttyRenderState): int =
  ## Returns the current row's zero-based position in the viewport.
  var value: int32
  discard rowGet(state, rowDataViewportY, addr value)
  int(value)

proc rowId*(state: GhosttyRenderState): RowID =
  ## Returns the opaque identity of the current row across frame updates.
  var value: FfiRowId
  discard rowGet(state, rowDataID, addr value)
  RowID(bits: value.bits)

proc rowSelection*(state: GhosttyRenderState): Option[RowSelection] =
  ## Returns the inclusive selected cell range for the current row, if any.
  var value = FfiRowSelection(size: csize_t(sizeof(FfiRowSelection)))
  if not rowGet(state, rowDataSelection, addr value):
    return none(RowSelection)
  some(RowSelection(start: int(value.startX), finish: int(value.endX)))

proc cellField(value: uint64; field: GhosttyCellField): uint64 {.inline.} =
  let mask = if field.width == 64: high(uint64)
    else: (1'u64 shl field.width) - 1
  (value shr field.lsb) and mask

proc rowCells*(state: GhosttyRenderState): seq[RenderCell] =
  ## Copies packed cells for the current row; the result survives next update.
  var view: FfiCellsView
  if not rowGet(state, rowDataCellsRaw, addr view):
    return
  if view.length == 0:
    return
  if view.data.isNil or view.length > csize_t(high(int)):
    raise newException(IOError, "libghostty-vt returned an invalid cell view")
  let cells = cast[ptr UncheckedArray[uint64]](view.data)
  let layout = state.library.manifest.cell
  result = newSeq[RenderCell](int(view.length))
  for index in 0 ..< result.len:
    let raw = cells[index]
    let tag = cellField(raw, layout.contentTag)
    var cell: RenderCell
    cell.styleId = uint16(cellField(raw, layout.styleId))
    let wide = cellField(raw, layout.wide)
    if wide > uint64(ord(high(CellWidth))):
      raise newException(IOError, "libghostty-vt returned an unknown cell width")
    cell.wide = CellWidth(wide)
    cell.hyperlink = cellField(raw, layout.hyperlink) != 0
    case tag
    of 0, 1:
      cell.codepoint = uint32(cellField(raw, layout.codepoint))
      cell.grapheme = tag == 1
    of 2:
      cell.hasBackground = true
      cell.paletteBackground = true
      cell.background.r = uint8(cellField(raw, layout.paletteIndex))
    of 3:
      cell.hasBackground = true
      cell.background = RGB(
        r: uint8(cellField(raw, layout.red)),
        g: uint8(cellField(raw, layout.green)),
        b: uint8(cellField(raw, layout.blue)))
    else:
      raise newException(IOError, "libghostty-vt returned an unknown cell tag")
    result[index] = cell

proc ensureRowCells(state: GhosttyRenderState) =
  discard requireHandle(state)
  if not state.rowPositioned or state.rowIterator.isNil:
    raise newException(IOError, "cell data requested without a current row")
  if state.rowCellsHandle.isNil:
    raise newException(IOError, "render-state row cells are closed")
  if state.rowCellsReady:
    return
  let status = cast[RowGetProc](requiredSymbol(state.library,
    "ghostty_render_state_row_get"))(state.rowIterator, rowDataCells,
      addr state.rowCellsHandle)
  checkResult("render-state row cells", status)
  if state.rowCellsHandle.isNil:
    raise newException(IOError,
      "libghostty-vt populated row cells without a handle")
  state.rowCellsReady = true

proc selectCell(state: GhosttyRenderState; x: int) =
  ensureRowCells(state)
  if x < 0 or x > high(uint16).int:
    raise newException(ValueError, "terminal cell column is out of range")
  let select = cast[RowCellsSelectProc](requiredSymbol(state.library,
    "ghostty_render_state_row_cells_select"))
  checkResult("cell selection", select(state.rowCellsHandle, uint16(x)))

proc styleColor(value: FfiStyleColor): RenderColor =
  case value.tag
  of 0:
    result.kind = renderColorNone
  of 1:
    result.kind = renderColorPalette
    result.paletteIndex = value.value[0]
  of 2:
    result.kind = renderColorRgb
    result.rgb = RGB(r: value.value[0], g: value.value[1], b: value.value[2])
  else:
    raise newException(IOError, "libghostty-vt returned an unknown style color")

proc cellStyle*(state: GhosttyRenderState; x: int): RenderStyle =
  ## Returns the style of a cell in the current row.
  state.selectCell(x)
  var value = FfiStyle(size: csize_t(sizeof(FfiStyle)))
  let getData = cast[RowCellsGetProc](requiredSymbol(state.library,
    "ghostty_render_state_row_cells_get"))
  checkResult("cell style query",
    getData(state.rowCellsHandle, cellDataStyle, addr value))
  result.foreground = styleColor(value.foreground)
  result.background = styleColor(value.background)
  result.underlineColor = styleColor(value.underlineColor)
  result.bold = value.bold
  result.italic = value.italic
  result.faint = value.faint
  result.blink = value.blink
  result.inverse = value.inverse
  result.invisible = value.invisible
  result.strikethrough = value.strikethrough
  result.overline = value.overline
  result.underline = int(value.underline)

proc cellGraphemes*(state: GhosttyRenderState; x: int): seq[uint32] =
  ## Returns the base codepoint and any additional codepoints for a cell.
  state.selectCell(x)
  let getData = cast[RowCellsGetProc](requiredSymbol(state.library,
    "ghostty_render_state_row_cells_get"))
  var count: uint32
  checkResult("cell grapheme length query",
    getData(state.rowCellsHandle, cellDataGraphemesLen, addr count))
  if count == 0:
    return
  if uint64(count) > 16'u64 * 1024 * 1024:
    raise newException(IOError, "libghostty-vt returned an oversized grapheme")
  result = newSeq[uint32](int(count))
  checkResult("cell grapheme query",
    getData(state.rowCellsHandle, cellDataGraphemesBuf, addr result[0]))
