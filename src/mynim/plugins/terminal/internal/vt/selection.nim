## Terminal text selection and pointer gesture bindings for Ghostty.

import std/options
import ./[library, terminal]

type
  GhosttyGridRef* {.bycopy.} = object
    size: csize_t
    node: pointer
    x*, y*: uint16

  GhosttySelection* {.bycopy.} = object
    size: csize_t
    start*, finish*: GhosttyGridRef
    rectangle: bool

  GhosttySelectionGesture* = ref object
    library: GhosttyVT
    handle: pointer
    pressEvent, releaseEvent, dragEvent, tickEvent: pointer

  GhosttyPointCoordinate {.bycopy.} = object
    x: uint16
    padding: uint16
    y: uint32

  GhosttyPointValue {.bycopy.} = object
    words: array[2, uint64]

  GhosttyPoint {.bycopy.} = object
    tag: int32
    value: GhosttyPointValue

  GhosttySurfacePosition {.bycopy.} = object
    x, y: float64

  GhosttySelectionGeometry {.bycopy.} = object
    columns, cellWidth, paddingLeft, screenHeight: uint32

  GhosttySelectionFormatOptions {.bycopy.} = object
    size: csize_t
    format: int32
    unwrap, trim: bool
    selection: ptr GhosttySelection

  GhosttyResult = int32
  GestureNewProc = proc(allocator: pointer; handle: ptr pointer):
    GhosttyResult {.cdecl.}
  GestureFreeProc = proc(gesture, terminal: pointer) {.cdecl.}
  GestureResetProc = proc(gesture, terminal: pointer) {.cdecl.}
  GestureEventNewProc = proc(allocator: pointer; event: ptr pointer;
    eventType: int32): GhosttyResult {.cdecl.}
  GestureEventFreeProc = proc(event: pointer) {.cdecl.}
  GestureEventSetProc = proc(event: pointer; option: int32;
    value: pointer): GhosttyResult {.cdecl.}
  GestureEventProc = proc(gesture, terminal, event: pointer;
    selection: ptr GhosttySelection): GhosttyResult {.cdecl.}
  GestureGetProc = proc(gesture, terminal: pointer; data: int32;
    value: pointer): GhosttyResult {.cdecl.}
  TerminalGridRefProc = proc(terminal: pointer; point: GhosttyPoint;
    reference: ptr GhosttyGridRef): GhosttyResult {.cdecl.}
  TerminalSelectAllProc = proc(terminal: pointer;
    selection: ptr GhosttySelection): GhosttyResult {.cdecl.}
  TerminalSelectionFormatProc = proc(terminal, allocator: pointer;
    options: GhosttySelectionFormatOptions; output: ptr pointer;
    length: ptr csize_t): GhosttyResult {.cdecl.}
  TerminalSetProc = proc(terminal: pointer; option: int32;
    value: pointer): GhosttyResult {.cdecl.}
  GhosttyFreeProc = proc(allocator, data: pointer; length: csize_t) {.cdecl.}

const
  success: GhosttyResult = 0
  noValue: GhosttyResult = -4
  gesturePress = 0'i32
  gestureRelease = 1'i32
  gestureDrag = 2'i32
  gestureTick = 3'i32
  gestureOptionRef = 0'i32
  gestureOptionPosition = 1'i32
  gestureOptionRepeatDistance = 2'i32
  gestureOptionRepeatInterval = 4'i32
  gestureOptionRectangle = 7'i32
  gestureOptionGeometry = 8'i32
  gestureOptionViewport = 9'i32
  gestureDataAutoscroll = 2'i32
  terminalOptionSelection = 21'i32
  pointViewport = 1'i32

static:
  doAssert sizeof(GhosttyGridRef) == 24
  doAssert offsetOf(GhosttyGridRef, node) == 8
  doAssert offsetOf(GhosttyGridRef, x) == 16
  doAssert sizeof(GhosttySelection) == 64
  doAssert offsetOf(GhosttySelection, start) == 8
  doAssert offsetOf(GhosttySelection, finish) == 32
  doAssert offsetOf(GhosttySelection, rectangle) == 56
  doAssert sizeof(GhosttyPointCoordinate) == 8
  doAssert sizeof(GhosttyPoint) == 24
  doAssert sizeof(GhosttySurfacePosition) == 16
  doAssert sizeof(GhosttySelectionGeometry) == 16
  doAssert sizeof(GhosttySelectionFormatOptions) == 24
  doAssert offsetOf(GhosttySelectionFormatOptions, selection) == 16

