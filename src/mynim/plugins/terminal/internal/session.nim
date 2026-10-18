## A PTY process connected to a serialized Ghostty terminal and render state.

import std/[locks, options, strutils, unicode]
import ./pty
import ./vt/[effects, encode, frame, input, library, render, selection, terminal]

type
  TerminalEventKind* = enum
    terminalBell,
    terminalTitleChanged,
    terminalPwdChanged,
    terminalRenderHoldChanged,
    terminalReset,
    terminalNotification,
    terminalClipboardWrite,
    terminalProcessExited

  TerminalEvent* = object
    kind*: TerminalEventKind
    title*, pwd*, body*, clipboardText*: string
    held*: bool
    exitCode*: int

  TerminalWake* = proc() {.closure.}
  TerminalNotify = proc(title, body: string) {.closure.}

  TerminalSessionData = object
    terminalGuard: Lock
    inputGuard: Lock
    inputChanged: Cond
    library: GhosttyVT
    terminal: GhosttyTerminal
    selectionGesture: GhosttySelectionGesture
    renderState: GhosttyRenderState
    keyEncoder: GhosttyKeyEncoder
    mouseEncoder: GhosttyMouseEncoder
    process: Pty
    readerThread, writerThread: Thread[TerminalSession]
    readerStarted, writerStarted: bool
    callbacksInstalled: bool
    closed, closing, writerStop, readerDone: bool
    inputQueue: seq[seq[byte]]
    inputQueueBytes: int
    inputError: string
    processExitCode: Option[int]
    events: seq[TerminalEvent]
    wake: TerminalWake
    onNotify: TerminalNotify
    noClipboardWrite: bool
    renderHeld: bool
    heldFrame: Option[TerminalFrame]
    cols, rows, cellWidth, cellHeight: int

  TerminalSession* = ref TerminalSessionData

const
  inputQueueLimit = 16 * 1024 * 1024
  defaultScrollbackBytes = 10 * 1024 * 1024
  readBufferSize = 8192
  clipboardLocationStandard = 0'i32
  clipboardWriteSuccess = 0'i32
  clipboardWriteDenied = 1'i32
  clipboardWriteUnsupported = 2'i32

proc `=destroy`(session: var TerminalSessionData) =
  deinitCond(session.inputChanged)
  deinitLock(session.inputGuard)
  deinitLock(session.terminalGuard)

proc `=copy`(destination: var TerminalSessionData;
             source: TerminalSessionData) {.error:
  "terminal sessions are reference-owned".}

proc addEvent(session: TerminalSession; event: sink TerminalEvent) =
  session.events.add(event)

proc signalWake(session: TerminalSession)

proc recordInputError(session: TerminalSession; message: string) =
  session.inputGuard.acquire()
  if session.inputError.len == 0:
    session.inputError = message
  session.inputChanged.broadcast()
  session.inputGuard.release()
  session.signalWake()

proc signalWake(session: TerminalSession) =
  var wake: TerminalWake
  session.inputGuard.acquire()
  wake = session.wake
  session.inputGuard.release()
  if wake != nil:
    {.cast(gcsafe).}:
      wake()

proc queueInput(session: TerminalSession; data: openArray[byte];
                fromCallback: bool): bool =
  if data.len == 0:
    return true
  session.inputGuard.acquire()
  if session.closing or session.closed or session.writerStop:
    if fromCallback and session.inputError.len == 0:
      session.inputError = "terminal process has stopped"
    session.inputGuard.release()
    return false
  if data.len > inputQueueLimit - session.inputQueueBytes:
    if session.inputError.len == 0:
      session.inputError = "terminal input queue exceeds 16 MiB"
    session.inputChanged.broadcast()
    session.inputGuard.release()
    return false
  var copied = newSeq[byte](data.len)
  copyMem(addr copied[0], unsafeAddr data[0], data.len)
  session.inputQueue.add(move(copied))
  session.inputQueueBytes += data.len
  session.inputChanged.signal()
  session.inputGuard.release()
  true

