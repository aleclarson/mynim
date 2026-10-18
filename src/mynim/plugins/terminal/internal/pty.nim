## Pseudo-terminal process support for the native Terminal plugin.

import std/[os, strutils]
when defined(macosx) or defined(linux) or defined(windows):
  import std/locks
when defined(windows):
  import std/[widestrs, winlean]

type
  PtyOptions* = object
    path*: string
    args*: seq[string]
    dir*: string
    env*: seq[string]
    cols*, rows*, width*, height*: int

  PtyData = object
    when defined(macosx) or defined(linux) or defined(windows):
      guard: Lock
      waitCondition: Cond
      processId: int
      waited, waitInProgress: bool
      exitCode: int
    when defined(macosx) or defined(linux):
      master: cint
    elif defined(windows):
      console: pointer
      input, output, process: Handle
      closing: bool
    else:
      unsupported: bool

  Pty* = ref PtyData

when defined(macosx) or defined(linux) or defined(windows):
  proc `=destroy`(pty: var PtyData) =
    deinitCond(pty.waitCondition)
    deinitLock(pty.guard)

when defined(macosx) or defined(linux):
  import std/posix
  {.compile: "pty_posix.c".}

  proc cOpenMaster(slaveName: cstring; capacity: csize_t): cint
    {.importc: "mynim_pty_open_master", cdecl.}
  proc cOpenSlave(slaveName: cstring): cint
    {.importc: "mynim_pty_open_slave", cdecl.}
  proc cSetSize(master: cint; cols, rows, width, height: cint): cint
    {.importc: "mynim_pty_set_size", cdecl.}
  proc cSpawn(master, slave: cint; path: cstring; args, env: cstringArray;
      dir: cstring): cint {.importc: "mynim_pty_spawn", cdecl.}
  proc cExitCode(status: cint): cint
    {.importc: "mynim_pty_exit_code", cdecl.}

  proc duplicateMaster(pty: Pty): cint =
    pty.guard.acquire()
    let master = pty.master
    if master < 0:
      pty.guard.release()
      return -1
    result = posix.dup(master)
    if result >= 0 and posix.fcntl(result, F_SETFD, FD_CLOEXEC) < 0:
      let error = osLastError()
      discard posix.close(result)
      result = -1
      pty.guard.release()
      raiseOSError(error, "pty: duplicating master")
    let error = osLastError()
    pty.guard.release()
    if result < 0:
      raiseOSError(error, "pty: duplicating master")

when defined(windows):
  type
    ConsoleCoord {.bycopy.} = object
      x, y: int16
    StartupInfoEx {.bycopy.} = object
      startup: STARTUPINFO
      attributes: pointer

  const
    procThreadAttributePseudoConsole = 0x00020016'u32
    extendedStartupInfoPresent = 0x00080000'i32
    errorBrokenPipe = 109'i32
    errorNoData = 232'i32
    errorInvalidHandle = 6'i32

  proc createPseudoConsole(size: ConsoleCoord; input, output: Handle;
      flags: uint32; console: ptr pointer): int32
      {.stdcall, dynlib: "kernel32.dll", importc: "CreatePseudoConsole".}
  proc resizePseudoConsole(console: pointer; size: ConsoleCoord): int32
      {.stdcall, dynlib: "kernel32.dll", importc: "ResizePseudoConsole".}
  proc closePseudoConsole(console: pointer)
      {.stdcall, dynlib: "kernel32.dll", importc: "ClosePseudoConsole".}
  proc initializeAttributeList(list: pointer; count, flags: uint32;
      size: ptr csize_t): WINBOOL
      {.stdcall, dynlib: "kernel32.dll",
        importc: "InitializeProcThreadAttributeList".}
  proc updateAttributeList(list: pointer; flags, attribute: uint32;
      value: pointer; size: csize_t; previous: pointer;
      returnSize: ptr csize_t): WINBOOL
      {.stdcall, dynlib: "kernel32.dll",
        importc: "UpdateProcThreadAttribute".}
  proc deleteAttributeList(list: pointer)
      {.stdcall, dynlib: "kernel32.dll",
        importc: "DeleteProcThreadAttributeList".}
  {.compile: "pty_windows.c".}
  proc cCloseConsoleAsync(console: pointer; output: Handle): cint
    {.importc: "mynim_pty_close_console_async", cdecl.}

