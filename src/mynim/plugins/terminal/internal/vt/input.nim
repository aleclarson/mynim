## Keyboard and pointer input encoders backed by libghostty-vt.
##
## Calls on an encoder must be serialized. Keep its GhosttyVT loaded until
## after close() and synchronize it again when terminal modes change.

import std/strformat
import ./[library, terminal]

type
  GhosttyResult = int32
  KeyAction* = enum
    keyRelease = 0
    keyPress = 1
    keyRepeat = 2
  Key* = distinct int32
  Mods* = distinct uint16
  KeyEvent* = object
    action*: KeyAction
    key*: Key
    mods*: Mods
    consumed*: Mods
    text*: string
    unshifted*: uint32
    composing*: bool
  MouseAction* = enum
    mousePress = 0
    mouseRelease = 1
    mouseMotion = 2
  MouseButton* = distinct int32
  MouseEncoderSize {.bycopy.} = object
    size: csize_t
    screenWidth, screenHeight: uint32
    cellWidth, cellHeight: uint32
    paddingTop, paddingBottom, paddingRight, paddingLeft: uint32
  MousePosition {.bycopy.} = object
    x, y: cfloat
  GhosttyKeyEncoder* = ref object
    library: GhosttyVT
    handle, event: pointer
  GhosttyMouseEncoder* = ref object
    library: GhosttyVT
    handle, event: pointer

const
  success: GhosttyResult = 0
  outOfSpace: GhosttyResult = -3
  modShift* = Mods(1 shl 0)
  modCtrl* = Mods(1 shl 1)
  modAlt* = Mods(1 shl 2)
  modSuper* = Mods(1 shl 3)
  modCapsLock* = Mods(1 shl 4)
  modNumLock* = Mods(1 shl 5)
  modShiftRight* = Mods(1 shl 6)
  modCtrlRight* = Mods(1 shl 7)
  modAltRight* = Mods(1 shl 8)
  modSuperRight* = Mods(1 shl 9)

  keyUnidentified* = Key(0)
  keyBackquote* = Key(1)
  keyBackslash* = Key(2)
  keyBracketLeft* = Key(3)
  keyBracketRight* = Key(4)
  keyComma* = Key(5)
  keyDigit0* = Key(6)
  keyDigit1* = Key(7)
  keyDigit2* = Key(8)
  keyDigit3* = Key(9)
  keyDigit4* = Key(10)
  keyDigit5* = Key(11)
  keyDigit6* = Key(12)
  keyDigit7* = Key(13)
  keyDigit8* = Key(14)
  keyDigit9* = Key(15)
  keyEqual* = Key(16)
  keyIntlBackslash* = Key(17)
  keyIntlRo* = Key(18)
  keyIntlYen* = Key(19)
  keyA* = Key(20)
  keyB* = Key(21)
  keyC* = Key(22)
  keyD* = Key(23)
  keyE* = Key(24)
  keyF* = Key(25)
  keyG* = Key(26)
  keyH* = Key(27)
  keyI* = Key(28)
  keyJ* = Key(29)
  keyK* = Key(30)
  keyL* = Key(31)
  keyM* = Key(32)
  keyN* = Key(33)
  keyO* = Key(34)
  keyP* = Key(35)
  keyQ* = Key(36)
  keyR* = Key(37)
  keyS* = Key(38)
  keyT* = Key(39)
  keyU* = Key(40)
  keyV* = Key(41)
  keyW* = Key(42)
  keyX* = Key(43)
  keyY* = Key(44)
  keyZ* = Key(45)
  keyMinus* = Key(46)
  keyPeriod* = Key(47)
  keyQuote* = Key(48)
  keySemicolon* = Key(49)
  keySlash* = Key(50)
  keyAltLeft* = Key(51)
  keyAltRight* = Key(52)
  keyBackspace* = Key(53)
  keyCapsLock* = Key(54)
  keyContextMenu* = Key(55)
  keyControlLeft* = Key(56)
  keyControlRight* = Key(57)
  keyEnter* = Key(58)
  keyMetaLeft* = Key(59)
  keyMetaRight* = Key(60)
  keyShiftLeft* = Key(61)
  keyShiftRight* = Key(62)
  keySpace* = Key(63)
  keyTab* = Key(64)
  keyConvert* = Key(65)
  keyKanaMode* = Key(66)
  keyNonConvert* = Key(67)
  keyDelete* = Key(68)
  keyEnd* = Key(69)
  keyHelp* = Key(70)
  keyHome* = Key(71)
  keyInsert* = Key(72)
  keyPageDown* = Key(73)
  keyPageUp* = Key(74)
  keyArrowDown* = Key(75)
  keyArrowLeft* = Key(76)
  keyArrowRight* = Key(77)
  keyArrowUp* = Key(78)
  keyEscape* = Key(120)
  keyF1* = Key(121)

  buttonNone* = MouseButton(0)
  buttonLeft* = MouseButton(1)
  buttonRight* = MouseButton(2)
  buttonMiddle* = MouseButton(3)
  wheelUp* = MouseButton(4)
  wheelDown* = MouseButton(5)
  wheelLeft* = MouseButton(6)
  wheelRight* = MouseButton(7)