proc onWritePty(rawTerminal, userdata: pointer;
                data: ptr UncheckedArray[byte]; length: csize_t) {.cdecl.} =
  discard rawTerminal
  let session = cast[TerminalSession](userdata)
  if session.isNil or data.isNil or length == 0 or
      uint64(length) > uint64(high(int)):
    return
  try:
    discard session.queueInput(toOpenArray(data, 0, int(length) - 1), true)
  except CatchableError as error:
    session.recordInputError(error.msg)

proc onBell(rawTerminal, userdata: pointer) {.cdecl.} =
  discard rawTerminal
  let session = cast[TerminalSession](userdata)
  if not session.isNil:
    try:
      session.addEvent(TerminalEvent(kind: terminalBell))
    except CatchableError as error:
      session.recordInputError(error.msg)

proc onTitleChanged(rawTerminal, userdata: pointer) {.cdecl.} =
  discard rawTerminal
  let session = cast[TerminalSession](userdata)
  if not session.isNil:
    try:
      session.addEvent(TerminalEvent(kind: terminalTitleChanged,
        title: session.terminal.title()))
    except CatchableError as error:
      session.recordInputError(error.msg)

proc onPwdChanged(rawTerminal, userdata: pointer) {.cdecl.} =
  discard rawTerminal
  let session = cast[TerminalSession](userdata)
  if not session.isNil:
    try:
      session.addEvent(TerminalEvent(kind: terminalPwdChanged,
        pwd: session.terminal.pwd()))
    except CatchableError as error:
      session.recordInputError(error.msg)

proc onRenderHold(rawTerminal, userdata: pointer; held: bool) {.cdecl.} =
  discard rawTerminal
  let session = cast[TerminalSession](userdata)
  if session.isNil:
    return
  try:
    if held:
      session.renderState.update(session.terminal)
      session.heldFrame = some(session.renderState.snapshotCurrent())
    else:
      session.heldFrame = none(TerminalFrame)
    session.renderHeld = held
    session.addEvent(TerminalEvent(kind: terminalRenderHoldChanged,
      held: held))
  except CatchableError as error:
    session.recordInputError(error.msg)

proc onReset(rawTerminal, userdata: pointer) {.cdecl.} =
  discard rawTerminal
  let session = cast[TerminalSession](userdata)
  if not session.isNil:
    try:
      session.heldFrame = none(TerminalFrame)
      session.renderHeld = false
      session.addEvent(TerminalEvent(kind: terminalReset))
    except CatchableError as error:
      session.recordInputError(error.msg)

proc copyGhosttyString(value: GhosttyString; valid: var bool): string =
  if uint64(value.len) > uint64(high(int)) or
      (value.len > 0 and value.data.isNil):
    valid = false
    return
  if value.len == 0:
    return
  result = newString(int(value.len))
  copyMem(addr result[0], value.data, result.len)

proc clipboardText(request: GhosttyClipboardWrite):
    tuple[text: string, supported: bool] =
  if request.contentsLen == 0:
    return (text: "", supported: true)
  if uint64(request.contentsLen) > uint64(high(int)) or
      request.contents.isNil:
    return

  var fallback = ""
  var hasFallback = false
  var valid = true
  for item in request.contents.toOpenArray(0, int(request.contentsLen) - 1):
    let mime = copyGhosttyString(item.mime, valid)
    if not valid:
      return
    if mime == "text/plain" or mime.startsWith("text/plain;"):
      result.text = copyGhosttyString(item.data, valid)
      result.supported = valid
      return
    if not hasFallback and mime.startsWith("text/"):
      fallback = copyGhosttyString(item.data, valid)
      if not valid:
        return
      hasFallback = true
  if hasFallback:
    result.text = fallback
    result.supported = true