proc requiredSymbol(library: GhosttyVT; name: string): pointer =
  result = library.symbol(name)
  if result.isNil:
    raise newException(IOError, "libghostty-vt is missing " & name)

proc checkResult(operation: string; status: GhosttyResult) =
  if status != success:
    raise newException(IOError,
      "libghostty-vt " & operation & " failed with result " & $status)

proc rawHandle(gesture: GhosttySelectionGesture): pointer =
  if gesture.isNil or gesture.handle.isNil:
    raise newException(IOError, "terminal selection gesture is closed")
  gesture.handle

proc makeEvent(gesture: GhosttySelectionGesture; eventType: int32): pointer =
  let create = cast[GestureEventNewProc](requiredSymbol(gesture.library,
    "ghostty_selection_gesture_event_new"))
  checkResult("selection event creation", create(nil, addr result, eventType))
  if result.isNil:
    raise newException(IOError,
      "libghostty-vt created a selection event without a handle")

proc setEvent(gesture: GhosttySelectionGesture; event: pointer;
              option: int32; value: pointer) =
  let set = cast[GestureEventSetProc](requiredSymbol(gesture.library,
    "ghostty_selection_gesture_event_set"))
  checkResult("selection event update", set(event, option, value))

proc applyEvent(gesture: GhosttySelectionGesture;
                terminal: GhosttyTerminal; event: pointer): Option[GhosttySelection] =
  var selection = GhosttySelection(size: csize_t(sizeof(GhosttySelection)))
  let apply = cast[GestureEventProc](requiredSymbol(gesture.library,
    "ghostty_selection_gesture_event"))
  let status = apply(gesture.rawHandle(), terminal.rawHandle(), event,
    addr selection)
  if status == success:
    return some(selection)
  if status != noValue:
    checkResult("selection gesture", status)

proc close*(gesture: GhosttySelectionGesture; terminal: GhosttyTerminal)

proc newGhosttySelectionGesture*(library: GhosttyVT;
    repeatIntervalNs = 500_000_000'u64;
    repeatDistance = 5.0): GhosttySelectionGesture =
  ## Creates a reusable click and drag selection state machine.
  if library.isNil:
    raise newException(ValueError, "selection Ghostty library is nil")
  new(result)
  result.library = library
  let create = cast[GestureNewProc](requiredSymbol(library,
    "ghostty_selection_gesture_new"))
  checkResult("selection gesture creation", create(nil, addr result.handle))
  if result.handle.isNil:
    raise newException(IOError,
      "libghostty-vt created a selection gesture without a handle")
  try:
    result.pressEvent = result.makeEvent(gesturePress)
    result.releaseEvent = result.makeEvent(gestureRelease)
    result.dragEvent = result.makeEvent(gestureDrag)
    result.tickEvent = result.makeEvent(gestureTick)
    result.setEvent(result.pressEvent, gestureOptionRepeatInterval,
      cast[pointer](unsafeAddr repeatIntervalNs))
    result.setEvent(result.pressEvent, gestureOptionRepeatDistance,
      cast[pointer](unsafeAddr repeatDistance))
  except CatchableError:
    result.close(nil)
    raise

proc close*(gesture: GhosttySelectionGesture; terminal: GhosttyTerminal) =
  ## Frees gesture references before their owning terminal is released.
  if gesture.isNil:
    return
  let freeEvent = cast[GestureEventFreeProc](requiredSymbol(gesture.library,
    "ghostty_selection_gesture_event_free"))
  for event in [gesture.pressEvent, gesture.releaseEvent,
                gesture.dragEvent, gesture.tickEvent]:
    if not event.isNil:
      freeEvent(event)
  if not gesture.handle.isNil:
    let free = cast[GestureFreeProc](requiredSymbol(gesture.library,
      "ghostty_selection_gesture_free"))
    free(gesture.handle,
      if terminal.isNil: nil else: terminal.rawHandle())
  gesture.handle = nil
  gesture.pressEvent = nil
  gesture.releaseEvent = nil
  gesture.dragEvent = nil
  gesture.tickEvent = nil