type
  KeyEncoderNewProc = proc(allocator: pointer; encoder: ptr pointer):
    GhosttyResult {.cdecl.}
  KeyEventNewProc = proc(allocator: pointer; event: ptr pointer):
    GhosttyResult {.cdecl.}
  HandleFreeProc = proc(handle: pointer) {.cdecl.}
  KeySetActionProc = proc(event: pointer; action: int32) {.cdecl.}
  KeySetKeyProc = proc(event: pointer; key: int32) {.cdecl.}
  KeySetModsProc = proc(event: pointer; mods: uint16) {.cdecl.}
  KeySetBoolProc = proc(event: pointer; value: bool) {.cdecl.}
  KeySetUtf8Proc = proc(event, utf8: pointer; length: csize_t) {.cdecl.}
  KeySetCodepointProc = proc(event: pointer; codepoint: uint32) {.cdecl.}
  KeySyncProc = proc(encoder, terminal: pointer) {.cdecl.}
  KeySetOptionProc = proc(encoder: pointer; option: int32; value: pointer) {.cdecl.}
  KeyEncodeProc = proc(encoder, event: pointer; output: ptr UncheckedArray[byte];
    capacity: csize_t; written: ptr csize_t): GhosttyResult {.cdecl.}
  MouseEventNewProc = proc(allocator: pointer; event: ptr pointer):
    GhosttyResult {.cdecl.}
  MouseSetActionProc = proc(event: pointer; action: int32) {.cdecl.}
  MouseSetButtonProc = proc(event: pointer; button: int32) {.cdecl.}
  MouseClearButtonProc = proc(event: pointer) {.cdecl.}
  MouseSetModsProc = proc(event: pointer; mods: uint16) {.cdecl.}
  MouseSetPositionProc = proc(event: pointer; position: MousePosition) {.cdecl.}
  MouseSyncProc = proc(encoder, terminal: pointer) {.cdecl.}
  MouseSetOptionProc = proc(encoder: pointer; option: int32; value: pointer) {.cdecl.}
  MouseResetProc = proc(encoder: pointer) {.cdecl.}
  MouseEncodeProc = proc(encoder, event: pointer;
    output: ptr UncheckedArray[byte]; capacity: csize_t;
    written: ptr csize_t): GhosttyResult {.cdecl.}

static:
  doAssert sizeof(MousePosition) == 8
  doAssert offsetOf(MousePosition, x) == 0
  doAssert offsetOf(MousePosition, y) == 4
  doAssert sizeof(MouseEncoderSize) == 40
  doAssert offsetOf(MouseEncoderSize, screenWidth) == 8
  doAssert offsetOf(MouseEncoderSize, cellWidth) == 16
  doAssert offsetOf(MouseEncoderSize, paddingTop) == 24
  doAssert offsetOf(MouseEncoderSize, paddingLeft) == 36

proc `or`*(left, right: Mods): Mods {.borrow.}
proc `==`*(left, right: MouseButton): bool {.borrow.}
proc `==`*(left, right: Mods): bool {.borrow.}
proc `==`*(left, right: Key): bool {.borrow.}

proc requiredSymbol(library: GhosttyVT; name: string): pointer =
  result = library.symbol(name)
  if result.isNil:
    raise newException(IOError, "libghostty-vt is missing " & name)

proc checkResult(operation: string; status: GhosttyResult) =
  if status != success:
    raise newException(IOError,
      &"libghostty-vt {operation} failed with result {status}")

proc requiredSize(value: csize_t; label: string): int =
  if value > csize_t(high(int)):
    raise newException(IOError,
      "libghostty-vt requested an unrepresentable " & label & " buffer")
  int(value)