proc onClipboardWrite(rawTerminal, userdata: pointer;
                      request: ptr GhosttyClipboardWrite) {.cdecl.} =
  discard rawTerminal
  if request.isNil or request.size <
      csize_t(offsetOf(GhosttyClipboardWrite, reply) +
        sizeof(GhosttyClipboardWriteReplyFn)):
    return
  let replyFn = request.reply
  if replyFn.isNil:
    return

  var reply = GhosttyClipboardWriteReply(
    size: csize_t(sizeof(GhosttyClipboardWriteReply)),
    result: clipboardWriteDenied)
  let session = cast[TerminalSession](userdata)
  try:
    if not session.isNil and request.size >=
        csize_t(sizeof(GhosttyClipboardWrite)) and
        request.location == clipboardLocationStandard and
        not session.noClipboardWrite:
      let content = clipboardText(request[])
      if content.supported:
        session.addEvent(TerminalEvent(kind: terminalClipboardWrite,
          clipboardText: content.text))
        reply.result = clipboardWriteSuccess
      else:
        reply.result = clipboardWriteUnsupported
  except CatchableError as error:
    if not session.isNil:
      session.recordInputError(error.msg)
  replyFn(request, addr reply)

proc onDesktopNotification(rawTerminal, userdata: pointer;
    notification: ptr GhosttyTerminalDesktopNotification) {.cdecl.} =
  discard rawTerminal
  let session = cast[TerminalSession](userdata)
  if session.isNil or notification.isNil or notification.size <
      csize_t(sizeof(GhosttyTerminalDesktopNotification)):
    return
  try:
    var valid = true
    let title = copyGhosttyString(notification.title, valid)
    if not valid:
      return
    let body = copyGhosttyString(notification.body, valid)
    if valid and session.onNotify != nil:
      session.addEvent(TerminalEvent(kind: terminalNotification,
        title: title, body: body))
  except CatchableError as error:
    session.recordInputError(error.msg)

proc sessionCallbacks(): TerminalCallbacks =
  TerminalCallbacks(
    writePty: onWritePty,
    bell: onBell,
    titleChanged: onTitleChanged,
    pwdChanged: onPwdChanged,
    renderHold: onRenderHold,
    reset: onReset,
    clipboardWrite: onClipboardWrite,
    desktopNotification: onDesktopNotification)

proc dispatchNotifications(session: TerminalSession) =
  if session.onNotify == nil:
    return
  var notifications: seq[TerminalEvent]
  session.terminalGuard.acquire()
  var remaining: seq[TerminalEvent]
  for event in session.events:
    if event.kind == terminalNotification:
      notifications.add(event)
    else:
      remaining.add(event)
  session.events = move(remaining)
  session.terminalGuard.release()
  for event in notifications:
    try:
      session.onNotify(event.title, event.body)
    except CatchableError as error:
      session.recordInputError(error.msg)

proc reader(session: TerminalSession) {.thread.} =
  {.cast(gcsafe).}:
    var buffer = newSeq[byte](readBufferSize)
    while true:
      var count: int
      try:
        count = session.process.read(buffer)
      except CatchableError as error:
        session.recordInputError(error.msg)
        break
      if count <= 0:
        break
      session.terminalGuard.acquire()
      try:
        session.terminal.write(buffer.toOpenArray(0, count - 1))
      except CatchableError as error:
        session.terminalGuard.release()
        session.recordInputError(error.msg)
        break
      session.terminalGuard.release()
      session.dispatchNotifications()
      session.signalWake()

    var exitCode = 0
    var hasExitCode = false
    try:
      exitCode = session.process.wait()
      hasExitCode = true
    except CatchableError as error:
      session.recordInputError(error.msg)
    session.terminalGuard.acquire()
    if hasExitCode:
      session.addEvent(TerminalEvent(kind: terminalProcessExited,
        exitCode: exitCode))
    session.terminalGuard.release()
    session.signalWake()
    session.inputGuard.acquire()
    if hasExitCode:
      session.processExitCode = some(exitCode)
    session.readerDone = true
    session.writerStop = true
    session.inputChanged.broadcast()
    session.inputGuard.release()