proc checkedCString(value, label: string): string =
  if value.find('\0') >= 0:
    raise newException(ValueError, "pty: " & label & " contains NUL")
  value

when defined(macosx) or defined(linux):
  proc currentEnvironment(): seq[string] =
    for key, value in envPairs():
      result.add key & "=" & value

when defined(windows):
  proc quoteArgument(value: string): string =
    result.add '"'
    var slashes = 0
    for ch in value:
      if ch == '\\':
        inc slashes
      elif ch == '"':
        result.add repeat('\\', slashes * 2 + 1)
        result.add '"'
        slashes = 0
      else:
        result.add repeat('\\', slashes)
        slashes = 0
        result.add ch
    result.add repeat('\\', slashes * 2)
    result.add '"'

  proc commandLine(path: string; args: openArray[string]): string =
    result = quoteArgument(path)
    for index in 1 ..< args.len:
      result.add ' '
      result.add quoteArgument(args[index])

  proc environmentBlock(values: openArray[string]): seq[Utf16Char] =
    for value in values:
      let wide = newWideCString(checkedCString(value, "environment"))
      for index in 0 .. wide.len:
        result.add wide[index]
    result.add Utf16Char(0)

  proc processOptions(pty: Pty; options: PtyOptions) =
    var attributeSize: csize_t
    discard initializeAttributeList(nil, 1, 0, addr attributeSize)
    if attributeSize == 0:
      raiseOSError(osLastError(), "pty: sizing process attributes")
    let attributes = cast[pointer](allocShared0(int(attributeSize)))
    if attributes.isNil:
      raise newException(OutOfMemDefect, "pty: allocating process attributes")
    defer:
      deleteAttributeList(attributes)
      deallocShared(attributes)
    if initializeAttributeList(attributes, 1, 0, addr attributeSize) == 0:
      raiseOSError(osLastError(), "pty: initializing process attributes")
    if updateAttributeList(attributes, 0, procThreadAttributePseudoConsole,
        pty.console, csize_t(sizeof(pointer)), nil, nil) == 0:
      raiseOSError(osLastError(), "pty: attaching ConPTY")

    var startup: StartupInfoEx
    startup.startup.cb = int32(sizeof(startup))
    startup.startup.dwFlags = STARTF_USESTDHANDLES
    startup.startup.hStdInput = INVALID_HANDLE_VALUE
    startup.startup.hStdOutput = INVALID_HANDLE_VALUE
    startup.startup.hStdError = INVALID_HANDLE_VALUE
    startup.attributes = attributes

    let path = checkedCString(options.path, "program path")
    var args = if options.args.len == 0: @[path] else: options.args
    for index in 0 ..< args.len:
      args[index] = checkedCString(args[index], "argument")
    let appWide = newWideCString(path)
    let lineWide = newWideCString(commandLine(path, args))
    var directoryWide: WideCStringObj
    var directory: WideCString
    if options.dir.len > 0:
      directoryWide = newWideCString(checkedCString(options.dir,
        "working directory"))
      directory = directoryWide

    var environment: seq[Utf16Char]
    var environmentWide: WideCString
    if options.env.len > 0:
      environment = environmentBlock(options.env)
      environmentWide = cast[WideCString](addr environment[0])
    var info: PROCESS_INFORMATION
    if createProcessW(appWide, lineWide, nil, nil, 0,
        extendedStartupInfoPresent or CREATE_UNICODE_ENVIRONMENT,
        environmentWide, directory, startup.startup, info) == 0:
      raiseOSError(osLastError(), "pty: starting " & path)
    discard closeHandle(info.hThread)
    pty.process = info.hProcess
    pty.processId = int(info.dwProcessId)

proc close*(pty: Pty)