proc newGhosttyKeyEncoder*(library: GhosttyVT): GhosttyKeyEncoder =
  ## Creates a keyboard encoder and its reusable input event.
  if library.isNil:
    raise newException(ValueError, "key encoder Ghostty library is nil")
  let createEncoder = cast[KeyEncoderNewProc](requiredSymbol(library,
    "ghostty_key_encoder_new"))
  let createEvent = cast[KeyEventNewProc](requiredSymbol(library,
    "ghostty_key_event_new"))
  let freeEncoder = cast[HandleFreeProc](requiredSymbol(library,
    "ghostty_key_encoder_free"))
  var encoderHandle: pointer
  checkResult("key encoder creation", createEncoder(nil, addr encoderHandle))
  if encoderHandle.isNil:
    raise newException(IOError,
      "libghostty-vt created a key encoder without a handle")
  var eventHandle: pointer
  try:
    checkResult("key event creation", createEvent(nil, addr eventHandle))
  except CatchableError:
    freeEncoder(encoderHandle)
    raise
  if eventHandle.isNil:
    freeEncoder(encoderHandle)
    raise newException(IOError,
      "libghostty-vt created a key event without a handle")
  new(result)
  result.library = library
  result.handle = encoderHandle
  result.event = eventHandle

proc newGhosttyMouseEncoder*(library: GhosttyVT): GhosttyMouseEncoder =
  ## Creates a mouse encoder and enables motion deduplication by terminal cell.
  if library.isNil:
    raise newException(ValueError, "mouse encoder Ghostty library is nil")
  let createEncoder = cast[KeyEncoderNewProc](requiredSymbol(library,
    "ghostty_mouse_encoder_new"))
  let createEvent = cast[MouseEventNewProc](requiredSymbol(library,
    "ghostty_mouse_event_new"))
  let freeEncoder = cast[HandleFreeProc](requiredSymbol(library,
    "ghostty_mouse_encoder_free"))
  let setOption = cast[MouseSetOptionProc](requiredSymbol(library,
    "ghostty_mouse_encoder_setopt"))
  var encoderHandle: pointer
  checkResult("mouse encoder creation", createEncoder(nil, addr encoderHandle))
  if encoderHandle.isNil:
    raise newException(IOError,
      "libghostty-vt created a mouse encoder without a handle")
  var eventHandle: pointer
  try:
    checkResult("mouse event creation", createEvent(nil, addr eventHandle))
  except CatchableError:
    freeEncoder(encoderHandle)
    raise
  if eventHandle.isNil:
    freeEncoder(encoderHandle)
    raise newException(IOError,
      "libghostty-vt created a mouse event without a handle")
  new(result)
  result.library = library
  result.handle = encoderHandle
  result.event = eventHandle
  var trackLastCell = true
  setOption(result.handle, 4, addr trackLastCell)

proc requireHandle(encoder: GhosttyKeyEncoder): pointer =
  if encoder.isNil or encoder.handle.isNil or encoder.event.isNil:
    raise newException(IOError, "key encoder is closed")
  encoder.handle

proc requireHandle(encoder: GhosttyMouseEncoder): pointer =
  if encoder.isNil or encoder.handle.isNil or encoder.event.isNil:
    raise newException(IOError, "mouse encoder is closed")
  encoder.handle

proc close*(encoder: GhosttyKeyEncoder) =
  ## Frees key event and encoder handles before unloading their library.
  if encoder.isNil or encoder.handle.isNil:
    return
  let freeEvent = cast[HandleFreeProc](requiredSymbol(encoder.library,
    "ghostty_key_event_free"))
  let freeEncoder = cast[HandleFreeProc](requiredSymbol(encoder.library,
    "ghostty_key_encoder_free"))
  let eventHandle = encoder.event
  let encoderHandle = encoder.handle
  encoder.event = nil
  encoder.handle = nil
  freeEvent(eventHandle)
  freeEncoder(encoderHandle)

proc close*(encoder: GhosttyMouseEncoder) =
  ## Frees mouse event and encoder handles before unloading their library.
  if encoder.isNil or encoder.handle.isNil:
    return
  let freeEvent = cast[HandleFreeProc](requiredSymbol(encoder.library,
    "ghostty_mouse_event_free"))
  let freeEncoder = cast[HandleFreeProc](requiredSymbol(encoder.library,
    "ghostty_mouse_encoder_free"))
  let eventHandle = encoder.event
  let encoderHandle = encoder.handle
  encoder.event = nil
  encoder.handle = nil
  freeEvent(eventHandle)
  freeEncoder(encoderHandle)

