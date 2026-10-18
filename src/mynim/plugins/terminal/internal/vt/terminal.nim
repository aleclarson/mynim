## Basic lifecycle and state access for a Ghostty virtual terminal.
##
## Calls on a terminal must be serialized, and its GhosttyVT library must
## remain loaded until after close().

import std/options
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
  TerminalString {.bycopy.} = object
    data: pointer
    length: csize_t
  TerminalModeConfig {.bycopy.} = object
    mode: uint16
    value: bool
  TerminalScrollbar* {.bycopy.} = object
    total*, offset*, len*: uint64
  ScrollViewport {.bycopy.} = object
    tag: int32
    padding: int32
    value: array[2, uint64]
  TerminalColor* {.bycopy.} = object
    r*, g*, b*: uint8
  TerminalPalette* = array[256, TerminalColor]

  GhosttyTerminal* = ref object
    library: GhosttyVT
    handle: pointer
  TerminalMode* = distinct uint16
  CursorStyle* = enum
    cursorStyleBar = 0
    cursorStyleBlock = 1
    cursorStyleUnderline = 2
    cursorStyleBlockHollow = 3

const
  success: GhosttyResult = 0
  dataColumns = 1'i32
  dataRows = 2'i32
  dataCursorX = 3'i32
  dataCursorY = 4'i32
  dataActiveScreen = 6'i32
  dataScrollbar = 9'i32
  dataMouseTracking = 11'i32
  dataTitle = 12'i32
  dataPwd = 13'i32
  dataViewportActive = 32'i32
  dataMode = 37'i32
  dataScrollbackMaxBytes = 34'i32
  optionTerminfoName = 37'i32
  optionDefaultCursorStyle = 22'i32
  optionDefaultCursorBlink = 23'i32
  optionScrollbackMaxBytes = 27'i32
  optionModeDefault = 33'i32
  optionMode = 34'i32
  optionResizePullScrollback = 40'i32
  optionColorForeground = 11'i32
  optionColorBackground = 12'i32
  optionColorCursor = 13'i32
  optionColorPalette = 14'i32
  modeAnsiMask = 0x8000'u16

  modeCursorKeys* = TerminalMode(1)
  modeCursorVisible* = TerminalMode(25)
  modeFocusEvent* = TerminalMode(1004)
  modeAltScroll* = TerminalMode(1007)
  modeBracketedPaste* = TerminalMode(2004)
  modeSyncOutput* = TerminalMode(2026)
  modeGraphemes* = TerminalMode(2027)
  modePasteEvents* = TerminalMode(5522)

type
  TerminalSetProc = proc(terminal: pointer; option: int32;
    value: pointer): GhosttyResult {.cdecl.}

static:
  doAssert sizeof(TerminalString) == 2 * sizeof(pointer)
  doAssert offsetOf(TerminalString, data) == 0
  doAssert offsetOf(TerminalString, length) == sizeof(pointer)
  doAssert sizeof(TerminalModeConfig) == 4
  doAssert offsetOf(TerminalModeConfig, mode) == 0
  doAssert offsetOf(TerminalModeConfig, value) == 2
  doAssert sizeof(TerminalScrollbar) == 3 * sizeof(uint64)
  doAssert offsetOf(TerminalScrollbar, offset) == sizeof(uint64)
  doAssert offsetOf(TerminalScrollbar, len) == 2 * sizeof(uint64)
  doAssert sizeof(ScrollViewport) == 24
  doAssert offsetOf(ScrollViewport, value) == 8
  doAssert sizeof(TerminalColor) == 3
  doAssert offsetOf(TerminalColor, r) == 0
  doAssert offsetOf(TerminalColor, g) == 1
  doAssert offsetOf(TerminalColor, b) == 2

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

proc ghosttyLibrary*(terminal: GhosttyTerminal): GhosttyVT =
  ## Returns the library backing an open terminal.
  discard requireHandle(terminal)
  terminal.library

