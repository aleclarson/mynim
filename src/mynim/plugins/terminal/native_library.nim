## Resolves and loads the pinned Ghostty terminal library for this app.

import std/[json, os, osproc, streams, strformat, strutils, tempfiles]
import mynim as core
import mynim/internal/sha256
import mynim/plugins/terminal/internal/vt/library as vtLibrary

export vtLibrary

type NativeLibraryFile* = object
  name*, url*, sha256*: string

const
  nativeLibrariesJson = staticRead("native-libraries.json")
  maxNativeLibraryBytes = 256'i64 * 1024 * 1024

proc requiredString(node: JsonNode; key, context: string): string =
  if node.kind != JObject or not node.hasKey(key) or
      node[key].kind != JString:
    raise newException(ValueError, context & " has no string " & key)
  node[key].getStr()

proc nativeLibraryFor*(osName, arch: string): NativeLibraryFile =
  ## Returns the upstream pinned library for an OS and architecture pair.
  let target = osName & "-" & arch
  let manifest = parseJson(nativeLibrariesJson)
  if manifest.kind != JObject or not manifest.hasKey("libraries") or
      manifest["libraries"].kind != JArray:
    raise newException(ValueError, "terminal native-library manifest is invalid")
  for library in manifest["libraries"]:
    if requiredString(library, "name", "native library") != "libghostty-vt":
      continue
    if not library.hasKey("files") or library["files"].kind != JObject or
        not library["files"].hasKey(target):
      break
    let file = library["files"][target]
    result.name = requiredString(file, "name", target)
    result.url = requiredString(file, "url", target)
    result.sha256 = requiredString(file, "sha256", target).toLowerAscii()
    if result.name.len == 0 or result.name.lastPathPart() != result.name:
      raise newException(ValueError, "terminal native-library filename is invalid")
    if not result.url.startsWith("https://"):
      raise newException(ValueError, "terminal native-library URL must use HTTPS")
    if result.sha256.len != 64:
      raise newException(ValueError, "terminal native-library SHA-256 is invalid")
    for ch in result.sha256:
      if ch notin {'0'..'9', 'a'..'f'}:
        raise newException(ValueError,
          "terminal native-library SHA-256 is invalid")
    return
  raise newException(ValueError,
    "terminal: libghostty-vt has no build for " & target)

proc hostNativeLibrary*(): NativeLibraryFile =
  let osName =
    when defined(macosx): "darwin"
    elif defined(linux): "linux"
    elif defined(windows): "windows"
    else: ""
  let arch =
    when defined(amd64): "amd64"
    elif defined(arm64): "arm64"
    else: ""
  if osName.len == 0 or arch.len == 0:
    raise newException(ValueError,
      "terminal: libghostty-vt is not supported on this platform")
  nativeLibraryFor(osName, arch)

proc cacheFile(asset: NativeLibraryFile): string =
  core.app.path(core.pathCache) / "natives" / asset.sha256 / asset.name

proc sha256File(path: string): string =
  var file: File
  if not open(file, path, fmRead):
    raise newException(IOError, "cannot read native library for SHA-256")
  defer: file.close()
  var state = sha256Init()
  var buffer: array[64 * 1024, byte]
  while true:
    let count = file.readBuffer(addr buffer[0], buffer.len)
    if count == 0:
      break
    state.sha256Update(buffer.toOpenArray(0, count - 1))
  for value in sha256Final(state):
    result.add(toHex(int(value), 2).toLowerAscii())

proc hasExpectedHash(path: string; asset: NativeLibraryFile): bool =
  if not fileExists(path):
    return false
  try:
    sha256File(path) == asset.sha256
  except CatchableError:
    false

proc downloadLibrary(asset: NativeLibraryFile; path: string) =
  if not asset.url.startsWith("https://") or asset.sha256.len != 64:
    raise newException(ValueError,
      "terminal: no verified download is configured for " & asset.name)
  let directory = path.parentDir()
  createDir(directory)
  let (temporaryFile, temporaryPath) = createTempFile(
    "mynim-ghostty-", ".download", directory)
  temporaryFile.close()
  defer:
    if fileExists(temporaryPath):
      removeFile(temporaryPath)

  let curl = findExe("curl")
  if curl.len == 0:
    raise newException(IOError,
      "terminal: downloading libghostty-vt requires curl on PATH")
  try:
    let process = startProcess(curl, args = @[
      "--disable", "--fail", "--location", "--silent", "--show-error",
      "--max-time", "120", "--max-redirs", "5",
      "--max-filesize", $maxNativeLibraryBytes,
      "--proto", "=https", "--proto-redir", "=https",
      "--user-agent", "mynim-terminal", "--output", temporaryPath,
      asset.url], options = {poUsePath, poStdErrToStdOut})
    defer: process.close()
    let exitCode = process.waitForExit()
    let output = process.outputStream.readAll()
    if exitCode != 0:
      raise newException(IOError,
        "curl exited with status " & $exitCode &
        (if output.len > 0: ": " & output.strip() else: ""))
  except CatchableError as error:
    raise newException(IOError,
      "terminal: downloading libghostty-vt failed: " & error.msg)

  if getFileSize(temporaryPath) > maxNativeLibraryBytes:
    raise newException(IOError,
      "terminal: downloaded libghostty-vt exceeds the size limit")
  if sha256File(temporaryPath) != asset.sha256:
    raise newException(IOError,
      "terminal: downloaded libghostty-vt failed SHA-256 validation")

  try:
    moveFile(temporaryPath, path)
  except OSError:
    if hasExpectedHash(path, asset):
      return
    if fileExists(path):
      removeFile(path)
    moveFile(temporaryPath, path)

proc findGhosttyVTPath*(): string =
  ## Finds an override or shipped copy; downloads only for unpackaged apps.
  let override = getEnv("MYNIM_GHOSTTY_VT")
  if override.len > 0:
    return override

  let asset = hostNativeLibrary()
  let directories = [
    core.app.path(core.pathResources),
    getAppFilename().parentDir()]
  for directory in directories:
    if directory.len > 0:
      let candidate = directory / asset.name
      if fileExists(candidate):
        return candidate

  let path = cacheFile(asset)
  if hasExpectedHash(path, asset):
    return path
  if core.app.isPackaged():
    raise newException(IOError,
      &"terminal: {asset.name} is missing from app resources; " &
      "build the app with nim-xplat build")
  downloadLibrary(asset, path)
  path

proc loadGhosttyVT*(): vtLibrary.GhosttyVT =
  ## Resolves the native library and validates its Ghostty ABI manifest.
  vtLibrary.openGhosttyVT(findGhosttyVTPath())