proc start*(options: PtyOptions): Pty =
  ## Starts the requested program attached to a controlling pseudo-terminal.
  if options.path.len == 0:
    raise newException(ValueError, "pty: program path is empty")
  when defined(macosx) or defined(linux):
    let path = checkedCString(options.path, "program path")
    let workDir = checkedCString(options.dir, "working directory")
    var args = if options.args.len == 0: @[path] else: options.args
    for index in 0 ..< args.len:
      args[index] = checkedCString(args[index], "argument")
    var environment = if options.env.len == 0:
      currentEnvironment() else: options.env
    for index in 0 ..< environment.len:
      environment[index] = checkedCString(environment[index], "environment")
    var argv = allocCStringArray(args)
    defer: deallocCStringArray(argv)
    var envp = allocCStringArray(environment)
    defer: deallocCStringArray(envp)

    var slaveName: array[256, char]
    let master = cOpenMaster(cast[cstring](addr slaveName[0]),
      csize_t(slaveName.len))
    if master < 0:
      raiseOSError(osLastError(), "pty: opening master")
    var slave = cOpenSlave(cast[cstring](addr slaveName[0]))
    if slave < 0:
      let error = osLastError()
      discard posix.close(master)
      raiseOSError(error, "pty: opening slave")
    let cols = if options.cols > 0: options.cols else: 80
    let rows = if options.rows > 0: options.rows else: 24
    if cSetSize(master, cint(min(cols, 0xFFFF)), cint(min(rows, 0xFFFF)),
        cint(min(max(0, options.width), 0xFFFF)),
        cint(min(max(0, options.height), 0xFFFF))) < 0:
      let error = osLastError()
      discard posix.close(slave)
      discard posix.close(master)
      raiseOSError(error, "pty: setting initial size")

    let child = cSpawn(master, slave, path.cstring, argv, envp,
      if workDir.len == 0: nil else: workDir.cstring)
    slave = -1
    if child < 0:
      let error = osLastError()
      discard posix.close(master)
      raiseOSError(error, "pty: starting " & path)
    new(result)
    initLock(result.guard)
    initCond(result.waitCondition)
    result.master = master
    result.processId = int(child)
  elif defined(windows):
    discard checkedCString(options.path, "program path")
    let cols = if options.cols > 0: options.cols else: 80
    let rows = if options.rows > 0: options.rows else: 24
    new(result)
    initLock(result.guard)
    initCond(result.waitCondition)
    var inputRead, inputWrite, outputRead, outputWrite: Handle
    var attributes: SECURITY_ATTRIBUTES
    attributes.nLength = int32(sizeof(SECURITY_ATTRIBUTES))
    if createPipe(inputRead, inputWrite, attributes, 0) == 0:
      raiseOSError(osLastError(), "pty: creating input pipe")
    if createPipe(outputRead, outputWrite, attributes, 0) == 0:
      let error = osLastError()
      discard closeHandle(inputRead)
      discard closeHandle(inputWrite)
      raiseOSError(error, "pty: creating output pipe")
    var console: pointer
    var status: int32
    try:
      status = createPseudoConsole(
        ConsoleCoord(x: int16(min(cols, 0x7FFF)),
          y: int16(min(rows, 0x7FFF))), inputRead, outputWrite, 0, addr console)
    except CatchableError:
      discard closeHandle(inputRead)
      discard closeHandle(inputWrite)
      discard closeHandle(outputRead)
      discard closeHandle(outputWrite)
      raise newException(IOError,
        "pty: ConPTY needs Windows 10 1809 or later")
    discard closeHandle(inputRead)
    discard closeHandle(outputWrite)
    if status != 0:
      discard closeHandle(inputWrite)
      discard closeHandle(outputRead)
      raise newException(IOError,
        "pty: CreatePseudoConsole failed with HRESULT 0x" &
        toHex(cast[uint32](status), 8))
    result.console = console
    result.input = inputWrite
    result.output = outputRead
    try:
      result.processOptions(options)
    except CatchableError:
      result.close()
      raise
  else:
    raise newException(IOError,
      "pty: ConPTY is not implemented on this platform")

