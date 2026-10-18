## Owned viewport snapshots for native terminal renderers.

import std/[options, tables]
import ./[render, terminal]

type
  TerminalFrameCell* = object
    cell*: RenderCell
    codepoints*: seq[uint32]
    style*: RenderStyle
  TerminalFrameRow* = object
    viewportY*: int
    dirty*: bool
    selection*: Option[RowSelection]
    id*: RowID
    cells*: seq[TerminalFrameCell]
  TerminalFrame* = object
    cols*, rows*: int
    dirty*: RenderDirty
    cursor*: RenderCursor
    colors*: RenderColors
    viewport*: seq[TerminalFrameRow]

proc cachedRow(rows: openArray[TerminalFrameRow]; id: RowID): int =
  for index, row in rows:
    if row.id.bits == id.bits:
      return index
  -1

proc snapshotCurrent*(state: GhosttyRenderState;
                      previous: openArray[TerminalFrameRow] = []):
    TerminalFrame =
  ## Copies changed rows and reuses immutable snapshots of unchanged row IDs.
  ## Calls that mutate or read the render state must be serialized.
  let (cols, rows) = state.size()
  result.cols = cols
  result.rows = rows
  result.dirty = state.dirty()
  result.cursor = state.cursor()
  result.colors = state.colors()
  result.viewport = newSeqOfCap[TerminalFrameRow](rows)
  var styles = initTable[uint16, RenderStyle]()
  let full = result.dirty == renderFull

  state.rows()
  while state.nextRow():
    let id = state.rowId()
    let viewportY = state.rowViewportY()
    let dirty = state.rowDirty()
    let selection = state.rowSelection()
    let cached = if full or dirty: -1 else: previous.cachedRow(id)
    var row: TerminalFrameRow
    if cached >= 0 and previous[cached].selection == selection:
      row = previous[cached]
      row.viewportY = viewportY
      row.dirty = false
    else:
      row = TerminalFrameRow(
        viewportY: viewportY,
        dirty: dirty,
        selection: selection,
        id: id)
      let cells = state.rowCells()
      row.cells = newSeq[TerminalFrameCell](cells.len)
      for x, cell in cells:
        var codepoints: seq[uint32]
        if cell.grapheme:
          codepoints = state.cellGraphemes(x)
        elif cell.codepoint != 0:
          codepoints = @[cell.codepoint]
        var style: RenderStyle
        if styles.hasKey(cell.styleId):
          style = styles[cell.styleId]
        else:
          style = state.cellStyle(x)
          styles[cell.styleId] = style
        row.cells[x] = TerminalFrameCell(
          cell: cell, codepoints: move(codepoints), style: style)
    result.viewport.add(move(row))

proc snapshot*(state: GhosttyRenderState;
               terminal: GhosttyTerminal;
               previous: openArray[TerminalFrameRow] = []): TerminalFrame =
  ## Updates render state and copies changed rows into Nim-owned data.
  state.update(terminal)
  state.snapshotCurrent(previous)
