## A PTY process connected to a serialized Ghostty terminal and render state.

import std/[base64, locks, options, os, strutils, unicode]
import mynim/transfer as transfer
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
    terminalClipboardRead,
    terminalProcessExited

  TerminalEvent* = object
    kind*: TerminalEventKind
    title*, pwd*, body*, clipboardText*: string
    clipboardRead*: ClipboardReadRequest
    held*: bool
    exitCode*: int

  ClipboardReadPolicy* = enum
    clipboardAccessDeny,
    clipboardAccessAllow,
    clipboardAccessAsk

  ClipboardReadRequest* = ref object
    id*: uint64
    mimes*: seq[string]
    list*, primary*: bool
    text*: string
    granted: bool
    kitty: bool
    kittyId, prefix, terminator, refusal: string
    ready, suppressOnly, completed: bool
    answer: int8

  PasteContent = object
    mime: string
    data: seq[byte]

  PasteOffer = object
    mimes: seq[string]
    contents: seq[PasteContent]

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
    launchOptions: PtyOptions
    process: Pty
    startupThread, readerThread, writerThread: Thread[TerminalSession]
    startupStarted, readerStarted, writerStarted: bool
    launchPending, launchRequested, processReady: bool
    callbacksInstalled: bool
    closed, closing, writerStop, readerDone: bool
    inputQueue: seq[seq[byte]]
    inputQueueBytes: int
    inputError: string
    processExitCode: Option[int]
    events: seq[TerminalEvent]
    cachedRows: seq[TerminalFrameRow]
    wake: TerminalWake
    onNotify: TerminalNotify
    noClipboardWrite: bool
    clipboardReadPolicy: ClipboardReadPolicy
    pasteOffers: system.Channel[PasteOffer]
    pasteOffersOpen: bool
    capturingClipboardRead: ClipboardReadRequest
    nextClipboardReadId: uint64
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
  session.inputChanged.broadcast()
  session.inputGuard.release()
  true

proc rawString(data: ptr UncheckedArray[byte]; length: csize_t): string =
  if data.isNil or length == 0 or uint64(length) > uint64(high(int)):
    return
  result = newString(int(length))
  copyMem(addr result[0], data, result.len)

proc copyGhosttyString(value: GhosttyString; valid: var bool): string

proc parseClipboardRefusal(request: ClipboardReadRequest;
                           response: string): bool =
  if response.startsWith("\x1b]52;"):
    let first = response.find(';')
    if first < 0:
      return false
    let secondRel = response.find(';', first + 1)
    if secondRel < 0:
      return false
    let second = secondRel
    request.kitty = false
    request.prefix = response[0 .. second]
    request.terminator = response[second + 1 .. ^1]
    request.refusal = response
    return true
  if not response.startsWith("\x1b]5522;type=read:status="):
    return false
  request.kitty = true
  request.refusal = response
  if response.endsWith("\x1b\\"):
    request.terminator = "\x1b\\"
  elif response.endsWith("\x07"):
    request.terminator = "\x07"
  else:
    request.terminator = "\x1b\\"
  request.kittyId.setLen(0)
  let marker = response.find(":id=")
  if marker >= 0:
    let start = marker + 4
    var finish = response.len
    for index in start ..< response.len:
      if response[index] == ':' or response[index] == '\x1b' or
          response[index] == '\x07':
        finish = index
        break
    if finish > start:
      request.kittyId = response[start ..< finish]
  true

proc copyBytes(value: string): seq[byte] =
  result = newSeq[byte](value.len)
  for index, character in value:
    result[index] = byte(character)

proc copyClipboardRead(session: TerminalSession;
                       request: ptr GhosttyClipboardRead):
    ClipboardReadRequest =
  if request.isNil or request.size < csize_t(sizeof(GhosttyClipboardRead)):
    return
  if uint64(request.mimesLen) > uint64(high(int)) or
      (request.mimesLen > 0 and request.mimes.isNil):
    return
  inc session.nextClipboardReadId
  if session.nextClipboardReadId == 0:
    inc session.nextClipboardReadId
  result = ClipboardReadRequest(
    id: session.nextClipboardReadId,
    list: request.list,
    primary: request.location != clipboardLocationStandard,
    granted: request.granted,
    suppressOnly: request.canRemember)
  if request.mimesLen > 0:
    for mime in request.mimes.toOpenArray(0, int(request.mimesLen) - 1):
      var valid = true
      let copied = copyGhosttyString(mime, valid)
      if not valid:
        return nil
      result.mimes.add(copied)