proc read*(pty: Pty; buffer: var openArray[byte]): int =
  ## Reads output; returns zero at end of file or after closing the PTY.
  if pty.isNil:
    raise newException(ValueError, "pty: process is nil")
  if buffer.len == 0:
    return 0
  when defined(macosx) or defined(linux):
    let master = duplicateMaster(pty)
    if master < 0:
      return 0
    defer: discard posix.close(master)
    while true:
      let count = posix.read(master, addr buffer[0], buffer.len)
      if count >= 0:
        return count
      let error = osLastError()
      if error.int == EINTR:
        continue
      if error.int == EIO or error.int == EBADF:
        return 0
      raiseOSError(error, "pty: reading")
  elif defined(windows):
    pty.guard.acquire()
    let output = pty.output
    pty.guard.release()
    if output == 0:
      return 0
    var count: int32
    if readFile(output, addr buffer[0],
        int32(min(buffer.len, high(int32).int)), addr count, nil) != 0:
      if count == 0 and pty.closing:
        pty.guard.acquire()
        if pty.output == output:
          pty.output = 0
        pty.guard.release()
      return int(count)
    let error = getLastError()
    if error in [errorBrokenPipe, errorNoData, errorInvalidHandle]:
      pty.guard.acquire()
      if pty.output == output:
        pty.output = 0
      pty.guard.release()
      return 0
    raiseOSError(OSErrorCode(error), "pty: reading")
  else:
    raise newException(IOError, "pty: read is unsupported on this platform")

proc write*(pty: Pty; buffer: openArray[byte]): int =
  ## Writes input to the attached process.
  if pty.isNil:
    raise newException(ValueError, "pty: process is nil")
  if buffer.len == 0:
    return 0
  when defined(macosx) or defined(linux):
    let master = duplicateMaster(pty)
    if master < 0:
      raise newException(IOError, "pty: closed")
    defer: discard posix.close(master)
    while true:
      let count = posix.write(master, unsafeAddr buffer[0], buffer.len)
      if count >= 0:
        return count
      let error = osLastError()
      if error.int == EINTR:
        continue
      if error.int == EBADF:
        raise newException(IOError, "pty: closed")
      raiseOSError(error, "pty: writing")
  elif defined(windows):
    pty.guard.acquire()
    let input = pty.input
    pty.guard.release()
    if input == 0:
      raise newException(IOError, "pty: closed")
    var count: int32
    if writeFile(input, unsafeAddr buffer[0],
        int32(min(buffer.len, high(int32).int)), addr count, nil) != 0:
      return int(count)
    let error = getLastError()
    if error in [errorBrokenPipe, errorNoData, errorInvalidHandle]:
      raise newException(IOError, "pty: closed")
    raiseOSError(OSErrorCode(error), "pty: writing")
  else:
    raise newException(IOError, "pty: write is unsupported on this platform")

proc resize*(pty: Pty; cols, rows: int; width = 0; height = 0) =
  ## Changes the cell and pixel size; the OS notifies the foreground process.
  if pty.isNil:
    raise newException(ValueError, "pty: process is nil")
  when defined(macosx) or defined(linux):
    pty.guard.acquire()
    if pty.master < 0:
      pty.guard.release()
      raise newException(IOError, "pty: closed")
    let status = cSetSize(pty.master, cint(min(max(0, cols), 0xFFFF)),
        cint(min(max(0, rows), 0xFFFF)),
        cint(min(max(0, width), 0xFFFF)),
        cint(min(max(0, height), 0xFFFF)))
    let error = osLastError()
    pty.guard.release()
    if status < 0:
      raiseOSError(error, "pty: resizing")
  elif defined(windows):
    pty.guard.acquire()
    let console = pty.console
    if console.isNil:
      pty.guard.release()
      raise newException(IOError, "pty: closed")
    let status = resizePseudoConsole(console, ConsoleCoord(
      x: int16(max(1, min(cols, 0x7FFF))),
      y: int16(max(1, min(rows, 0x7FFF)))))
    pty.guard.release()
    if status != 0:
      raise newException(IOError,
        "pty: ResizePseudoConsole failed with HRESULT 0x" &
        toHex(cast[uint32](status), 8))
  else:
    raise newException(IOError, "pty: resize is unsupported on this platform")

proc pid*(pty: Pty): int =
  if pty.isNil:
    return 0
  when defined(macosx) or defined(linux):
    int(pty.processId)
  elif defined(windows):
    pty.processId
  else:
    0

