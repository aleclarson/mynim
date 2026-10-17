## single_instance.go — one running app per identifier/name, with later
## launches forwarding their command line and working directory.

when defined(windows) or (defined(posix) and not defined(emscripten)):
  import std/nativesockets as nativeSockets
  import mynim/internal/sha256 as sha256

when defined(windows):
  import std/winlean as winlean
elif defined(posix) and not defined(emscripten):
  import std/posix as posix except Time

const
  maxSecondInstanceMessage = 1 shl 20
  socketTimeoutMs = 2_000
when defined(windows):
  const winUnixPathLength = 108

when defined(windows):
  type
    InstanceSocket = nativeSockets.SocketHandle
    WinUnixAddress = object
      family: uint16
      path: array[108, char]
  let invalidInstanceSocket = winlean.INVALID_SOCKET
elif defined(posix) and not defined(emscripten):
  type InstanceSocket = nativeSockets.SocketHandle
  const invalidInstanceSocket = posix.INVALID_SOCKET
else:
  type InstanceSocket = int
  const invalidInstanceSocket = -1

type
  SecondInstanceMessage = object
    args: seq[string]
    workingDir: string

  SingleInstanceState = object
    mu: Lock
    listener: InstanceSocket
    when defined(windows) or (defined(posix) and not defined(emscripten)):
      listenerThread: Thread[InstanceSocket]
      threadStarted: bool
    locked: bool
    path: string
    socketInfo: FileInfo
    hasSocketInfo: bool
    handlers: Listeners[proc(args: seq[string], workingDir: string) {.closure.}]

var singleInstance: SingleInstanceState
singleInstance.mu.initLock()
singleInstance.listener = invalidInstanceSocket

