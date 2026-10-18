## Pseudo-terminal process support for the native Terminal plugin.

import std/[os, strutils]

type
  PtyOptions* = object
    path*: string
    args*: seq[string]
    dir*: string
    env*: seq[string]
    cols*, rows*, width*, height*: int

  Pty* = ref object
    when defined(macosx) or defined(linux):
      master: cint
      processId: cint
      waited: bool
      exitCode: int
    else:
      unsupported: bool

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

proc checkedCString(value, label: string): string =
  if value.find('\0') >= 0:
    raise newException(ValueError, "pty: " & label & " contains NUL")
  value

proc currentEnvironment(): seq[string] =
  for key, value in envPairs():
    result.add key & "=" & value

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
    Pty(master: master, processId: child)
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
    if pty.master < 0:
      return 0
    while true:
      let count = posix.read(pty.master, addr buffer[0], buffer.len)
      if count >= 0:
        return count
      let error = osLastError()
      if error.int == EINTR:
        continue
      if error.int == EIO or error.int == EBADF:
        return 0
      raiseOSError(error, "pty: reading")
  else:
    raise newException(IOError, "pty: read is unsupported on this platform")

proc write*(pty: Pty; buffer: openArray[byte]): int =
  ## Writes input to the attached process.
  if pty.isNil:
    raise newException(ValueError, "pty: process is nil")
  if buffer.len == 0:
    return 0
  when defined(macosx) or defined(linux):
    if pty.master < 0:
      raise newException(IOError, "pty: closed")
    while true:
      let count = posix.write(pty.master, unsafeAddr buffer[0], buffer.len)
      if count >= 0:
        return count
      let error = osLastError()
      if error.int == EINTR:
        continue
      if error.int == EBADF:
        raise newException(IOError, "pty: closed")
      raiseOSError(error, "pty: writing")
  else:
    raise newException(IOError, "pty: write is unsupported on this platform")

proc resize*(pty: Pty; cols, rows: int; width = 0; height = 0) =
  ## Changes the cell and pixel size; the OS notifies the foreground process.
  if pty.isNil:
    raise newException(ValueError, "pty: process is nil")
  when defined(macosx) or defined(linux):
    if pty.master < 0:
      raise newException(IOError, "pty: closed")
    if cSetSize(pty.master, cint(min(max(0, cols), 0xFFFF)),
        cint(min(max(0, rows), 0xFFFF)),
        cint(min(max(0, width), 0xFFFF)),
        cint(min(max(0, height), 0xFFFF))) < 0:
      raiseOSError(osLastError(), "pty: resizing")
  else:
    raise newException(IOError, "pty: resize is unsupported on this platform")

proc pid*(pty: Pty): int =
  if pty.isNil:
    return 0
  when defined(macosx) or defined(linux):
    int(pty.processId)
  else:
    0

proc wait*(pty: Pty): int =
  ## Waits for the process to exit; signal exits use the conventional 128+N.
  if pty.isNil:
    raise newException(ValueError, "pty: process is nil")
  when defined(macosx) or defined(linux):
    if pty.waited:
      return pty.exitCode
    var status: cint
    while true:
      let waited = posix.waitpid(Pid(pty.processId), status, 0)
      if waited == Pid(pty.processId):
        pty.waited = true
        pty.exitCode = int(cExitCode(status))
        return pty.exitCode
      if osLastError().int != EINTR:
        raiseOSError(osLastError(), "pty: waiting")
  else:
    raise newException(IOError, "pty: wait is unsupported on this platform")

proc close*(pty: Pty) =
  ## Closes the master side; Unix sends SIGHUP to processes using its slave.
  if pty.isNil:
    return
  when defined(macosx) or defined(linux):
    if pty.master >= 0:
      discard posix.close(pty.master)
      pty.master = -1

proc kill*(pty: Pty) =
  ## Kills the process group created for this PTY, then falls back to its PID.
  if pty.isNil:
    return
  when defined(macosx) or defined(linux):
    if pty.processId <= 0 or pty.waited:
      return
    if posix.kill(Pid(-pty.processId), SIGKILL) < 0 and
        posix.kill(Pid(pty.processId), SIGKILL) < 0:
      raiseOSError(osLastError(), "pty: killing")
