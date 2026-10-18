## Basic lifecycle and state access for a Ghostty virtual terminal.
##
## Calls on a terminal must be serialized, and its GhosttyVT library must
## remain loaded until after close().

import ./library

type
  GhosttyResult = int32
  TerminalNewProc = proc(allocator: pointer; terminal: ptr pointer;
    cols, rows: uint16): GhosttyResult {.cdecl.}
  TerminalFreeProc = proc(terminal: pointer) {.cdecl.}
  TerminalResetProc = proc(terminal: pointer) {.cdecl.}
  TerminalResizeProc = proc(terminal: pointer; cols, rows: uint16;
    cellWidth, cellHeight: uint32): GhosttyResult {.cdecl.}
  TerminalWriteProc = proc(terminal: pointer; data: ptr UncheckedArray[byte];
    length: csize_t) {.cdecl.}
  TerminalGetProc = proc(terminal: pointer; data: int32;
    value: pointer): GhosttyResult {.cdecl.}

  GhosttyTerminal* = ref object
    library: GhosttyVT
    handle: pointer

const
  success: GhosttyResult = 0
  dataColumns = 1'i32
  dataRows = 2'i32
  dataCursorX = 3'i32
  dataCursorY = 4'i32

proc requiredSymbol(library: GhosttyVT; name: string): pointer =
  result = library.symbol(name)
  if result.isNil:
    raise newException(IOError, "libghostty-vt is missing " & name)

proc checkResult(name: string; status: GhosttyResult) =
  if status != success:
    raise newException(IOError,
      "libghostty-vt " & name & " failed with result " & $status)

proc checkedDimension(value: int; label: string): uint16 =
  if value <= 0 or value > high(uint16).int:
    raise newException(ValueError,
      "terminal " & label & " must be between 1 and " & $high(uint16))
  uint16(value)

proc newGhosttyTerminal*(library: GhosttyVT; cols, rows: int): GhosttyTerminal =
  ## Creates an empty terminal with the given cell dimensions.
  let width = checkedDimension(cols, "columns")
  let height = checkedDimension(rows, "rows")
  if library.isNil:
    raise newException(ValueError, "terminal Ghostty library is nil")
  let create = cast[TerminalNewProc](requiredSymbol(library,
    "ghostty_terminal_new"))
  var handle: pointer
  checkResult("terminal creation", create(nil, addr handle, width, height))
  if handle.isNil:
    raise newException(IOError,
      "libghostty-vt created a terminal without a handle")
  new(result)
  result.library = library
  result.handle = handle

proc requireHandle(terminal: GhosttyTerminal): pointer =
  if terminal.isNil or terminal.handle.isNil:
    raise newException(IOError, "terminal is closed")
  terminal.handle

proc rawHandle*(terminal: GhosttyTerminal): pointer =
  ## Internal bridge for Ghostty APIs that consume this terminal handle.
  requireHandle(terminal)

proc belongsToLibrary*(terminal: GhosttyTerminal; library: GhosttyVT): bool =
  ## Checks that another Ghostty object can safely use this terminal.
  not terminal.isNil and terminal.library == library

proc close*(terminal: GhosttyTerminal) =
  ## Frees the Ghostty state; close it before unloading its library.
  if terminal.isNil or terminal.handle.isNil:
    return
  let free = cast[TerminalFreeProc](requiredSymbol(terminal.library,
    "ghostty_terminal_free"))
  let handle = terminal.handle
  terminal.handle = nil
  free(handle)

proc reset*(terminal: GhosttyTerminal) =
  ## Resets modes, scrollback and screen contents while keeping dimensions.
  let handle = requireHandle(terminal)
  let resetTerminal = cast[TerminalResetProc](requiredSymbol(
    terminal.library, "ghostty_terminal_reset"))
  resetTerminal(handle)

proc resize*(terminal: GhosttyTerminal; cols, rows: int;
             cellWidth = 1; cellHeight = 1) =
  ## Resizes the cell grid and the pixel dimensions of each cell.
  if cellWidth < 0 or cellWidth > high(uint32).int or
      cellHeight < 0 or cellHeight > high(uint32).int:
    raise newException(ValueError, "terminal cell pixel size is out of range")
  let handle = requireHandle(terminal)
  let resizeTerminal = cast[TerminalResizeProc](requiredSymbol(
    terminal.library, "ghostty_terminal_resize"))
  let status = resizeTerminal(handle,
    checkedDimension(cols, "columns"), checkedDimension(rows, "rows"),
    uint32(max(1, cellWidth)), uint32(max(1, cellHeight)))
  checkResult("resize", status)

proc write*(terminal: GhosttyTerminal; data: openArray[byte]) =
  ## Processes a chunk of VT output. An empty chunk is a no-op.
  let handle = requireHandle(terminal)
  if data.len == 0:
    return
  let writeData = cast[TerminalWriteProc](requiredSymbol(terminal.library,
    "ghostty_terminal_vt_write"))
  writeData(handle,
    cast[ptr UncheckedArray[byte]](unsafeAddr data[0]), csize_t(data.len))

proc write*(terminal: GhosttyTerminal; data: string) =
  ## Processes UTF-8 terminal output without copying its bytes.
  discard requireHandle(terminal)
  if data.len == 0:
    return
  terminal.write(data.toOpenArrayByte(0, data.high))

proc getUint16(terminal: GhosttyTerminal; key: int32): int =
  let handle = requireHandle(terminal)
  var value: uint16
  let getData = cast[TerminalGetProc](requiredSymbol(terminal.library,
    "ghostty_terminal_get"))
  let status = getData(handle, key, addr value)
  checkResult("terminal query", status)
  int(value)

proc size*(terminal: GhosttyTerminal): tuple[cols, rows: int] =
  ## Returns the active terminal's cell dimensions.
  (getUint16(terminal, dataColumns), getUint16(terminal, dataRows))

proc cursor*(terminal: GhosttyTerminal): tuple[x, y: int] =
  ## Returns the cursor column and row, both zero-based.
  (getUint16(terminal, dataCursorX), getUint16(terminal, dataCursorY))