proc sync*(encoder: GhosttyKeyEncoder; terminal: GhosttyTerminal;
           optionAsAlt = false) =
  ## Copies terminal key modes and configures macOS Option-as-Alt behavior.
  let encoderHandle = requireHandle(encoder)
  if terminal.isNil or not terminal.belongsToLibrary(encoder.library):
    raise newException(ValueError,
      "key encoder and terminal must use the same Ghostty library")
  let syncOptions = cast[KeySyncProc](requiredSymbol(encoder.library,
    "ghostty_key_encoder_setopt_from_terminal"))
  let setOption = cast[KeySetOptionProc](requiredSymbol(encoder.library,
    "ghostty_key_encoder_setopt"))
  var optionValue = int32(ord(optionAsAlt))
  syncOptions(encoderHandle, terminal.rawHandle())
  setOption(encoderHandle, 6, addr optionValue)

proc encode*(encoder: GhosttyKeyEncoder; input: KeyEvent): seq[byte] =
  ## Encodes one key event. The result owns its bytes and may outlive this call.
  let encoderHandle = requireHandle(encoder)
  let eventHandle = encoder.event
  let setAction = cast[KeySetActionProc](requiredSymbol(encoder.library,
    "ghostty_key_event_set_action"))
  let setKey = cast[KeySetKeyProc](requiredSymbol(encoder.library,
    "ghostty_key_event_set_key"))
  let setMods = cast[KeySetModsProc](requiredSymbol(encoder.library,
    "ghostty_key_event_set_mods"))
  let setConsumedMods = cast[KeySetModsProc](requiredSymbol(encoder.library,
    "ghostty_key_event_set_consumed_mods"))
  let setComposing = cast[KeySetBoolProc](requiredSymbol(encoder.library,
    "ghostty_key_event_set_composing"))
  let setUnshifted = cast[KeySetCodepointProc](requiredSymbol(encoder.library,
    "ghostty_key_event_set_unshifted_codepoint"))
  let setUtf8 = cast[KeySetUtf8Proc](requiredSymbol(encoder.library,
    "ghostty_key_event_set_utf8"))
  let encodeKey = cast[KeyEncodeProc](requiredSymbol(encoder.library,
    "ghostty_key_encoder_encode"))
  setAction(eventHandle, int32(ord(input.action)))
  setKey(eventHandle, int32(input.key))
  setMods(eventHandle, uint16(input.mods))
  setConsumedMods(eventHandle, uint16(input.consumed))
  setComposing(eventHandle, input.composing)
  setUnshifted(eventHandle, input.unshifted)
  if input.text.len > 0:
    setUtf8(eventHandle, cast[pointer](unsafeAddr input.text[0]),
      csize_t(input.text.len))
  else:
    setUtf8(eventHandle, nil, 0)
  defer: setUtf8(eventHandle, nil, 0)

  var output: array[128, byte]
  var written: csize_t
  var status = encodeKey(encoderHandle, eventHandle,
    cast[ptr UncheckedArray[byte]](addr output[0]),
    csize_t(output.len), addr written)
  if status == outOfSpace:
    let capacity = requiredSize(written, "key input")
    if capacity == 0:
      raise newException(IOError,
        "libghostty-vt returned an empty required key input buffer")
    result = newSeq[byte](capacity)
    status = encodeKey(encoderHandle, eventHandle,
      cast[ptr UncheckedArray[byte]](addr result[0]), csize_t(capacity),
      addr written)
    checkResult("key encoding", status)
    if written > csize_t(result.len):
      raise newException(IOError,
        "libghostty-vt returned an oversized key input")
    result.setLen(int(written))
    return
  checkResult("key encoding", status)
  if written > csize_t(output.len):
    raise newException(IOError,
      "libghostty-vt returned an oversized key input")
  result = newSeq[byte](int(written))
  if written > 0:
    copyMem(addr result[0], addr output[0], int(written))

proc checkedUint32(value: int; label: string; minimum: int): uint32 =
  let normalized = max(minimum, value)
  if uint64(normalized) > uint64(high(uint32)):
    raise newException(ValueError, label & " exceeds the Ghostty ABI range")
  uint32(normalized)

