## updater.go — restart the app and remove files a prior update left.

when not defined(emscripten):
  import std/tempfiles
  import mynim/internal/update as updateRuntime

const
  packageUpdateFeed {.strdefine.} = ""
  packageUpdateKey {.strdefine.} = ""

let startExe =
  when defined(emscripten): ""
  else: getAppFilename()

## Keep the process handle alive until the current app exits. Closing it
## before then would terminate the newly started process.
var relaunchedProcess: Process

proc cleanOldUpdateFiles(directory: string) {.gcsafe.} =
  if directory == "" or not dirExists(directory):
    return
  for entry in walkDir(directory):
    let name = extractFilename(entry.path)
    if not name.startsWith(".") or ".old-" notin name:
      continue
    try:
      if entry.kind == pcDir:
        removeDir(entry.path)
      else:
        removeFile(entry.path)
    except OSError:
      discard

proc cleanUpdateLeftovers() {.gcsafe.} =
  ## Windows keeps the old executable open; Linux may leave renamed app
  ## files behind. macOS swaps and removes whole bundles while running.
  when not defined(macosx) and not defined(emscripten):
    let exe = getAppFilename()
    if exe == "":
      return
    cleanOldUpdateFiles(parentDir(exe))

proc relaunchNow() =
  ## Starts the executable again after the app's quit callbacks finish.
  when not defined(emscripten):
    if launchedByDev():
      quit(devRelaunchCode)
    if startExe == "":
      return
    try:
      when defined(windows):
        relaunchedProcess = startProcess(startExe, workingDir = startDir,
          args = commandLineParams(), options = {poDaemon})
      else:
        relaunchedProcess = startProcess(startExe, workingDir = startDir,
          args = commandLineParams(), options = {poParentStreams})
    except CatchableError:
      discard

when not defined(emscripten):
  type
    UpdaterModule* = object
      ## The singleton app updater. Apps receive a configured feed and key from
      ## `nim-xplat build` when `updates` is set in mygo.json.

    Update* = object
      ## A newer signed release found by `Updater.check`.
      version*, notes*, date*: string
      manifest: updateRuntime.Manifest
      key, current: string

    UpdateProgress* = proc(downloaded, total: int64) {.closure.}

  let Updater* = UpdaterModule()

  proc installTarget(): string =
    if startExe.len == 0:
      return ""
    let exe = expandFilename(startExe)
    when defined(macosx):
      result = parentDir(parentDir(parentDir(exe)))
      if not result.endsWith(".app"):
        result = ""
    else:
      if getEnv("APPIMAGE").len > 0:
        return ""
      result = parentDir(exe)

  proc enabled*(u: UpdaterModule): bool =
    ## Whether this build has update settings and can write beside its install.
    if packageUpdateFeed.len == 0 or packageUpdateKey.len == 0 or isDev():
      return false
    try:
      let target = installTarget()
      if target.len == 0:
        return false
      let probe = createTempDir(".mynim-update-", "", parentDir(target))
      removeDir(probe)
      true
    except CatchableError:
      false

  proc check*(u: UpdaterModule;
      cancelled: proc(): bool {.closure.} = nil): tuple[update: Option[Update],
      err: ref CatchableError] =
    ## Fetches this app's update feed; returns none when it is current.
    result.update = none(Update)
    if cancelled != nil and cancelled():
      result.err = newException(IOError, "mynim: update operation cancelled")
      return
    if not u.enabled():
      result.err = newException(ValueError,
        "mynim: updates are not enabled for this build")
      return
    let current = app.version()
    let userAgent = "Mynim/" & Version & " " & app.name() & "/" & current
    let getter: updateRuntime.HttpGetter = proc(url: string;
        maxBytes: int): string =
      updateRuntime.httpGet(url, userAgent, maxBytes, cancelled)
    try:
      let found = updateRuntime.checkUpdate(packageUpdateFeed, current, getter)
      if found.isSome:
        let manifest = found.get()
        result.update = some(Update(version: manifest.version,
          notes: manifest.notes, date: manifest.date, manifest: manifest,
          key: packageUpdateKey, current: current))
    except CatchableError as error:
      result.err = newException(IOError,
        "mynim: checking for updates: " & error.msg)

  proc install*(up: Update;
      progress: UpdateProgress = nil;
      cancelled: proc(): bool {.closure.} = nil): ref CatchableError =
    ## Downloads, verifies, and installs this update beside the app.
    ## Requires `curl`, `openssl`, and `tar` on PATH.
    try:
      if cancelled != nil and cancelled():
        raise newException(IOError, "mynim: update operation cancelled")
      let target = installTarget()
      if target.len == 0:
        return newException(ValueError,
          "mynim: this installation cannot update itself")
      let userAgent = "Mynim/" & Version & " " & app.name() & "/" &
        up.current
      let download: updateRuntime.FileDownloader = proc(url, path: string;
          size: int64; onProgress: updateRuntime.UpdateProgress) =
        updateRuntime.httpDownload(url, userAgent, path, size, onProgress,
          cancelled)
      result = updateRuntime.installUpdate(up.manifest, up.key, target,
        progress, download, up.current, cancelled)
      when defined(linux):
        if result.isNil:
          let refreshError = updateRuntime.refreshDesktopEntry(target,
            startExe.lastPathPart())
          if refreshError != nil:
            stderr.writeLine("mynim: registering the desktop entry of the " &
              "update: " & refreshError.msg)
    except CatchableError as error:
      result = newException(IOError,
        "mynim: installing the update: " & error.msg)
