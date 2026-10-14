## login.nim: starting at login follows the XDG autostart specification:
## a desktop entry in $XDG_CONFIG_HOME/autostart.

proc autostartEntry(id: string): string =
  xdgDir("XDG_CONFIG_HOME", ".config") / "autostart" /
    desktopName(id) & ".desktop"

method setOpenAtLogin*(a: appController, `open`: bool, id, name,
    arg: string) =
  let path = autostartEntry(id)
  if not `open`:
    try:
      removeFile(path)
    except OSError as e:
      if fileExists(path) or symlinkExists(path):
        raise e
    return
  let (exe, err) = executable()
  if not err.isNil: raise err
  try:
    createDir(parentDir(path))
  except OSError as e:
    raise e
  let entry = "[Desktop Entry]\nType=Application\nName=" &
    entryString(name) & "\nExec=" & execArg(exe) & " " & arg &
    "\nTerminal=false\nX-GNOME-Autostart-enabled=true\n"
  let e = writeFileAtomic(path, entry)
  if not e.isNil: raise e

method openAtLogin*(a: appController, id, name, arg: string): bool =
  let data = try: readFile(autostartEntry(id)) except IOError: return false
  for line in data.split('\n'):
    case line.strip()
    of "Hidden=true", "X-GNOME-Autostart-enabled=false":
      return false # turned off in the desktop's settings
    else: discard
  true

## openedAtLogin reports false: the autostart entry passes the login
## argument instead.
method openedAtLogin*(a: appController): bool = false