proc writer(session: TerminalSession) {.thread.} =
  {.cast(gcsafe).}:
    while true:
      session.inputGuard.acquire()
      while session.inputQueue.len == 0 and not session.writerStop:
        session.inputChanged.wait(session.inputGuard)
      if session.writerStop:
        session.inputQueue.setLen(0)
        session.inputQueueBytes = 0
        session.inputGuard.release()
        break
      var data = move(session.inputQueue[0])
      session.inputQueue.delete(0)
      session.inputQueueBytes -= data.len
      session.inputGuard.release()

      var offset = 0
      try:
        while offset < data.len:
          let written = session.process.write(data.toOpenArray(offset,
            data.high))
          if written <= 0:
            raise newException(IOError, "terminal PTY accepted no input")
          offset += written
      except CatchableError as error:
        session.recordInputError(error.msg)
        session.inputGuard.acquire()
        session.writerStop = true
        session.inputChanged.broadcast()
        session.inputGuard.release()
        break

proc cellPixels(cols, rows, cellWidth, cellHeight: int):
    tuple[width, height: int] =
  let width = uint64(cols) * uint64(cellWidth)
  let height = uint64(rows) * uint64(cellHeight)
  (int(min(width, 0xFFFF'u64)), int(min(height, 0xFFFF'u64)))

proc releaseGhostty(session: TerminalSession) =
  if session.callbacksInstalled and not session.terminal.isNil:
    try:
      session.terminal.clearCallbacks()
    except CatchableError as error:
      session.recordInputError(error.msg)
    session.callbacksInstalled = false
  if not session.mouseEncoder.isNil:
    try:
      session.mouseEncoder.close()
    except CatchableError as error:
      session.recordInputError(error.msg)
    session.mouseEncoder = nil
  if not session.keyEncoder.isNil:
    try:
      session.keyEncoder.close()
    except CatchableError as error:
      session.recordInputError(error.msg)
    session.keyEncoder = nil
  if not session.renderState.isNil:
    try:
      session.renderState.close()
    except CatchableError as error:
      session.recordInputError(error.msg)
    session.renderState = nil
  if not session.selectionGesture.isNil:
    try:
      session.selectionGesture.close(session.terminal)
    except CatchableError as error:
      session.recordInputError(error.msg)
    session.selectionGesture = nil
  if not session.terminal.isNil:
    try:
      session.terminal.close()
    except CatchableError as error:
      session.recordInputError(error.msg)
    session.terminal = nil

proc newTerminalSession*(library: GhosttyVT; process: PtyOptions;
    cols = 80; rows = 24; cellWidth = 1; cellHeight = 1;
    cursorBlink = true;
    terminfoName = "xterm-256color";
    scrollbackMaxBytes = defaultScrollbackBytes;
    noClipboardWrite = false;
    onNotify: TerminalNotify = nil): TerminalSession =
  ## Starts a PTY-backed Ghostty terminal and its input/output workers.
  if library.isNil:
    raise newException(ValueError, "terminal session Ghostty library is nil")
  if cols <= 0 or cols > high(uint16).int or rows <= 0 or
      rows > high(uint16).int:
    raise newException(ValueError, "terminal session dimensions are invalid")
  if cellWidth <= 0 or uint64(cellWidth) > uint64(high(uint32)) or
      cellHeight <= 0 or uint64(cellHeight) > uint64(high(uint32)):
    raise newException(ValueError, "terminal session cell size is invalid")

  new(result)
  initLock(result.terminalGuard)
  initLock(result.inputGuard)
  initCond(result.inputChanged)
  result.library = library
  result.cols = cols
  result.rows = rows
  result.cellWidth = cellWidth
  result.cellHeight = cellHeight
  result.noClipboardWrite = noClipboardWrite
  result.onNotify = onNotify

  try:
    result.terminal = newGhosttyTerminal(library, cols, rows)
    result.selectionGesture = newGhosttySelectionGesture(library)
    result.terminal.setTerminfoName(terminfoName)
    result.terminal.setScrollbackMaxBytes(scrollbackMaxBytes)
    result.terminal.setDefaultCursor(cursorStyleBlock, cursorBlink)
    result.terminal.setModeDefault(modeGraphemes, true)
    result.keyEncoder = newGhosttyKeyEncoder(library)
    result.mouseEncoder = newGhosttyMouseEncoder(library)
    result.renderState = newGhosttyRenderState(library)
    var processOptions = process
    processOptions.cols = cols
    processOptions.rows = rows
    let pixels = cellPixels(cols, rows, cellWidth, cellHeight)
    if processOptions.width <= 0: processOptions.width = pixels.width
    if processOptions.height <= 0: processOptions.height = pixels.height
    result.process = processOptions.start()
    result.terminal.setCallbacks(cast[pointer](result), sessionCallbacks())
    result.callbacksInstalled = true
    createThread(result.writerThread, writer, result)
    result.writerStarted = true
    createThread(result.readerThread, reader, result)
    result.readerStarted = true
  except CatchableError:
    result.inputGuard.acquire()
    result.closing = true
    result.writerStop = true
    result.inputChanged.broadcast()
    result.inputGuard.release()
    if result.process != nil:
      try:
        result.process.kill()
      except CatchableError:
        discard
      result.process.close()
      try:
        discard result.process.wait()
      except CatchableError:
        discard
    if result.readerStarted:
      joinThread(result.readerThread)
      result.readerStarted = false
    if result.writerStarted:
      joinThread(result.writerThread)
      result.writerStarted = false
    result.terminalGuard.acquire()
    result.releaseGhostty()
    result.terminalGuard.release()
    result.inputGuard.acquire()
    result.closed = true
    result.inputChanged.broadcast()
    result.inputGuard.release()
    raise