proc offerMime(format: transfer.Format): string =
  if format == transfer.FileList:
    return transfer.URIList
  if format.find('/') <= 0 or format.contains({' ', '\t'}) or
      format.startsWith("application/x-mygo-"):
    return
  format

proc newPasteOffer(data: transfer.Data): PasteOffer =
  let snapshot = data.snapshot()
  for format in snapshot.formats():
    let mime = offerMime(format)
    if mime.len > 0 and mime notin result.mimes:
      result.mimes.add(mime)
  for mime in result.mimes:
    var read = snapshot.read(transfer.Format(mime))
    if read.err != nil and mime == transfer.URIList:
      read = snapshot.read(transfer.FileList)
    if read.err == nil:
      result.contents.add(PasteContent(mime: mime, data: read.data))

proc ghosttyString(value: string): GhosttyString =
  if value.len > 0:
    result = GhosttyString(data: cast[pointer](unsafeAddr value[0]),
      len: csize_t(value.len))

proc readPasteMime(offer: PasteOffer; mime: string): seq[byte] =
  for content in offer.contents:
    if content.mime == mime:
      return content.data

proc answerPasteOffer(request: ptr GhosttyClipboardRead; offer: PasteOffer) =
  if request.isNil or request.reply == nil:
    return
  var mimeNames: seq[string]
  var payloads: seq[seq[byte]]
  var contents: seq[GhosttyClipboardContent]
  for mime in offer.mimes:
    var requested = false
    if request.mimesLen > 0 and not request.mimes.isNil:
      for index in 0 ..< int(request.mimesLen):
        var valid = true
        if copyGhosttyString(request.mimes[index], valid) == mime and valid:
          requested = true
          break
    if not requested:
      continue
    let payload = offer.readPasteMime(mime)
    if payload.len == 0:
      continue
    mimeNames.add(mime)
    payloads.add(payload)
    contents.add(GhosttyClipboardContent(
      mime: ghosttyString(mimeNames[^1]),
      data: GhosttyString(data: cast[pointer](addr payloads[^1][0]),
        len: csize_t(payloads[^1].len))))

  var available: seq[GhosttyString]
  if request.list:
    for mime in offer.mimes:
      available.add(ghosttyString(mime))

  var reply = GhosttyClipboardReadReply(
    size: csize_t(sizeof(GhosttyClipboardReadReply)),
    result: clipboardWriteSuccess)
  if contents.len > 0:
    reply.contents = cast[ptr UncheckedArray[GhosttyClipboardContent]](
      addr contents[0])
    reply.contentsLen = csize_t(contents.len)
  if available.len > 0:
    reply.available = cast[ptr UncheckedArray[GhosttyString]](
      addr available[0])
    reply.availableLen = csize_t(available.len)
  request.reply(cast[pointer](request), addr reply)

proc onWritePty(rawTerminal, userdata: pointer;
                data: ptr UncheckedArray[byte]; length: csize_t) {.cdecl.} =
  discard rawTerminal
  let session = cast[TerminalSession](userdata)
  if session.isNil or data.isNil or length == 0 or
      uint64(length) > uint64(high(int)):
    return
  try:
    let pending = session.capturingClipboardRead
    if pending != nil:
      let response = rawString(data, length)
      session.capturingClipboardRead = nil
      if pending.parseClipboardRefusal(response):
        pending.ready = true
        if not pending.suppressOnly:
          session.addEvent(TerminalEvent(kind: terminalClipboardRead,
            clipboardRead: pending))
        return
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
      let frame = session.renderState.snapshotCurrent(session.cachedRows)
      session.cachedRows = frame.viewport
      session.heldFrame = some(frame)
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
      session.cachedRows = @[]
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

