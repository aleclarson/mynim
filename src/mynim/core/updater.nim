## updater.go — restart the app and remove files a prior update left.

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