proc failure*(session: TerminalSession): string

proc send*(session: TerminalSession; data: openArray[byte]) =
  ## Queues keyboard, paste, mouse, or other encoded input for the PTY.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  if data.len > inputQueueLimit:
    raise newException(ValueError, "terminal input exceeds 16 MiB")
  if not session.queueInput(data, false):
    let error = session.failure()
    raise newException(IOError,
      if error.len > 0: error else: "terminal process has stopped")

proc lockTerminal(session: TerminalSession) =
  session.terminalGuard.acquire()
  session.inputGuard.acquire()
  let stopped = session.closing or session.closed
  session.inputGuard.release()
  if stopped or session.terminal.isNil:
    session.terminalGuard.release()
    raise newException(IOError, "terminal session is closed")

proc send*(session: TerminalSession; data: string) =
  ## Queues UTF-8 or VT-encoded input for the PTY.
  if data.len > 0:
    session.send(data.toOpenArrayByte(0, data.high))

proc setWake*(session: TerminalSession; wake: TerminalWake) =
  ## Sets a thread-safe UI wake callback for output and process events.
  if session.isNil:
    return
  session.inputGuard.acquire()
  session.wake = wake
  session.inputGuard.release()

proc sendKey*(session: TerminalSession; event: KeyEvent;
              optionAsAlt = false) =
  ## Syncs current Ghostty modes, encodes a key event, and queues its bytes.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  var encoded: seq[byte]
  try:
    session.keyEncoder.sync(session.terminal, optionAsAlt)
    encoded = session.keyEncoder.encode(event)
  finally:
    session.terminalGuard.release()
  session.send(encoded)

proc sendFocus*(session: TerminalSession; gained: bool) =
  ## Sends a focus report only while the application has enabled mode 1004.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  var report: seq[byte]
  try:
    if session.terminal.mode(modeFocusEvent):
      report = encodeFocus(session.library, gained)
  finally:
    session.terminalGuard.release()
  session.send(report)

proc mode*(session: TerminalSession; mode: TerminalMode): bool =
  ## Reports a Ghostty mode while serializing access to the terminal.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    result = session.terminal.mode(mode)
  finally:
    session.terminalGuard.release()

proc activeScreen*(session: TerminalSession): bool =
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    result = session.terminal.activeScreen()
  finally:
    session.terminalGuard.release()

proc scrollBy*(session: TerminalSession; rows: int) =
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    session.terminal.scrollBy(rows)
  finally:
    session.terminalGuard.release()