proc onClipboardRead(rawTerminal, userdata: pointer;
                     request: ptr GhosttyClipboardRead) {.cdecl.} =
  ## Leave denied reads to Ghostty. Allowed reads defer its refusal until
  ## the UI thread has read the clipboard and can encode the response.
  discard rawTerminal
  let session = cast[TerminalSession](userdata)
  if session.isNil or request.isNil or request.size <
      csize_t(sizeof(GhosttyClipboardRead)):
    return
  if request.granted:
    let pending = session.pasteOffers.tryRecv()
    if pending.dataAvailable:
      let offer = pending.msg
      try:
        answerPasteOffer(request, offer)
      except CatchableError as error:
        session.recordInputError(error.msg)
      return
  if session.clipboardReadPolicy == clipboardAccessDeny and
      not request.canRemember:
    return
  try:
    let pending = session.copyClipboardRead(request)
    if pending == nil:
      return
    pending.suppressOnly = request.canRemember
    session.capturingClipboardRead = pending
  except CatchableError as error:
    session.recordInputError(error.msg)

proc stringFromBytes(data: openArray[byte]): string =
  result = newString(data.len)
  for index, value in data:
    result[index] = char(value)

proc clipboardBytes(contents: openArray[(string, seq[byte])];
                    mime: string): seq[byte] =
  for (name, data) in contents:
    if name == mime:
      return data

proc kittyClipboardAnswer(request: ClipboardReadRequest;
    contents: openArray[(string, seq[byte])]; available: openArray[string]):
    string =
  proc packet(status: string; primaryLocation = false): string =
    result = "\x1b]5522;type=read:status=" & status
    if primaryLocation and request.primary:
      result.add(":loc=primary")
    if request.kittyId.len > 0:
      result.add(":id=" & request.kittyId)

  let terminator = if request.terminator.len > 0:
      request.terminator else: "\x1b\\"
  result.add(packet("OK", primaryLocation = true))
  result.add(terminator)
  if request.list:
    result.add(packet("DATA"))
    result.add(":mime=" & base64.encode("."))
    var listed: string
    for mime in available:
      let separator = if listed.len > 0: 1 else: 0
      if listed.len + separator + mime.len + 1 > 4096:
        break
      if separator > 0:
        listed.add(' ')
      listed.add(mime)
    listed.add('\n')
    if listed.len > 1:
      result.add(';' & base64.encode(listed))
    result.add(terminator)
  for mime in request.mimes:
    let data = clipboardBytes(contents, mime)
    var offset = 0
    while offset < data.len:
      let finish = min(offset + 4096, data.len)
      result.add(packet("DATA"))
      result.add(":mime=" & base64.encode(mime) & ";")
      result.add(base64.encode(stringFromBytes(data.toOpenArray(offset,
        finish - 1))))
      result.add(terminator)
      offset = finish
  result.add(packet("DONE"))
  result.add(terminator)

proc clipboardAnswer(request: ClipboardReadRequest; allowed: bool;
    contents: openArray[(string, seq[byte])]; available: openArray[string]):
    seq[byte] =
  var response: string
  if not allowed:
    response = request.refusal
  elif request.kitty:
    response = kittyClipboardAnswer(request, contents, available)
  else:
    response = request.prefix &
      base64.encode(stringFromBytes(clipboardBytes(contents, "text/plain"))) &
      request.terminator
  copyBytes(response)

proc clipboardReadAnswer*(session: TerminalSession;
                          request: ClipboardReadRequest): int8 =
  if session.isNil or request.isNil:
    return
  session.terminalGuard.acquire()
  if request.completed:
    result = -1
  else:
    result = request.answer
  session.terminalGuard.release()

proc resolveClipboardRead*(session: TerminalSession;
    request: ClipboardReadRequest; allowed: bool) =
  if session.isNil or request.isNil:
    return
  var wake = false
  session.terminalGuard.acquire()
  if not request.completed and request.answer == 0:
    request.answer = if allowed: 1'i8 else: 2'i8
    wake = true
  session.terminalGuard.release()
  if wake:
    session.signalWake()

