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

proc snapshotCurrent*(state: GhosttyRenderState): TerminalFrame =
  ## Copies the already-updated render state into Nim-owned data.
  ## Calls that mutate or read the render state must be serialized.
  let (cols, rows) = state.size()
  result.cols = cols
  result.rows = rows
  result.dirty = state.dirty()
  result.cursor = state.cursor()
  result.colors = state.colors()
  result.viewport = newSeqOfCap[TerminalFrameRow](rows)
  var styles = initTable[uint16, RenderStyle]()

  state.rows()
  while state.nextRow():
    var row = TerminalFrameRow(
      viewportY: state.rowViewportY(),
      dirty: state.rowDirty(),
      selection: state.rowSelection(),
      id: state.rowId())
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
               terminal: GhosttyTerminal): TerminalFrame =
  ## Updates render state and copies every viewport row into Nim-owned data.
  state.update(terminal)
  state.snapshotCurrent()
