## Find native assets declared by imported Mynim plugin modules and stage them.

import std/[json, os, osproc, streams, strutils, tables, tempfiles]
import ../mynim/internal/native_asset_cache
import ../mynim/internal/sha256

type NativeAsset = object
  library, name, url, sha256: string

const
  pluginModuleMarker = "MYNIM_NATIVE_PLUGIN_MODULE="
  pluginManifestName = "native-libraries.json"
  maxNativeAssetBytes = 256'i64 * 1024 * 1024

proc requiredString(node: JsonNode; key, context: string): string =
  if node.kind != JObject or not node.hasKey(key) or
      node[key].kind != JString:
    raise newException(ValueError, context & " has no string " & key)
  node[key].getStr()

proc pluginModulePaths*(compileOutput: string): seq[string] =
  var seen = initTable[string, bool]()
  for line in compileOutput.splitLines():
    if not line.startsWith(pluginModuleMarker):
      continue
    let path = line[pluginModuleMarker.len .. ^1].strip()
    if path.len == 0:
      raise newException(ValueError,
        "nim-xplat: compiler reported an empty native plugin module path")
    let normalized = absolutePath(path)
    if not seen.hasKey(normalized):
      seen[normalized] = true
      result.add normalized

proc parsePluginAssets(modulePath, targetOs, targetArch: string): seq[NativeAsset] =
  let manifestPath = modulePath.parentDir() / pluginManifestName
  if not fileExists(manifestPath):
    raise newException(IOError,
      "nim-xplat: native plugin manifest is missing: " & manifestPath)
  let manifest = parseFile(manifestPath)
  if manifest.kind != JObject or not manifest.hasKey("libraries") or
      manifest["libraries"].kind != JArray:
    raise newException(ValueError,
      manifestPath & ": libraries must be an array")
  let target = targetOs & "-" & targetArch
  for library in manifest["libraries"]:
    let libraryName = requiredString(library, "name", "native library")
    if libraryName.len == 0:
      raise newException(ValueError,
        manifestPath & ": native library name cannot be empty")
    if not library.hasKey("files") or library["files"].kind != JObject or
        not library["files"].hasKey(target):
      raise newException(ValueError,
        manifestPath & ": " & libraryName & " has no build for " &
        targetOs & "/" & targetArch)
    let file = library["files"][target]
    let asset = NativeAsset(
      library: libraryName,
      name: requiredString(file, "name", target),
      url: requiredString(file, "url", target),
      sha256: requiredString(file, "sha256", target))
    if asset.name.len == 0 or asset.name in [".", ".."] or
        asset.name.lastPathPart() != asset.name or
        asset.name.contains({'/', '\\'}):
      raise newException(ValueError,
        manifestPath & ": native library filename is invalid")
    if not asset.url.startsWith("https://"):
      raise newException(ValueError,
        manifestPath & ": native library URL must use HTTPS")
    if asset.sha256.len != 64 or asset.sha256 != asset.sha256.toLowerAscii():
      raise newException(ValueError,
        manifestPath & ": native library SHA-256 is invalid")
    for ch in asset.sha256:
      if ch notin {'0'..'9', 'a'..'f'}:
        raise newException(ValueError,
          manifestPath & ": native library SHA-256 is invalid")
    result.add asset

proc sha256File(path: string): string =
  var file: File
  if not open(file, path, fmRead):
    raise newException(IOError, "cannot read native asset for SHA-256")
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

proc cachePath(cacheRoot: string; asset: NativeAsset): string =
  nativeAssetCachePath(cacheRoot, asset.sha256, asset.name)

proc hasExpectedHash(path: string; asset: NativeAsset): bool =
  if not fileExists(path):
    return false
  try:
    sha256File(path) == asset.sha256
  except CatchableError:
    false

proc fetchAsset(cacheRoot: string; asset: NativeAsset): string =
  result = cachePath(cacheRoot, asset)
  if hasExpectedHash(result, asset):
    return
  let directory = result.parentDir()
  createDir(directory)
  let (temporaryFile, temporaryPath) = createTempFile(
    "mynim-native-", ".download", directory)
  temporaryFile.close()
  defer:
    if fileExists(temporaryPath):
      removeFile(temporaryPath)

  let curl = findExe("curl")
  if curl.len == 0:
    raise newException(IOError,
      "nim-xplat: downloading native assets requires curl on PATH")
  let process = startProcess(curl, args = @[
    "--disable", "--fail", "--location", "--silent", "--show-error",
    "--max-time", "120", "--max-redirs", "5",
    "--max-filesize", $maxNativeAssetBytes,
    "--proto", "=https", "--proto-redir", "=https",
    "--user-agent", "nim-xplat", "--output", temporaryPath, asset.url],
    options = {poUsePath, poStdErrToStdOut})
  try:
    let exitCode = process.waitForExit()
    let output = process.outputStream.readAll()
    if exitCode != 0:
      raise newException(IOError,
        "curl exited with status " & $exitCode &
        (if output.len > 0: ": " & output.strip() else: ""))
  finally:
    process.close()

  if getFileSize(temporaryPath) > maxNativeAssetBytes:
    raise newException(IOError,
      "nim-xplat: downloaded native asset exceeds the size limit")
  if sha256File(temporaryPath) != asset.sha256:
    raise newException(IOError,
      "nim-xplat: downloaded native asset failed SHA-256 validation")
  try:
    moveFile(temporaryPath, result)
  except OSError:
    if hasExpectedHash(result, asset):
      return
    if fileExists(result):
      removeFile(result)
    moveFile(temporaryPath, result)

proc stageNativePlugins*(compileOutput, destination, targetOs, targetArch: string;
    cacheRoot = ""): seq[string] =
  ## Stages checksum-verified assets from native plugin modules imported by an app.
  let cache = if cacheRoot.len > 0: absolutePath(cacheRoot)
    else: nativeAssetCacheRoot()
  var seenLibraries = initTable[string, bool]()
  for modulePath in pluginModulePaths(compileOutput):
    for asset in parsePluginAssets(modulePath, targetOs, targetArch):
      if seenLibraries.hasKey(asset.library):
        continue
      seenLibraries[asset.library] = true
      if fileExists(destination / asset.name) or dirExists(destination / asset.name):
        raise newException(ValueError,
          "nim-xplat: resource conflicts with native library " & asset.name)
      let cached = fetchAsset(cache, asset)
      let target = destination / asset.name
      copyFile(cached, target)
      result.add target