proc answerClipboardRead*(session: TerminalSession;
    request: ClipboardReadRequest; allowed: bool;
    contents: openArray[(string, seq[byte])]; available: openArray[string]) =
  if session.isNil or request.isNil:
    return
  session.terminalGuard.acquire()
  if request.ready and not request.completed:
    let response = request.clipboardAnswer(allowed, contents, available)
    discard session.queueInput(response, false)
    request.completed = true
  session.terminalGuard.release()

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
    clipboardRead: onClipboardRead,
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
    session.inputGuard.acquire()
    while not session.processReady and not session.writerStop:
      session.inputChanged.wait(session.inputGuard)
    let canRead = session.processReady and not session.writerStop
    session.inputGuard.release()
    if not canRead:
      return
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
      while (session.inputQueue.len == 0 or not session.processReady) and
          not session.writerStop:
        session.inputChanged.wait(session.inputGuard)
      if session.writerStop and
          (session.inputQueue.len == 0 or not session.processReady):
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

proc startPendingLocked(session: TerminalSession): bool =
  ## Starts the deferred PTY under the terminal lock; true requests an error redraw.
  if not session.launchPending:
    return
  session.inputGuard.acquire()
  let stopping = session.closing or session.closed
  session.inputGuard.release()
  if stopping:
    return

  var processOptions = session.launchOptions
  processOptions.cols = session.cols
  processOptions.rows = session.rows
  let pixels = cellPixels(session.cols, session.rows,
    session.cellWidth, session.cellHeight)
  processOptions.width = pixels.width
  processOptions.height = pixels.height
  try:
    session.process = processOptions.start()
  except CatchableError as error:
    session.launchPending = false
    session.launchRequested = false
    session.launchOptions = PtyOptions()
    try:
      let message = "\e[31m" & error.msg & "\e[0m"
      session.terminal.write(message.toOpenArrayByte(0, message.high))
    except CatchableError as writeError:
      session.inputGuard.acquire()
      if session.inputError.len == 0:
        session.inputError = writeError.msg
      session.inputGuard.release()
    session.inputGuard.acquire()
    session.processExitCode = some(-1)
    session.readerDone = true
    session.writerStop = true
    session.inputQueue.setLen(0)
    session.inputQueueBytes = 0
    session.inputChanged.broadcast()
    session.inputGuard.release()
    session.addEvent(TerminalEvent(kind: terminalProcessExited,
      exitCode: -1))
    return true

  session.launchPending = false
  session.launchRequested = false
  session.launchOptions = PtyOptions()
  session.inputGuard.acquire()
  session.processReady = true
  session.inputChanged.broadcast()
  session.inputGuard.release()

proc delayedStart(session: TerminalSession) {.thread.} =
  {.cast(gcsafe).}:
    const startDelayMs = 500
    const pollIntervalMs = 10
    for _ in 0 ..< startDelayMs div pollIntervalMs:
      sleep(pollIntervalMs)
      session.terminalGuard.acquire()
      let pending = session.launchPending
      let requested = session.launchRequested
      let wake = if pending and requested:
          session.startPendingLocked()
        else:
          false
      session.terminalGuard.release()
      if wake:
        session.signalWake()
      if not pending or requested:
        return
      session.inputGuard.acquire()
      let stopping = session.closing or session.closed
      session.inputGuard.release()
      if stopping:
        return

    session.terminalGuard.acquire()
    let wake = session.startPendingLocked()
    session.terminalGuard.release()
    if wake:
      session.signalWake()

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
    clipboardReadPolicy = clipboardAccessDeny;
    onNotify: TerminalNotify = nil): TerminalSession =
  ## Creates a Ghostty terminal and starts its PTY on first resize or timeout.
  if library.isNil:
    raise newException(ValueError, "terminal session Ghostty library is nil")
  if cols <= 0 or cols > high(uint16).int or rows <= 0 or
      rows > high(uint16).int:
    raise newException(ValueError, "terminal session dimensions are invalid")
  if cellWidth <= 0 or uint64(cellWidth) > uint64(high(uint32)) or
      cellHeight <= 0 or uint64(cellHeight) > uint64(high(uint32)):
    raise newException(ValueError, "terminal session cell size is invalid")
  if process.path.len == 0:
    raise newException(ValueError, "terminal session process path is empty")

  new(result)
  initLock(result.terminalGuard)
  initLock(result.inputGuard)
  initCond(result.inputChanged)
  result.pasteOffers.open(1)
  result.pasteOffersOpen = true
  result.library = library
  result.cols = cols
  result.rows = rows
  result.cellWidth = cellWidth
  result.cellHeight = cellHeight
  result.noClipboardWrite = noClipboardWrite
  result.clipboardReadPolicy = clipboardReadPolicy
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
    result.launchOptions = process
    result.launchPending = true
    result.terminal.setCallbacks(cast[pointer](result), sessionCallbacks())
    result.callbacksInstalled = true
    createThread(result.writerThread, writer, result)
    result.writerStarted = true
    createThread(result.readerThread, reader, result)
    result.readerStarted = true
    createThread(result.startupThread, delayedStart, result)
    result.startupStarted = true
  except CatchableError:
    result.inputGuard.acquire()
    result.closing = true
    result.writerStop = true
    result.inputChanged.broadcast()
    result.inputGuard.release()
    if result.startupStarted:
      joinThread(result.startupThread)
      result.startupStarted = false
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
    result.pasteOffers.close()
    result.pasteOffersOpen = false
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