proc scrollbar*(session: TerminalSession): TerminalScrollbar =
  ## Returns the scrollback viewport's total, offset, and visible row count.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    result = session.terminal.scrollbar()
  finally:
    session.terminalGuard.release()

proc scrollToOffset*(session: TerminalSession; offset: uint64) =
  ## Moves to a Ghostty scrollbar offset, clamping to the retained history.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    let current = session.terminal.scrollbar()
    let maximum = if current.total > current.len:
        current.total - current.len else: 0'u64
    let target = min(offset, maximum)
    if target > current.offset:
      let amount = min(target - current.offset, uint64(high(int64)))
      session.terminal.scrollBy(int(amount))
    elif target < current.offset:
      let amount = min(current.offset - target, uint64(high(int64)))
      session.terminal.scrollBy(-int(amount))
  finally:
    session.terminalGuard.release()

proc scrollToBottom*(session: TerminalSession) =
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    session.terminal.scrollToBottom()
  finally:
    session.terminalGuard.release()

proc selectionPress*(session: TerminalSession; column, row: int;
    x, y: float64; timeNs: uint64; repeatDistance = 5.0): bool =
  ## Starts a pointer selection and installs any click selection immediately.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    let reference = session.terminal.cellAt(column, row)
    if reference.isNone:
      return false
    let selection = session.selectionGesture.press(session.terminal,
      reference.get(), x, y, timeNs, repeatDistance)
    session.terminal.setSelection(selection)
    result = true
  finally:
    session.terminalGuard.release()

proc selectionDrag*(session: TerminalSession; column, row: int;
    x, y: float64; columns, cellWidth, paddingLeft, screenHeight: int;
    rectangle = false): bool =
  ## Extends and installs a pointer selection.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    let reference = session.terminal.cellAt(column, row)
    if reference.isNone:
      return false
    let selection = session.selectionGesture.drag(session.terminal,
      reference.get(), x, y, columns, cellWidth, paddingLeft, screenHeight,
      rectangle)
    if selection.isSome:
      session.terminal.setSelection(selection)
    result = true
  finally:
    session.terminalGuard.release()

proc selectionRelease*(session: TerminalSession; column, row: int;
                       inside: bool) =
  ## Ends a pointer selection, preserving its final range.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    var reference = none(GhosttyGridRef)
    if inside:
      reference = session.terminal.cellAt(column, row)
    session.selectionGesture.release(session.terminal, reference)
  finally:
    session.terminalGuard.release()

proc selectionAutoscroll*(session: TerminalSession): int =
  ## Returns the active selection drag's scroll direction.
  if session.isNil:
    return 0
  session.lockTerminal()
  try:
    result = session.selectionGesture.autoscroll(session.terminal)
  finally:
    session.terminalGuard.release()

proc selectionTick*(session: TerminalSession; column, row: int;
    x, y: float64; columns, cellWidth, paddingLeft, screenHeight: int): bool =
  ## Advances a selection after one viewport autoscroll tick.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    let selection = session.selectionGesture.autoscrollTick(session.terminal,
      column, row, x, y, columns, cellWidth, paddingLeft, screenHeight)
    if selection.isSome:
      session.terminal.setSelection(selection)
      result = true
  finally:
    session.terminalGuard.release()

proc selectAll*(session: TerminalSession): bool =
  ## Selects all retained terminal content.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    let selection = session.terminal.selectAll()
    if selection.isSome:
      session.terminal.setSelection(selection)
      result = true
  finally:
    session.terminalGuard.release()

proc clearSelection*(session: TerminalSession) =
  ## Clears the terminal's active selection.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    session.terminal.setSelection(none(GhosttySelection))
  finally:
    session.terminalGuard.release()

proc selectedText*(session: TerminalSession): Option[string] =
  ## Copies selected content from Ghostty using its terminal text formatter.
  if session.isNil:
    return none(string)
  session.lockTerminal()
  try:
    result = session.terminal.selectedText()
  finally:
    session.terminalGuard.release()

