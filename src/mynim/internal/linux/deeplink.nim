## deeplink.nim: URL scheme handlers follow the XDG conventions: a
## desktop entry that opens URLs with the app, hidden from menus, is
## made the default handler of the scheme in the user's mimeapps.list,
## which is what `xdg-mime default` does.

## handlerEntry returns where the desktop entry of the app's URL handler
## goes, named after the app's identifier.
proc handlerEntry(id: string): tuple[dir, file: string] =
  (xdgDir("XDG_DATA_HOME", ".local/share") / "applications",
   desktopName(id) & ".url-handler.desktop")

proc handlerDesktopEntry(name, exe: string, schemes: seq[string]): string =
  var mime = ""
  for s in schemes:
    mime.add "x-scheme-handler/" & s & ";"
  "[Desktop Entry]\nType=Application\nName=" & entryString(name) &
    "\nExec=" & execArg(exe) &
    " %u\nTerminal=false\nNoDisplay=true\nMimeType=" & mime & "\n"

## handlerSchemes returns the schemes a handler entry declares.
proc handlerSchemes(path: string): seq[string] =
  let data = try: readFile(path) except IOError: ""
  for line in data.split('\n'):
    let t = line.strip()
    if t.startsWith("MimeType="):
      for m in t["MimeType=".len .. ^1].split(';'):
        if m.startsWith("x-scheme-handler/") and
            m.len > "x-scheme-handler/".len:
          result.add m["x-scheme-handler/".len .. ^1]

const defaultApps = "[Default Applications]"

proc mimeappsList(): string =
  xdgDir("XDG_CONFIG_HOME", ".config") / "mimeapps.list"

## mimeDefault returns the default application of a MIME type in the
## user's mimeapps.list.
proc mimeDefault(mime: string): string =
  let data = try: readFile(mimeappsList()) except IOError: ""
  var section = ""
  for line in data.split('\n'):
    let t = line.strip()
    if t.startsWith("["):
      section = t
      continue
    let eq = t.find('=')
    if eq >= 0 and section == defaultApps and
        t[0 ..< eq].strip() == mime:
      let v = t[eq + 1 .. ^1].strip()
      return v.split(';')[0]

## setMimeDefault makes file the default application of a MIME type in
## the user's mimeapps.list or, when file is "", removes the default if
## it is owner.
proc setMimeDefault(mime, file, owner: string): ref CatchableError =
  let path = mimeappsList()
  var data: string
  try:
    data = readFile(path)
  except IOError as e:
    if not fileExists(path) and not symlinkExists(path):
      data = ""
    else:
      return e
  var lines = data.strip(leading = false, chars = {'\n'}).split('\n')
  if data.len == 0:
    lines = @[]
  var start = -1
  var `end` = lines.len # the Default Applications section
  for i, line in lines:
    let t = line.strip()
    if start >= 0 and t.startsWith("["):
      `end` = i
      break
    if t == defaultApps:
      start = i
  let entry = mime & "=" & file
  var found = -1
  if start >= 0:
    for i in start + 1 ..< `end`:
      let eq = lines[i].find('=')
      if eq >= 0 and lines[i][0 ..< eq].strip() == mime:
        found = i
  if file == "":
    if found < 0: return nil
    let eq = lines[found].find('=')
    if lines[found][eq + 1 .. ^1].strip().dup(removeSuffix(";")) != owner:
      return nil # another application's
    lines.delete(found)
  elif found >= 0:
    lines[found] = entry
  elif start >= 0:
    lines.insert(entry, start + 1)
  else:
    if lines.len > 0:
      lines.add ""
    lines.add defaultApps
    lines.add entry
  try:
    createDir(parentDir(path))
  except OSError as e:
    return e
  writeFileAtomic(path, lines.join("\n") & "\n")

method registerURLScheme*(a: appController, scheme, id, name: string) =
  let (dir, file) = handlerEntry(id)
  let path = dir / file
  var schemes = handlerSchemes(path)
  if scheme notin schemes:
    schemes.add scheme
  let (exe, err) = executable()
  if not err.isNil: raise err
  try:
    createDir(dir)
  except OSError as e:
    raise e
  let e = writeFileAtomic(path, handlerDesktopEntry(name, exe, schemes))
  if not e.isNil: raise e
  let e2 = setMimeDefault("x-scheme-handler/" & scheme, file, "")
  if not e2.isNil: raise e2

method unregisterURLScheme*(a: appController, scheme, id, name: string) =
  let (dir, file) = handlerEntry(id)
  let path = dir / file
  var schemes = handlerSchemes(path)
  if scheme in schemes:
    schemes = schemes.filterIt(it != scheme)
    var err: ref CatchableError
    if schemes.len == 0:
      try:
        removeFile(path)
      except OSError as e:
        err = e
    else:
      let (exe, e) = executable()
      if not e.isNil:
        err = e
      else:
        err = writeFileAtomic(path, handlerDesktopEntry(name, exe, schemes))
    if not err.isNil: raise err
  let e = setMimeDefault("x-scheme-handler/" & scheme, "", file)
  if not e.isNil: raise e

method isURLSchemeRegistered*(a: appController, scheme, id,
    name: string): bool =
  let (dir, file) = handlerEntry(id)
  scheme in handlerSchemes(dir / file) and
    mimeDefault("x-scheme-handler/" & scheme) == file