proc reset*(gesture: GhosttySelectionGesture; terminal: GhosttyTerminal) =
  ## Clears the active click sequence while keeping the gesture reusable.
  let reset = cast[GestureResetProc](requiredSymbol(gesture.library,
    "ghostty_selection_gesture_reset"))
  reset(gesture.rawHandle(), terminal.rawHandle())

proc cellAt*(terminal: GhosttyTerminal; column, row: int):
    Option[GhosttyGridRef] =
  ## Returns a snapshot of one cell in the visible viewport.
  var point = GhosttyPoint(tag: pointViewport)
  let coordinate = GhosttyPointCoordinate(
    x: uint16(max(0, min(column, high(uint16).int))),
    y: uint32(max(row, 0)))
  copyMem(addr point.value.words[0], unsafeAddr coordinate,
    sizeof(coordinate))
  var reference = GhosttyGridRef(size: csize_t(sizeof(GhosttyGridRef)))
  let getRef = cast[TerminalGridRefProc](requiredSymbol(
    terminal.ghosttyLibrary(), "ghostty_terminal_grid_ref"))
  let status = getRef(terminal.rawHandle(), point, addr reference)
  if status == success:
    return some(reference)
  if status != noValue:
    checkResult("cell reference query", status)

proc press*(gesture: GhosttySelectionGesture; terminal: GhosttyTerminal;
            reference: GhosttyGridRef; x, y: float64;
            timeNs: uint64; repeatDistance = 5.0): Option[GhosttySelection] =
  ## Starts a cell, word, or line selection according to click timing.
  var position = GhosttySurfacePosition(x: x, y: y)
  var distance = repeatDistance
  gesture.setEvent(gesture.pressEvent, gestureOptionRef,
    cast[pointer](addr reference))
  gesture.setEvent(gesture.pressEvent, gestureOptionPosition,
    cast[pointer](addr position))
  gesture.setEvent(gesture.pressEvent, gestureOptionRepeatDistance,
    cast[pointer](addr distance))
  gesture.setEvent(gesture.pressEvent, 3'i32, cast[pointer](unsafeAddr timeNs))
  gesture.applyEvent(terminal, gesture.pressEvent)

proc drag*(gesture: GhosttySelectionGesture; terminal: GhosttyTerminal;
           reference: GhosttyGridRef; x, y: float64; columns, cellWidth,
           paddingLeft, screenHeight: int; rectangle = false):
    Option[GhosttySelection] =
  ## Extends the current selection through the specified cell.
  var position = GhosttySurfacePosition(x: x, y: y)
  var geometry = GhosttySelectionGeometry(
    columns: uint32(max(columns, 1)), cellWidth: uint32(max(cellWidth, 1)),
    paddingLeft: uint32(max(paddingLeft, 0)),
    screenHeight: uint32(max(screenHeight, 1)))
  var isRectangle = rectangle
  gesture.setEvent(gesture.dragEvent, gestureOptionRef,
    cast[pointer](addr reference))
  gesture.setEvent(gesture.dragEvent, gestureOptionPosition,
    cast[pointer](addr position))
  gesture.setEvent(gesture.dragEvent, gestureOptionGeometry,
    cast[pointer](addr geometry))
  gesture.setEvent(gesture.dragEvent, gestureOptionRectangle,
    cast[pointer](addr isRectangle))
  gesture.applyEvent(terminal, gesture.dragEvent)

proc release*(gesture: GhosttySelectionGesture; terminal: GhosttyTerminal;
              reference: Option[GhosttyGridRef]) =
  ## Ends a selection gesture over a cell or outside the grid.
  if reference.isSome:
    var value = reference.get()
    gesture.setEvent(gesture.releaseEvent, gestureOptionRef,
      cast[pointer](addr value))
  else:
    gesture.setEvent(gesture.releaseEvent, gestureOptionRef, nil)
  discard gesture.applyEvent(terminal, gesture.releaseEvent)

proc autoscroll*(gesture: GhosttySelectionGesture;
                 terminal: GhosttyTerminal): int =
  ## Returns -1, 0, or 1 according to the gesture's autoscroll request.
  var direction: int32
  let get = cast[GestureGetProc](requiredSymbol(gesture.library,
    "ghostty_selection_gesture_get"))
  if get(gesture.rawHandle(), terminal.rawHandle(), gestureDataAutoscroll,
      addr direction) == success:
    result = case direction
      of 1: -1
      of 2: 1
      else: 0

proc autoscrollTick*(gesture: GhosttySelectionGesture;
    terminal: GhosttyTerminal; column, row: int; x, y: float64;
    columns, cellWidth, paddingLeft, screenHeight: int;
    rectangle = false): Option[GhosttySelection] =
  ## Continues a selection drag after the viewport has scrolled.
  var position = GhosttySurfacePosition(x: x, y: y)
  var geometry = GhosttySelectionGeometry(
    columns: uint32(max(columns, 1)), cellWidth: uint32(max(cellWidth, 1)),
    paddingLeft: uint32(max(paddingLeft, 0)),
    screenHeight: uint32(max(screenHeight, 1)))
  var viewport = GhosttyPointCoordinate(
    x: uint16(max(0, min(column, high(uint16).int))),
    y: uint32(max(row, 0)))
  var isRectangle = rectangle
  gesture.setEvent(gesture.tickEvent, gestureOptionPosition,
    cast[pointer](addr position))
  gesture.setEvent(gesture.tickEvent, gestureOptionGeometry,
    cast[pointer](addr geometry))
  gesture.setEvent(gesture.tickEvent, gestureOptionViewport,
    cast[pointer](addr viewport))
  gesture.setEvent(gesture.tickEvent, gestureOptionRectangle,
    cast[pointer](addr isRectangle))
  gesture.applyEvent(terminal, gesture.tickEvent)

proc setSelection*(terminal: GhosttyTerminal;
                   selection: Option[GhosttySelection]) =
  ## Installs a selection snapshot, or clears the terminal's current selection.
  let set = cast[TerminalSetProc](requiredSymbol(terminal.ghosttyLibrary(),
    "ghostty_terminal_set"))
  if selection.isSome:
    var value = selection.get()
    checkResult("selection update", set(terminal.rawHandle(),
      terminalOptionSelection, addr value))
  else:
    checkResult("selection clear", set(terminal.rawHandle(),
      terminalOptionSelection, nil))

proc selectAll*(terminal: GhosttyTerminal): Option[GhosttySelection] =
  ## Returns a selection snapshot covering the active screen and scrollback.
  var selection = GhosttySelection(size: csize_t(sizeof(GhosttySelection)))
  let selectAll = cast[TerminalSelectAllProc](requiredSymbol(
    terminal.ghosttyLibrary(), "ghostty_terminal_select_all"))
  let status = selectAll(terminal.rawHandle(), addr selection)
  if status == success:
    return some(selection)
  if status != noValue:
    checkResult("select all", status)

proc selectedText*(terminal: GhosttyTerminal): Option[string] =
  ## Formats the active selection as copied plain text.
  var output: pointer
  var length: csize_t
  let options = GhosttySelectionFormatOptions(
    size: csize_t(sizeof(GhosttySelectionFormatOptions)),
    format: 0, unwrap: true, trim: true)
  let format = cast[TerminalSelectionFormatProc](requiredSymbol(
    terminal.ghosttyLibrary(), "ghostty_terminal_selection_format_alloc"))
  let status = format(terminal.rawHandle(), nil, options, addr output,
    addr length)
  if status != success:
    if status == noValue:
      return none(string)
    checkResult("selection formatting", status)
  try:
    if output.isNil or length == 0:
      return some("")
    if uint64(length) > uint64(high(int)):
      raise newException(IOError, "terminal selection is too large")
    result = some(newString(int(length)))
    copyMem(addr result.get()[0], output, int(length))
  finally:
    if not output.isNil:
      let free = cast[GhosttyFreeProc](requiredSymbol(
        terminal.ghosttyLibrary(), "ghostty_free"))
      free(nil, output, length)