when defined(windows) or (defined(posix) and not defined(emscripten)):
  proc newInstanceSocket(): InstanceSocket =
    when defined(windows):
      nativeSockets.createNativeSocket(1.cint, 1.cint, 0.cint,
        inheritable = false)
    else:
      nativeSockets.createNativeSocket(nativeSockets.AF_UNIX,
        nativeSockets.SOCK_STREAM, nativeSockets.IPPROTO_NONE,
        inheritable = false)

  proc closeInstanceSocket(socket: InstanceSocket) =
    when defined(windows):
      discard winlean.closesocket(socket)
    else:
      discard posix.close(socket)

  proc socketError(): int32 =
    when defined(windows):
      winlean.wsaGetLastError()
    else:
      int32(osLastError())

  proc addressInUse(error: int32): bool =
    when defined(windows):
      error == winlean.WSAEADDRINUSE
    else:
      error == int32(posix.EADDRINUSE)

  proc bindInstanceSocket(socket: InstanceSocket; path: string): cint =
    when defined(windows):
      if path.len >= winUnixPathLength:
        return -1
      var address = WinUnixAddress(family: 1'u16)
      copyMem(addr address.path[0], path.cstring, path.len + 1)
      nativeSockets.bindAddr(socket,
        cast[ptr nativeSockets.SockAddr](addr address),
        nativeSockets.SockLen(sizeof(address)))
    else:
      var address = nativeSockets.makeUnixAddr(path)
      let length = nativeSockets.SockLen(
        offsetOf(nativeSockets.Sockaddr_un, sun_path) + path.len + 1)
      nativeSockets.bindAddr(socket,
        cast[ptr nativeSockets.SockAddr](addr address), length)

  proc connectInstanceSocket(socket: InstanceSocket; path: string): cint =
    when defined(windows):
      if path.len >= winUnixPathLength:
        return -1
      var address = WinUnixAddress(family: 1'u16)
      copyMem(addr address.path[0], path.cstring, path.len + 1)
      nativeSockets.connect(socket,
        cast[ptr nativeSockets.SockAddr](addr address),
        nativeSockets.SockLen(sizeof(address)))
    else:
      var address = nativeSockets.makeUnixAddr(path)
      let length = nativeSockets.SockLen(
        offsetOf(nativeSockets.Sockaddr_un, sun_path) + path.len + 1)
      nativeSockets.connect(socket,
        cast[ptr nativeSockets.SockAddr](addr address), length)

  proc setSocketTimeout(socket: InstanceSocket) =
    when defined(windows):
      const
        soSndTimeo = 0x1005.cint
        soRcvTimeo = 0x1006.cint
      var timeout = socketTimeoutMs.uint32
      discard winlean.setsockopt(socket, winlean.SOL_SOCKET, soSndTimeo,
        addr timeout, nativeSockets.SockLen(sizeof(timeout)))
      discard winlean.setsockopt(socket, winlean.SOL_SOCKET, soRcvTimeo,
        addr timeout, nativeSockets.SockLen(sizeof(timeout)))
    else:
      var timeout: posix.Timeval
      timeout.tv_sec = typeof(timeout.tv_sec)(socketTimeoutMs div 1_000)
      timeout.tv_usec = typeof(timeout.tv_usec)((socketTimeoutMs mod 1_000) * 1_000)
      discard posix.setsockopt(socket, posix.SOL_SOCKET, posix.SO_SNDTIMEO,
        addr timeout, nativeSockets.SockLen(sizeof(timeout)))
      discard posix.setsockopt(socket, posix.SOL_SOCKET, posix.SO_RCVTIMEO,
        addr timeout, nativeSockets.SockLen(sizeof(timeout)))

  proc configureNoSigpipe(socket: InstanceSocket) =
    when defined(macosx) or defined(bsd) or defined(haiku):
      var enabled = 1.cint
      discard posix.setsockopt(socket, posix.SOL_SOCKET, posix.SO_NOSIGPIPE,
        addr enabled, nativeSockets.SockLen(sizeof(enabled)))

  proc sendAll(socket: InstanceSocket; data: string): bool =
    var sentTotal = 0
    while sentTotal < data.len:
      let flags = when defined(windows): 0.cint
        else: nativeSockets.MSG_NOSIGNAL
      let sent = when defined(windows):
        nativeSockets.send(socket, unsafeAddr data[sentTotal],
          (data.len - sentTotal).cint, flags)
      else:
        nativeSockets.send(socket, unsafeAddr data[sentTotal],
          data.len - sentTotal, flags)
      if sent <= 0:
        return false
      sentTotal += sent
    true

  proc readToEnd(socket: InstanceSocket; limit: int): tuple[data: string,
      ok: bool] =
    var buffer: array[4096, char]
    while result.data.len <= limit:
      let received = when defined(windows):
        nativeSockets.recv(socket, addr buffer[0], buffer.len.cint, 0.cint)
      else:
        nativeSockets.recv(socket, addr buffer[0], buffer.len, 0.cint)
      if received == 0:
        result.ok = true
        return
      if received < 0:
        return
      if result.data.len + received > limit:
        return
      var chunk = newString(received)
      copyMem(addr chunk[0], addr buffer[0], received)
      result.data.add chunk

  proc tryForward(path, message: string): bool =
    let client = newInstanceSocket()
    if client == invalidInstanceSocket:
      return false
    defer: closeInstanceSocket(client)
    configureNoSigpipe(client)
    if connectInstanceSocket(client, path) != 0:
      return false
    result = true
    setSocketTimeout(client)
    discard sendAll(client, message)
    when defined(windows):
      discard winlean.shutdown(client, 1.cint) # SD_SEND
    else:
      discard posix.shutdown(client, posix.SHUT_WR)
    discard readToEnd(client, 1)

  proc unlinkSocketIfOwned(path: string; expected: FileInfo;
      hasExpected: bool) =
    if path.len == 0 or not hasExpected:
      return
    try:
      let current = getFileInfo(path, followSymlink = false)
      if current.id == expected.id:
        removeFile(path)
    except CatchableError:
      discard

  proc makeListener(path: string): tuple[socket: InstanceSocket,
      error: int32] =
    result.socket = newInstanceSocket()
    if result.socket == invalidInstanceSocket:
      result.error = socketError()
      return
    configureNoSigpipe(result.socket)
    if bindInstanceSocket(result.socket, path) != 0:
      result.error = socketError()
      closeInstanceSocket(result.socket)
      result.socket = invalidInstanceSocket
      return
    when defined(posix):
      try:
        setFilePermissions(path, {fpUserRead, fpUserWrite})
      except CatchableError:
        result.error = 1
        closeInstanceSocket(result.socket)
        result.socket = invalidInstanceSocket
        try: removeFile(path)
        except CatchableError: discard
        return
    if nativeSockets.listen(result.socket, 16) != 0:
      result.error = socketError()
      closeInstanceSocket(result.socket)
      result.socket = invalidInstanceSocket
      try: removeFile(path)
      except CatchableError: discard

  proc dispatchSecondInstance(message: SecondInstanceMessage) {.gcsafe.} =
    {.cast(gcsafe).}:
      discard postMain(proc() =
        for fn in singleInstance.handlers.snapshot():
          fn(message.args, message.workingDir)
        deliverArgs(message.args, message.workingDir))

  proc receiveSecondInstance(socket: InstanceSocket) =
    defer: closeInstanceSocket(socket)
    setSocketTimeout(socket)
    let (raw, complete) = readToEnd(socket, maxSecondInstanceMessage)
    if not complete:
      return
    try:
      let node = parseJson(raw)
      var message = SecondInstanceMessage(
        workingDir: node["workingDir"].getStr())
      for arg in node["args"].getElems():
        if arg.kind != JString:
          return
        message.args.add arg.getStr()
      dispatchSecondInstance(message)
    except CatchableError:
      discard

  proc acceptSecondInstances(listener: InstanceSocket) {.thread.} =
    {.cast(gcsafe).}:
      while true:
        let client = nativeSockets.accept(listener, nil, nil)
        if client == invalidInstanceSocket:
          return
        receiveSecondInstance(client)

  proc socketPath(name: string): string =
    let digest = sha256.sha256Hex(name)[0 ..< 12]
    when defined(windows):
      result = getTempDir() / ("mynim-" & digest & ".sock")
      if result.len >= winUnixPathLength:
        result = getEnv("LOCALAPPDATA") / "Temp" /
          ("mynim-" & digest & ".sock")
    else:
      let filename = "mynim-" & $posix.getuid() & "-" & digest & ".sock"
      for dir in [getEnv("XDG_RUNTIME_DIR"), getTempDir(), "/tmp"]:
        if dir != "" and (dir / filename).len <
            min(90, nativeSockets.Sockaddr_un_path_length):
          return dir / filename
      "/tmp" / filename

  proc singleInstanceKey(name: string): string =
    let (info, ok) = packageInfo()
    if ok and info.identifier != "":
      info.identifier & "\n" & name
    else:
      name

  proc releaseSingleInstanceLock() =
    singleInstance.mu.acquire()
    defer: singleInstance.mu.release()
    let listener = singleInstance.listener
    let path = singleInstance.path
    let info = singleInstance.socketInfo
    let hasInfo = singleInstance.hasSocketInfo
    let threadStarted = singleInstance.threadStarted
    singleInstance.listener = invalidInstanceSocket
    singleInstance.path.setLen(0)
    singleInstance.hasSocketInfo = false
    singleInstance.threadStarted = false
    singleInstance.locked = false
    if listener != invalidInstanceSocket:
      closeInstanceSocket(listener)
    if threadStarted:
      joinThread(singleInstance.listenerThread)
    unlinkSocketIfOwned(path, info, hasInfo)

proc requestSingleInstanceLock*(a: Application): bool =
  ## Ensures only one instance of this app runs. A later launch forwards
  ## its command-line arguments and working directory, then returns false
  ## so it can exit. Call before app.run.
  let generate = getEnv("NIM_XPLAT_GENERATE",
    getEnv("MYNIM_GENERATE", getEnv("MYGO_GENERATE")))
  if generate != "":
    return true
  when defined(windows) or (defined(posix) and not defined(emscripten)):
    singleInstance.mu.acquire()
    defer: singleInstance.mu.release()
    if singleInstance.locked:
      return true
    let path = socketPath(singleInstanceKey(a.name()))
    let message = $(%*{
      "args": commandLineParams(),
      "workingDir": getCurrentDir()
    })
    for attempt in 0 ..< 5:
      if tryForward(path, message):
        if devLaunched:
          stderr.writeLine("mynim: " & a.name() &
            " is already running: handed the command line over to it " &
            "(app.requestSingleInstanceLock)")
        return false
      try: removeFile(path)
      except CatchableError: discard
      let (listener, error) = makeListener(path)
      if listener != invalidInstanceSocket:
        singleInstance.listener = listener
        singleInstance.path = path
        try:
          singleInstance.socketInfo = getFileInfo(path, followSymlink = false)
          singleInstance.hasSocketInfo = true
        except CatchableError:
          singleInstance.hasSocketInfo = false
        singleInstance.locked = true
        try:
          createThread(singleInstance.listenerThread, acceptSecondInstances,
            listener)
          singleInstance.threadStarted = true
        except CatchableError:
          singleInstance.locked = false
          singleInstance.listener = invalidInstanceSocket
          closeInstanceSocket(listener)
          unlinkSocketIfOwned(path, singleInstance.socketInfo,
            singleInstance.hasSocketInfo)
          singleInstance.hasSocketInfo = false
          return true
        discard a.onQuit(releaseSingleInstanceLock)
        return true
      if not addressInUse(error):
        return true
      sleep((attempt + 1) * 20)
    true
  else:
    true

proc onSecondInstance*(a: Application;
    fn: proc(args: seq[string], workingDir: string) {.closure.}):
    proc() {.closure.} =
  ## Called in the running instance when a later launch forwards its
  ## arguments. The callback runs on the application main thread.
  singleInstance.handlers.add(fn, false)