proc sync*(encoder: GhosttyMouseEncoder; terminal: GhosttyTerminal;
           width, height, cellWidth, cellHeight, padLeft, padTop: int;
           pressed: bool) =
  ## Copies terminal mouse modes, pixel geometry, and button state.
  let encoderHandle = requireHandle(encoder)
  if terminal.isNil or not terminal.belongsToLibrary(encoder.library):
    raise newException(ValueError,
      "mouse encoder and terminal must use the same Ghostty library")
  let syncOptions = cast[MouseSyncProc](requiredSymbol(encoder.library,
    "ghostty_mouse_encoder_setopt_from_terminal"))
  let setOption = cast[MouseSetOptionProc](requiredSymbol(encoder.library,
    "ghostty_mouse_encoder_setopt"))
  var size = MouseEncoderSize(
    size: csize_t(sizeof(MouseEncoderSize)),
    screenWidth: checkedUint32(width, "screen width", 1),
    screenHeight: checkedUint32(height, "screen height", 1),
    cellWidth: checkedUint32(cellWidth, "cell width", 1),
    cellHeight: checkedUint32(cellHeight, "cell height", 1),
    paddingTop: checkedUint32(padTop, "top padding", 0),
    paddingLeft: checkedUint32(padLeft, "left padding", 0))
  var anyButtonPressed = pressed
  syncOptions(encoderHandle, terminal.rawHandle())
  setOption(encoderHandle, 2, addr size)
  setOption(encoderHandle, 3, addr anyButtonPressed)

proc reset*(encoder: GhosttyMouseEncoder) =
  ## Clears last-cell motion deduplication state.
  let encoderHandle = requireHandle(encoder)
  let resetEncoder = cast[MouseResetProc](requiredSymbol(encoder.library,
    "ghostty_mouse_encoder_reset"))
  resetEncoder(encoderHandle)

proc encode*(encoder: GhosttyMouseEncoder; action: MouseAction;
             button: MouseButton; mods: Mods; x, y: float32): seq[byte] =
  ## Encodes a pixel-positioned pointer event; empty means no report was due.
  let encoderHandle = requireHandle(encoder)
  let eventHandle = encoder.event
  let setAction = cast[MouseSetActionProc](requiredSymbol(encoder.library,
    "ghostty_mouse_event_set_action"))
  let setButton = cast[MouseSetButtonProc](requiredSymbol(encoder.library,
    "ghostty_mouse_event_set_button"))
  let clearButton = cast[MouseClearButtonProc](requiredSymbol(encoder.library,
    "ghostty_mouse_event_clear_button"))
  let setMods = cast[MouseSetModsProc](requiredSymbol(encoder.library,
    "ghostty_mouse_event_set_mods"))
  let setPosition = cast[MouseSetPositionProc](requiredSymbol(encoder.library,
    "ghostty_mouse_event_set_position"))
  let encodeMouse = cast[MouseEncodeProc](requiredSymbol(encoder.library,
    "ghostty_mouse_encoder_encode"))
  setAction(eventHandle, int32(ord(action)))
  if button == buttonNone:
    clearButton(eventHandle)
  else:
    setButton(eventHandle, int32(button))
  setMods(eventHandle, uint16(mods))
  setPosition(eventHandle, MousePosition(x: cfloat(x), y: cfloat(y)))

  var output: array[64, byte]
  var written: csize_t
  var status = encodeMouse(encoderHandle, eventHandle,
    cast[ptr UncheckedArray[byte]](addr output[0]),
    csize_t(output.len), addr written)
  if status == outOfSpace:
    let capacity = requiredSize(written, "mouse input")
    if capacity == 0:
      raise newException(IOError,
        "libghostty-vt returned an empty required mouse input buffer")
    result = newSeq[byte](capacity)
    status = encodeMouse(encoderHandle, eventHandle,
      cast[ptr UncheckedArray[byte]](addr result[0]), csize_t(capacity),
      addr written)
    checkResult("mouse encoding", status)
    if written > csize_t(result.len):
      raise newException(IOError,
        "libghostty-vt returned an oversized mouse input")
    result.setLen(int(written))
    return
  checkResult("mouse encoding", status)
  if written > csize_t(output.len):
    raise newException(IOError,
      "libghostty-vt returned an oversized mouse input")
  result = newSeq[byte](int(written))
  if written > 0:
    copyMem(addr result[0], addr output[0], int(written))