proc setOption(terminal: GhosttyTerminal; option: int32; value: pointer;
               operation: string) =
  let handle = requireHandle(terminal)
  let setData = cast[TerminalSetProc](requiredSymbol(terminal.library,
    "ghostty_terminal_set"))
  checkResult(operation, setData(handle, option, value))

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

proc scrollbar*(terminal: GhosttyTerminal): TerminalScrollbar =
  ## Returns total scrollback rows, the viewport offset, and visible rows.
  let handle = requireHandle(terminal)
  let getData = cast[TerminalGetProc](requiredSymbol(terminal.library,
    "ghostty_terminal_get"))
  checkResult("scrollbar query", getData(handle, dataScrollbar, addr result))

proc activeScreen*(terminal: GhosttyTerminal): bool =
  ## Reports whether the alternate screen is active.
  let handle = requireHandle(terminal)
  var active: int32
  let getData = cast[TerminalGetProc](requiredSymbol(terminal.library,
    "ghostty_terminal_get"))
  getData(handle, dataActiveScreen, addr active) == success and active == 1

proc viewportActive*(terminal: GhosttyTerminal): bool =
  ## Reports whether the viewport follows the active screen.
  let handle = requireHandle(terminal)
  var active: bool
  let getData = cast[TerminalGetProc](requiredSymbol(terminal.library,
    "ghostty_terminal_get"))
  getData(handle, dataViewportActive, addr active) != success or active

proc scrollViewport(terminal: GhosttyTerminal; tag: int32;
                    value = [0'u64, 0'u64]) =
  let handle = requireHandle(terminal)
  let scroll = cast[proc(terminal: pointer; viewport: ScrollViewport) {.cdecl.}](
    requiredSymbol(terminal.library, "ghostty_terminal_scroll_viewport"))
  scroll(handle, ScrollViewport(tag: tag, value: value))

