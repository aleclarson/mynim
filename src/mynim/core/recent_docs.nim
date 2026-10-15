## recent_docs.go — the app's persistent Open Recent list and the
## platform's recent-document integration.

import std/tempfiles
when defined(posix):
  from std/posix import fsync
elif defined(windows):
  import std/winlean as recentWin

type RecentDocumentsState = object
  mu: Lock
  loaded: bool
  paths: seq[string]

var recentDocs = block:
  var state: RecentDocumentsState
  state.mu.initLock()
  state

const maxRecentDocuments = 10

proc recentFile(): string =
  app.path(pathUserData) / "recent-documents.json"

## loadRecentLocked reads the persistent list once. recentDocs.mu is held.
proc loadRecentLocked() =
  if recentDocs.loaded:
    return
  recentDocs.loaded = true
  try:
    let data = parseJson(readFile(recentFile()))
    if data.kind == JArray:
      for item in data:
        if item.kind == JString:
          recentDocs.paths.add item.getStr()
  except CatchableError:
    discard

proc syncRecentFile(file: File) =
  file.flushFile()
  when defined(posix):
    if fsync(getFileHandle(file)) != 0:
      raiseOSError(osLastError())
  elif defined(windows):
    if recentWin.flushFileBuffers(
        cast[recentWin.Handle](getOsFileHandle(file))) == 0:
      raiseOSError(osLastError())

## writeRecentFile atomically replaces the app-owned JSON file.
proc writeRecentFile(path, data: string): ref CatchableError =
  var tempFile: File
  var tempPath = ""
  try:
    (tempFile, tempPath) = createTempFile(
      "." & path.extractFilename() & ".", ".tmp", path.parentDir())
    tempFile.write(data)
    syncRecentFile(tempFile)
    tempFile.close()
    tempFile = nil
    backend().replaceFile(path, tempPath)
    nil
  except CatchableError as e:
    if tempFile != nil:
      try:
        tempFile.close()
      except CatchableError:
        discard
    if tempPath != "" and fileExists(tempPath):
      try:
        removeFile(tempPath)
      except CatchableError:
        discard
    e

## saveRecentLocked writes the list and schedules the Open Recent menus to
## refresh. recentDocs.mu is held.
proc saveRecentLocked(): ref CatchableError =
  discard postMain(proc() = updateRecentMenus())
  try:
    let data = if recentDocs.paths.len == 0:
        $newJNull()
      else:
        $(%*recentDocs.paths)
    writeRecentFile(recentFile(), data)
  except CatchableError as e:
    e

proc combineRecentErrors(first, second: ref CatchableError):
    ref CatchableError =
  if first == nil: return second
  if second == nil: return first
  newException(IOError, first.msg & "\n" & second.msg)

proc addRecentDocument*(a: Application; path: string):
    ref CatchableError =
  ## Adds a file or directory to the app's Open Recent menu and the
  ## operating system's recent-document list.
  needsApp("app.addRecentDocument")
  if path == "":
    return newException(ValueError,
      "mynim: app.addRecentDocument needs a path")
  var absolute: string
  try:
    absolute = absolutePath(path)
  except CatchableError as e:
    return e

  recentDocs.mu.acquire()
  loadRecentLocked()
  var paths: seq[string]
  for oldPath in recentDocs.paths:
    if oldPath != absolute:
      paths.add oldPath
  paths.insert(absolute, 0)
  if paths.len > maxRecentDocuments:
    paths.setLen(maxRecentDocuments)
  recentDocs.paths = paths
  let fileErr = saveRecentLocked()
  recentDocs.mu.release()

  let platformErr = onMainValue(proc(): ref CatchableError =
    try:
      backend().app().addRecentDocument(absolute)
      nil
    except CatchableError as e:
      e)
  combineRecentErrors(fileErr, platformErr)

proc clearRecentDocuments*(a: Application): ref CatchableError =
  ## Empties the app's Open Recent menu and clears its entries from the
  ## operating system's recent-document list.
  needsApp("app.clearRecentDocuments")
  recentDocs.mu.acquire()
  recentDocs.loaded = true
  recentDocs.paths.setLen(0)
  let fileErr = saveRecentLocked()
  recentDocs.mu.release()

  let platformErr = onMainValue(proc(): ref CatchableError =
    try:
      backend().app().clearRecentDocuments()
      nil
    except CatchableError as e:
      e)
  combineRecentErrors(fileErr, platformErr)

proc recentDocuments*(a: Application): seq[string] =
  ## Returns up to ten existing files and directories, newest first.
  recentDocs.mu.acquire()
  loadRecentLocked()
  var paths: seq[string]
  for path in recentDocs.paths:
    paths.add path
  recentDocs.mu.release()
  for path in paths:
    if fileExists(path) or dirExists(path):
      result.add path

proc openRecentDocument(path: string) =
  ## Apps without a document controller receive recent selections as
  ## ordinary open-file events.
  fire1(app.onOpenFile, path)

proc addRecent(path: string) =
  ## Records an opened or saved document and logs failures. The document
  ## controller uses this for its own file operations.
  let err = app.addRecentDocument(path)
  if err != nil:
    stderr.writeLine("mynim: documents: " & err.msg)

proc recentMenuItems(): seq[MenuItem] =
  let paths = app.recentDocuments()
  for path in paths:
    let itemPath = path
    let name = path.extractFilename()
    result.add MenuItem(label: if name == "": path else: name,
      toolTip: path,
      click: proc(item: MenuItem; win: Window) =
        openRecentDocument(itemPath))
  if paths.len > 0:
    result.add separator()
  let clearDisabled = paths.len == 0
  result.add MenuItem(label: menuMessages().menuClearRecent(),
    disabled: clearDisabled,
    click: proc(item: MenuItem; win: Window) =
      goAsync(proc() =
        let err = app.clearRecentDocuments()
        if err != nil:
          stderr.writeLine("mynim: recent documents: " & err.msg)))

proc refreshRecentMenu(m: Menu; changed: var bool) =
  if m == nil:
    return
  for item in m.items():
    if item.role == roleOpenRecent:
      let items = recentMenuItems()
      menuMu.acquire()
      let sub = Menu()
      for child in items:
        sub.items.add prepareItem(child, sub)
      item.submenu = items
      item.sub = sub
      menuMu.release()
      changed = true
    elif item.sub != nil:
      refreshRecentMenu(item.sub, changed)

proc updateRecentMenus() =
  ## Rebuilds the Open Recent submenus of the application and window
  ## menus. Runs on the main thread.
  if not app.isReady():
    return
  var menus = @[app.menu()]
  for win in allWindows():
    menus.add win.menu
  var changed = false
  for m in menus:
    refreshRecentMenu(m, changed)
  if changed:
    refreshMenus()