proc clearPasteOffers(session: TerminalSession) =
  var pending = session.pasteOffers.tryRecv()
  while pending.dataAvailable:
    pending.msg = PasteOffer()
    pending = session.pasteOffers.tryRecv()

proc pasteData*(session: TerminalSession; data: transfer.Data) =
  ## Offers clipboard MIME types to mode 5522, or sends its text normally.
  ## Transfer providers are materialized on the caller thread before the
  ## offer crosses to the PTY reader thread.
  if session.isNil:
    raise newException(ValueError, "terminal session is nil")
  var offer = newPasteOffer(data)
  session.lockTerminal()
  var encoded: seq[byte]
  var offered = false
  try:
    session.clearPasteOffers()
    var fallbackText: string
    for content in offer.contents:
      if content.mime == transfer.Text:
        fallbackText = transfer.bytesToString(content.data)
        break
    let mimes = offer.mimes
    if mimes.len > 0 and session.terminal.mode(modePasteEvents):
      session.pasteOffers.send(move(offer))
      offered = session.terminal.pasteEvent(mimes)
      if not offered:
        session.clearPasteOffers()
    if not offered:
      encoded = encodePaste(session.library, fallbackText,
        session.terminal.mode(modeBracketedPaste))
    session.terminal.scrollToBottom()
  except CatchableError:
    session.clearPasteOffers()
    raise
  finally:
    session.terminalGuard.release()
  if not offered:
    session.send(encoded)

proc paste*(session: TerminalSession; text: string) =
  ## Sanitizes and brackets clipboard text according to current terminal mode.
  session.pasteData(transfer.textData(text))

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
  ## Resizes the terminal and PTY, or starts the deferred PTY at this size.
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
    session.terminal.resize(cols, rows, cellWidth, cellHeight)
    session.cols = cols
    session.rows = rows
    session.cellWidth = cellWidth
    session.cellHeight = cellHeight
    if session.process != nil:
      let pixels = cellPixels(cols, rows, cellWidth, cellHeight)
      session.process.resize(cols, rows, pixels.width, pixels.height)
    elif session.launchPending:
      session.launchRequested = true
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
      result = session.renderState.snapshot(session.terminal,
        session.cachedRows)
      session.cachedRows = result.viewport
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
    var frame: TerminalFrame
    if session.renderHeld and session.heldFrame.isSome:
      frame = session.heldFrame.get()
    else:
      frame = session.renderState.snapshot(session.terminal,
        session.cachedRows)
      session.cachedRows = frame.viewport
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

  if session.startupStarted:
    joinThread(session.startupThread)
    session.startupStarted = false

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

  if session.pasteOffersOpen:
    session.clearPasteOffers()
    session.pasteOffers.close()
    session.pasteOffersOpen = false

  session.terminalGuard.acquire()
  session.releaseGhostty()
  session.process = nil
  session.launchPending = false
  session.launchRequested = false
  session.launchOptions = PtyOptions()
  session.cachedRows = @[]
  session.heldFrame = none(TerminalFrame)
  session.events.setLen(0)
  session.terminalGuard.release()

  session.inputGuard.acquire()
  session.closed = true
  session.inputChanged.broadcast()
  session.inputGuard.release()
  session.signalWake()