proc scrollBy*(terminal: GhosttyTerminal; rows: int) =
  ## Moves the viewport by rows; negative values scroll toward history.
  terminal.scrollViewport(2, [uint64(cast[int64](rows)), 0'u64])

proc scrollToBottom*(terminal: GhosttyTerminal) =
  ## Returns the viewport to the active screen.
  terminal.scrollViewport(1)

proc cursor*(terminal: GhosttyTerminal): tuple[x, y: int] =
  ## Returns the cursor column and row, both zero-based.
  (getUint16(terminal, dataCursorX), getUint16(terminal, dataCursorY))

proc getString(terminal: GhosttyTerminal; key: int32): string =
  let handle = requireHandle(terminal)
  let getData = cast[TerminalGetProc](requiredSymbol(terminal.library,
    "ghostty_terminal_get"))
  var value: TerminalString
  checkResult("terminal query", getData(handle, key, addr value))
  if value.length > csize_t(high(int)):
    raise newException(IOError,
      "libghostty-vt returned an unrepresentable terminal string")
  if value.length == 0:
    return ""
  if value.data.isNil:
    raise newException(IOError,
      "libghostty-vt returned a terminal string without data")
  result = newString(int(value.length))
  copyMem(addr result[0], value.data, int(value.length))

proc title*(terminal: GhosttyTerminal): string =
  ## Returns the current terminal title as the program supplied it.
  getString(terminal, dataTitle)

proc pwd*(terminal: GhosttyTerminal): string =
  ## Returns the current working directory reported by the running program.
  getString(terminal, dataPwd)

proc setTerminfoName*(terminal: GhosttyTerminal; name: string) =
  ## Sets the terminfo name returned by XTGETTCAP for TN.
  var value = TerminalString(length: csize_t(name.len))
  if name.len > 0:
    value.data = cast[pointer](unsafeAddr name[0])
  terminal.setOption(optionTerminfoName, addr value, "setting terminfo name")

proc setScrollbackMaxBytes*(terminal: GhosttyTerminal; maxBytes: int) =
  ## Sets the approximate scrollback byte limit; zero disables scrollback.
  if maxBytes < 0 or uint64(maxBytes) > uint64(high(csize_t)):
    raise newException(ValueError, "terminal scrollback limit is out of range")
  var value = csize_t(maxBytes)
  terminal.setOption(optionScrollbackMaxBytes, addr value,
    "setting scrollback limit")

proc scrollbackMaxBytes*(terminal: GhosttyTerminal): uint64 =
  ## Returns the configured approximate scrollback byte limit.
  let handle = requireHandle(terminal)
  var value: csize_t
  let getData = cast[TerminalGetProc](requiredSymbol(terminal.library,
    "ghostty_terminal_get"))
  checkResult("scrollback query", getData(handle, dataScrollbackMaxBytes,
    addr value))
  uint64(value)

proc setDefaultCursor*(terminal: GhosttyTerminal; style: CursorStyle;
                       blink: bool) =
  ## Sets the style and blink setting restored by DECSCUSR 0.
  var rawStyle = int32(ord(style))
  var rawBlink = blink
  terminal.setOption(optionDefaultCursorStyle, addr rawStyle,
    "setting default cursor style")
  terminal.setOption(optionDefaultCursorBlink, addr rawBlink,
    "setting default cursor blink")

proc setMode*(terminal: GhosttyTerminal; mode: TerminalMode; value: bool) =
  ## Sets a terminal mode without changing its reset default.
  var config = TerminalModeConfig(mode: uint16(mode), value: value)
  terminal.setOption(optionMode, addr config, "setting terminal mode")

proc setModeDefault*(terminal: GhosttyTerminal; mode: TerminalMode;
                     value: bool) =
  ## Sets a mode and the value restored by a full reset.
  var config = TerminalModeConfig(mode: uint16(mode), value: value)
  terminal.setOption(optionModeDefault, addr config,
    "setting terminal mode default")

proc mode*(terminal: GhosttyTerminal; mode: TerminalMode): bool =
  ## Reports whether a terminal mode is currently active.
  let handle = requireHandle(terminal)
  var config = TerminalModeConfig(mode: uint16(mode))
  let getData = cast[TerminalGetProc](requiredSymbol(terminal.library,
    "ghostty_terminal_get"))
  checkResult("terminal mode query", getData(handle, dataMode, addr config))
  config.value

proc mouseTracking*(terminal: GhosttyTerminal): bool =
  ## Reports whether the terminal has enabled mouse tracking.
  let handle = requireHandle(terminal)
  var value: bool
  let getData = cast[TerminalGetProc](requiredSymbol(terminal.library,
    "ghostty_terminal_get"))
  getData(handle, dataMouseTracking, addr value) == success and value

proc setResizePullScrollback*(terminal: GhosttyTerminal; enabled: bool) =
  ## Controls whether a larger screen pulls rows back from scrollback.
  var value = enabled
  terminal.setOption(optionResizePullScrollback, addr value,
    "setting scrollback resize behavior")

proc ansiMode*(value: int): TerminalMode =
  ## Packs a standard ANSI mode number into Ghostty's 16-bit mode value.
  if value < 0 or value > 0x7FFF:
    raise newException(ValueError, "ANSI terminal mode is out of range")
  TerminalMode(uint16(value) or modeAnsiMask)

proc setColors*(terminal: GhosttyTerminal; foreground, background: TerminalColor;
                cursor = none(TerminalColor);
                palette = none(TerminalPalette)) =
  ## Sets default colors and palette entries; absent optional values reset them.
  var foregroundValue = foreground
  var backgroundValue = background
  terminal.setOption(optionColorForeground, addr foregroundValue,
    "setting foreground color")
  terminal.setOption(optionColorBackground, addr backgroundValue,
    "setting background color")
  if cursor.isSome:
    var cursorValue = cursor.get()
    terminal.setOption(optionColorCursor, addr cursorValue,
      "setting cursor color")
  else:
    terminal.setOption(optionColorCursor, nil, "clearing cursor color")
  if palette.isSome:
    var paletteValue = palette.get()
    terminal.setOption(optionColorPalette, addr paletteValue[0],
      "setting terminal palette")
  else:
    terminal.setOption(optionColorPalette, nil, "resetting terminal palette")