proc wait*(pty: Pty): int =
  ## Waits for the process to exit; signal exits use the conventional 128+N.
  if pty.isNil:
    raise newException(ValueError, "pty: process is nil")
  when defined(macosx) or defined(linux):
    pty.guard.acquire()
    while pty.waitInProgress and not pty.waited:
      wait(pty.waitCondition, pty.guard)
    if pty.waited:
      let code = pty.exitCode
      pty.guard.release()
      return code
    let processId = pty.processId
    pty.waitInProgress = true
    pty.guard.release()
    var status: cint
    while true:
      let waited = posix.waitpid(Pid(processId), status, 0)
      if waited == Pid(processId):
        let code = int(cExitCode(status))
        pty.guard.acquire()
        pty.waited = true
        pty.waitInProgress = false
        pty.exitCode = code
        broadcast(pty.waitCondition)
        pty.guard.release()
        return code
      let error = osLastError()
      if error.int == EINTR:
        continue
      pty.guard.acquire()
      pty.waitInProgress = false
      broadcast(pty.waitCondition)
      pty.guard.release()
      raiseOSError(error, "pty: waiting")
  elif defined(windows):
    pty.guard.acquire()
    while pty.waitInProgress and not pty.waited:
      wait(pty.waitCondition, pty.guard)
    if pty.waited:
      let code = pty.exitCode
      pty.guard.release()
      return code
    let process = pty.process
    if process == 0:
      pty.guard.release()
      raise newException(IOError, "pty: process has not started")
    pty.waitInProgress = true
    pty.guard.release()
    if waitForSingleObject(process, INFINITE) != WAIT_OBJECT_0:
      let error = osLastError()
      pty.guard.acquire()
      pty.waitInProgress = false
      broadcast(pty.waitCondition)
      pty.guard.release()
      raiseOSError(error, "pty: waiting")
    var code: int32
    if getExitCodeProcess(process, code) == 0:
      let error = osLastError()
      pty.guard.acquire()
      pty.waitInProgress = false
      broadcast(pty.waitCondition)
      pty.guard.release()
      raiseOSError(error, "pty: reading exit code")
    pty.guard.acquire()
    pty.waited = true
    pty.waitInProgress = false
    pty.exitCode = int(code)
    pty.process = 0
    broadcast(pty.waitCondition)
    pty.guard.release()
    discard closeHandle(process)
    int(code)
  else:
    raise newException(IOError, "pty: wait is unsupported on this platform")

proc close*(pty: Pty) =
  ## Hangs up the Unix slave or closes ConPTY after draining its output.
  if pty.isNil:
    return
  when defined(macosx) or defined(linux):
    pty.guard.acquire()
    let master = pty.master
    if master < 0:
      pty.guard.release()
      return
    let processId = pty.processId
    let waited = pty.waited
    pty.master = -1
    pty.guard.release()
    if processId > 0 and not waited and
        posix.kill(Pid(-processId), SIGHUP) < 0:
      discard posix.kill(Pid(processId), SIGHUP)
    discard posix.close(master)
  elif defined(windows):
    pty.guard.acquire()
    if pty.closing:
      pty.guard.release()
      return
    pty.closing = true
    let console = pty.console
    let input = pty.input
    let output = pty.output
    pty.console = nil
    pty.input = 0
    if console.isNil:
      pty.output = 0
    pty.guard.release()
    if input != 0:
      discard closeHandle(input)
    if console.isNil:
      if output != 0:
        discard closeHandle(output)
    else:
      if cCloseConsoleAsync(console, output) == 0:
        pty.guard.acquire()
        pty.output = 0
        pty.guard.release()
        if output != 0:
          discard closeHandle(output)
        closePseudoConsole(console)

proc kill*(pty: Pty) =
  ## Kills the process group created for this PTY, then falls back to its PID.
  if pty.isNil:
    return
  when defined(macosx) or defined(linux):
    pty.guard.acquire()
    let processId = pty.processId
    let waited = pty.waited
    pty.guard.release()
    if processId <= 0 or waited:
      return
    if posix.kill(Pid(-processId), SIGKILL) < 0 and
        posix.kill(Pid(processId), SIGKILL) < 0:
      raiseOSError(osLastError(), "pty: killing")
  elif defined(windows):
    pty.guard.acquire()
    let process = pty.process
    if process == 0 or pty.waited:
      pty.guard.release()
      return
    let terminated = terminateProcess(process, 1)
    let error = if terminated == 0: osLastError() else: OSErrorCode(0)
    pty.guard.release()
    if terminated == 0:
      raiseOSError(error, "pty: killing")