proc clearScrollback*(session: TerminalSession) =
  ## Clears retained terminal history by feeding the emulator CSI 3 J.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    session.terminal.setSelection(none(GhosttySelection))
    let command = [27'u8, 91'u8, 51'u8, 74'u8]
    session.terminal.write(command)
  finally:
    session.terminalGuard.release()

proc scrollForSelection*(session: TerminalSession; rows: int) =
  ## Scrolls the viewport and keeps terminal access serialized with its gesture.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    session.terminal.scrollBy(rows)
  finally:
    session.terminalGuard.release()

proc setColors*(session: TerminalSession; foreground, background: TerminalColor;
                cursor = none(TerminalColor);
                palette = none(TerminalPalette)) =
  ## Applies default foreground/background and optional cursor/palette colors.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    session.terminal.setColors(foreground, background, cursor, palette)
  finally:
    session.terminalGuard.release()

proc paste*(session: TerminalSession; text: string) =
  ## Sanitizes and brackets clipboard text according to current terminal mode.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.terminalGuard.acquire()
  session.inputGuard.acquire()
  let stopped = session.closing or session.closed
  session.inputGuard.release()
  if stopped or session.terminal.isNil:
    session.terminalGuard.release()
    raise newException(IOError, "terminal session is closed")
  var encoded: seq[byte]
  try:
    encoded = encodePaste(session.library, text,
      session.terminal.mode(modeBracketedPaste))
  finally:
    session.terminalGuard.release()
  session.send(encoded)

proc mouseTracking*(session: TerminalSession): bool =
  ## Reports whether the active screen tracks mouse clicks or motion.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    result = session.terminal.mouseTracking()
  finally:
    session.terminalGuard.release()

proc sendMouse*(session: TerminalSession; action: MouseAction;
    button: MouseButton; mods: Mods; x, y: float32;
    screenWidth, screenHeight, cellWidth, cellHeight, padLeft, padTop: int;
    anyButtonPressed: bool): bool =
  ## Syncs mouse modes and geometry, encodes one pointer event, and queues it.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  var encoded: seq[byte]
  try:
    session.mouseEncoder.sync(session.terminal, screenWidth, screenHeight,
      cellWidth, cellHeight, padLeft, padTop, anyButtonPressed)
    encoded = session.mouseEncoder.encode(action, button, mods, x, y)
  finally:
    session.terminalGuard.release()
  result = encoded.len > 0
  session.send(encoded)

proc resize*(session: TerminalSession; cols, rows: int;
             cellWidth = 1; cellHeight = 1) =
  ## Resizes the PTY and terminal model as one serialized update.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  if cols <= 0 or cols > high(uint16).int or rows <= 0 or
      rows > high(uint16).int:
    raise newException(ValueError, "terminal session dimensions are invalid")
  if cellWidth <= 0 or uint64(cellWidth) > uint64(high(uint32)) or
      cellHeight <= 0 or uint64(cellHeight) > uint64(high(uint32)):
    raise newException(ValueError, "terminal session cell size is invalid")
  session.lockTerminal()
  try:
    let pixels = cellPixels(cols, rows, cellWidth, cellHeight)
    session.process.resize(cols, rows, pixels.width, pixels.height)
    session.terminal.resize(cols, rows, cellWidth, cellHeight)
    session.cols = cols
    session.rows = rows
    session.cellWidth = cellWidth
    session.cellHeight = cellHeight
  finally:
    session.terminalGuard.release()

proc size*(session: TerminalSession): tuple[cols, rows: int] =
  ## Returns the current terminal cell dimensions.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    result = session.terminal.size()
  finally:
    session.terminalGuard.release()

proc snapshot*(session: TerminalSession): TerminalFrame =
  ## Returns an owned frame, preserving the captured frame during synchronized output.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    if session.renderHeld and session.heldFrame.isSome:
      result = session.heldFrame.get()
    else:
      result = session.renderState.snapshot(session.terminal)
  finally:
    session.terminalGuard.release()

