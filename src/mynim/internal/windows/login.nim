## login.nim (login.go): starting at login, a value in the Run key of
## the user. Task Manager's Startup page turns it off without
## removing it, in StartupApproved.

const
  runKey* = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
  approvedKey* = "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run"

proc loginCommand(arg: string): string =
  var exe = getAppFilename()
  try:
    let real = expandSymlink(exe)
    if real != "":
      exe = real
  except OSError:
    discard
  "\"" & exe & "\" " & arg

method setOpenAtLogin*(a: appController, open: bool, id, name,
    arg: string) =
  if not open:
    let e = regDeleteValue(hkeyCurrentUser, runKey, id)
    if not e.isNil:
      raise e
    let e2 = regDeleteValue(hkeyCurrentUser, approvedKey, id)
    if not e2.isNil:
      raise e2
    return
  let cmd = loginCommand(arg)
  let e = regSet(hkeyCurrentUser, runKey, id, cmd)
  if not e.isNil:
    raise e
  ## Turned off in Task Manager earlier: the app asks for it again.
  let e2 = regDeleteValue(hkeyCurrentUser, approvedKey, id)
  if not e2.isNil:
    raise e2

method openAtLogin*(a: appController, id, name, arg: string): bool =
  let cmd = loginCommand(arg)
  let (got, ok) = regGet(hkeyCurrentUser, runKey, id)
  if not ok or not got.equalsIgnoreCase(cmd):
    return false
  ## The first byte is odd when the entry is turned off.
  let (state, ok2) = regGetBytes(hkeyCurrentUser, approvedKey, id)
  not ok2 or state.len == 0 or (state[0] and 1) == 0

## openedAtLogin reports false: the Run entry passes the login
## argument instead.
method openedAtLogin*(a: appController): bool = false
