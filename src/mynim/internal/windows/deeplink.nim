## deeplink.nim (deeplink.go): URL schemes registered for the current
## user under HKEY_CURRENT_USER\Software\Classes\<scheme>, whose
## shell\open\command runs the executable with the URL.

proc schemeKey(scheme: string): string = "Software\\Classes\\" & scheme

## openCommand is the command that opens URLs with this executable.
proc openCommand(): tuple[cmd: string, err: ref CatchableError] =
  var exe: string
  try:
    exe = getAppFilename()
    let real = expandSymlink(exe)
    if real != "":
      exe = real
  except OSError as e:
    return ("", e)
  ("\"" & exe & "\" \"%1\"", nil)

method registerURLScheme*(a: appController, scheme, id, name: string) =
  let (cmd, err) = openCommand()
  if not err.isNil:
    raise err
  let key = schemeKey(scheme)
  let exe = cmd[1 ..< cmd.len - " \"%1\"".len - 1]
  for v in [(key, "", "URL:" & name),
            (key, "URL Protocol", ""),
            (key & "\\DefaultIcon", "", "\"" & exe & "\",0"),
            (key & "\\shell\\open\\command", "", cmd)]:
    let e = regSet(hkeyCurrentUser, v[0], v[1], v[2])
    if not e.isNil:
      raise e

method unregisterURLScheme*(a: appController, scheme, id,
    name: string) =
  if not a.isURLSchemeRegistered(scheme, id, name):
    return ## another application's, or none
  let e = regDeleteTree(hkeyCurrentUser, schemeKey(scheme))
  if not e.isNil:
    raise e

method isURLSchemeRegistered*(a: appController, scheme, id,
    name: string): bool =
  let (cmd, err) = openCommand()
  if not err.isNil:
    return false
  let (got, ok) = regGet(hkeyCurrentUser,
    schemeKey(scheme) & "\\shell\\open\\command", "")
  ok and got.equalsIgnoreCase(cmd)