proc hyperlinkAt*(session: TerminalSession; column, row: int): string =
  ## Returns the OSC 8 URI attached to a visible terminal cell.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    let reference = session.terminal.cellAt(column, row)
    if reference.isSome:
      result = session.terminal.hyperlinkUri(reference.get())
  finally:
    session.terminalGuard.release()

proc rowText*(session: TerminalSession; row: int):
    tuple[text: string, columns: seq[int]] =
  ## Returns visible row text with a cell column for each Unicode codepoint.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  if row < 0:
    return
  session.lockTerminal()
  try:
    let frame = if session.renderHeld and session.heldFrame.isSome:
        session.heldFrame.get()
      else:
        session.renderState.snapshot(session.terminal)
    for visibleRow in frame.viewport:
      if visibleRow.viewportY != row:
        continue
      for column, frameCell in visibleRow.cells:
        if frameCell.cell.wide in {cellSpacerTail, cellSpacerHead}:
          continue
        if frameCell.codepoints.len == 0:
          result.text.add(' ')
          result.columns.add(column)
          continue
        for value in frameCell.codepoints:
          result.text.add(toUTF8(Rune(value)))
          result.columns.add(column)
      return
  finally:
    session.terminalGuard.release()

proc clean*(session: TerminalSession) =
  ## Marks the copied frame clean after the native renderer draws it.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.lockTerminal()
  try:
    session.renderState.clean()
  finally:
    session.terminalGuard.release()

proc takeEvents*(session: TerminalSession): seq[TerminalEvent] =
  ## Transfers events accumulated from VT callbacks and process exit.
  if session.isNil:
    return
  session.terminalGuard.acquire()
  result = move(session.events)
  session.events = @[]
  session.terminalGuard.release()

proc processExitCode*(session: TerminalSession): Option[int] =
  ## Returns the process exit code once its output stream reaches EOF.
  if session.isNil:
    return none(int)
  session.inputGuard.acquire()
  result = session.processExitCode
  session.inputGuard.release()

proc waitForExit*(session: TerminalSession): int =
  ## Waits until the reader has drained PTY output and reaped the process.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  session.inputGuard.acquire()
  while not session.readerDone and not session.closed:
    session.inputChanged.wait(session.inputGuard)
  let exitCode = session.processExitCode
  let error = session.inputError
  session.inputGuard.release()
  if exitCode.isSome:
    return exitCode.get()
  raise newException(IOError,
    if error.len > 0: error else: "terminal session closed before process exit")

proc failure*(session: TerminalSession): string =
  ## Returns the first PTY read or write failure, if any.
  if session.isNil:
    return "terminal session is nil"
  session.inputGuard.acquire()
  result = session.inputError
  session.inputGuard.release()

proc close*(session: TerminalSession) =
  ## Stops the process workers and releases Ghostty objects; call before unloading its library.
  if session.isNil:
    return
  session.inputGuard.acquire()
  if session.closed:
    session.inputGuard.release()
    return
  if session.closing:
    while not session.closed:
      session.inputChanged.wait(session.inputGuard)
    session.inputGuard.release()
    return
  session.closing = true
  session.writerStop = true
  session.inputQueue.setLen(0)
  session.inputQueueBytes = 0
  session.inputChanged.broadcast()
  session.inputGuard.release()

  # Drain operations that passed their initial open check. New calls see
  # `closing` before they can enter the terminal lock.
  session.terminalGuard.acquire()
  session.terminalGuard.release()

  if session.process != nil:
    try:
      session.process.kill()
    except CatchableError as error:
      session.recordInputError(error.msg)
    session.process.close()
  if session.readerStarted:
    joinThread(session.readerThread)
    session.readerStarted = false
  if session.writerStarted:
    joinThread(session.writerThread)
    session.writerStarted = false

  session.terminalGuard.acquire()
  session.releaseGhostty()
  session.process = nil
  session.heldFrame = none(TerminalFrame)
  session.events.setLen(0)
  session.terminalGuard.release()

  session.inputGuard.acquire()
  session.closed = true
  session.inputChanged.broadcast()
  session.inputGuard.release()
  session.signalWake()
