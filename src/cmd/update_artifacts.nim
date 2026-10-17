## Create signed update archives and manifests for a native build.

import std/[algorithm, base64, json, os, osproc, streams, strutils, tempfiles,
  sets, times, uri]
import ./publish
import ../mynim/internal/update as updateRuntime
import ../mynim/internal/update_delta

const ed25519PrivatePrefix: array[16, byte] = [
  0x30'u8, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
  0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]

proc configString(config: JsonNode; key, fallback: string): string =
  if not config.hasKey(key):
    return fallback
  if config[key].kind != JString:
    raise newException(ValueError, "mygo.json: updates." & key &
      " must be a string")
  config[key].getStr()

proc updateSlug(value: string): string =
  var separator = false
  for ch in value.toLowerAscii:
    if ch in {'a'..'z', '0'..'9'}:
      if separator and result.len > 0:
        result.add '-'
      result.add ch
      separator = false
    else:
      separator = true
  if result.len == 0:
    result = "app"

proc escapePathSegment(value: string): string =
  const digits = "0123456789ABCDEF"
  for ch in value:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '~'}:
      result.add ch
    else:
      let value = ord(ch)
      result.add '%'
      result.add digits[value shr 4]
      result.add digits[value and 0x0f]

proc updateFileUrl(updates: JsonNode; filename, version: string): string =
  let github = configString(updates, "github", "")
  let baseUrl = configString(updates, "url", "")
  if github.len > 0 and baseUrl.len > 0:
    raise newException(ValueError,
      "mygo.json: updates needs either github or url, not both")
  if github.len == 0 and baseUrl.len == 0:
    raise newException(ValueError,
      "mygo.json: updates needs either github or url")
  if github.len > 0:
    let slash = github.find('/')
    if slash <= 0 or slash == github.high or github.find('/', slash + 1) >= 0:
      raise newException(ValueError,
        "mygo.json: updates.github must be owner/name")
    var prefix = configString(updates, "tagPrefix", "v")
    if prefix.len == 0:
      prefix = "v"
    return "https://github.com/" & github & "/releases/download/" &
      escapePathSegment(prefix & version) & "/" & escapePathSegment(filename)

  let parsed = try: parseUri(baseUrl)
    except CatchableError:
      raise newException(ValueError,
        "mygo.json: updates.url must be an HTTPS URL")
  if parsed.scheme.toLowerAscii() != "https" or parsed.hostname.len == 0:
    raise newException(ValueError,
      "mygo.json: updates.url must be an HTTPS URL")
  baseUrl.strip(chars = {'/'}) & "/" & escapePathSegment(filename)

proc runtimeUpdateSettings*(config: JsonNode; target: string):
    tuple[feed, publicKey: string] =
  ## Validates the app-side update settings and returns their link-time values.
  if config.kind != JObject or not config.hasKey("updates") or
      config["updates"].kind == JNull:
    return
  let updates = config["updates"]
  if updates.kind != JObject:
    raise newException(ValueError, "mygo.json: updates must be an object")
  result.publicKey = configString(updates, "publicKey", "").strip()
  if result.publicKey.len == 0:
    raise newException(ValueError,
      "mygo.json: updates needs the publicKey of nim-xplat keygen")
  var decodedPublic: string
  try:
    decodedPublic = decode(result.publicKey)
  except ValueError:
    raise newException(ValueError, "updates.publicKey: invalid update key")
  if decodedPublic.len != 32:
    raise newException(ValueError, "updates.publicKey: invalid update key")

  let github = configString(updates, "github", "")
  let baseUrl = configString(updates, "url", "")
  if github.len > 0 and baseUrl.len > 0:
    raise newException(ValueError,
      "mygo.json: updates needs either github or url, not both")
  if github.len > 0:
    let slash = github.find('/')
    if slash <= 0 or slash == github.high or
        github.find('/', slash + 1) >= 0:
      raise newException(ValueError,
        "mygo.json: updates.github must be owner/name")
    var prefix = configString(updates, "tagPrefix", "v")
    if prefix.len == 0:
      prefix = "v"
    let manifestName = "update-" & target & ".json"
    if prefix == "v":
      result.feed = "https://github.com/" & github &
        "/releases/latest/download/" & manifestName
    else:
      result.feed = "mygo+github-tags:" & escapePathSegment(github) & "/" &
        escapePathSegment(prefix) & "/" & escapePathSegment(manifestName)
  elif baseUrl.len > 0:
    let parsed = try: parseUri(baseUrl)
      except CatchableError:
        raise newException(ValueError,
          "mygo.json: updates.url must be an HTTPS URL")
    if parsed.scheme.toLowerAscii() != "https" or parsed.hostname.len == 0:
      raise newException(ValueError,
        "mygo.json: updates.url must be an HTTPS URL")
    result.feed = baseUrl.strip(chars = {'/'}) & "/update-" & target & ".json"
  else:
    raise newException(ValueError,
      "mygo.json: updates needs either github or url")

proc signingKey(updates: JsonNode; projectDir, publicKey: string): string =
  var encoded = getEnv("MYGO_UPDATER_PRIVATE_KEY").strip()
  if encoded.len == 0:
    let configured = configString(updates, "privateKey", "")
    if configured.len > 0:
      var path = configured
      if path.startsWith("~/"):
        path = getHomeDir() / path[2 .. ^1]
      elif not isAbsolute(path):
        path = projectDir / path
      if not fileExists(path):
        raise newException(IOError,
          "mygo.json: updates.privateKey does not exist: " & path)
      encoded = readFile(path).strip()
  if encoded.len == 0:
    return ""

  var privateKey, expectedPublic: string
  try:
    privateKey = decode(encoded)
    expectedPublic = decode(publicKey.strip())
  except ValueError:
    raise newException(ValueError,
      "updates: invalid base64 Ed25519 key")
  if privateKey.len != 64 or expectedPublic.len != 32:
    raise newException(ValueError, "updates: invalid Ed25519 key length")
  if privateKey[32 .. ^1] != expectedPublic:
    raise newException(ValueError,
      "the update signing key does not match updates.publicKey in " &
      (projectDir / "mygo.json"))
  privateKey

proc runTool(executable: string; args: openArray[string]):
    tuple[code: int, output: string] =
  let process = startProcess(executable, args = @args,
    options = {poUsePath, poStdErrToStdOut})
  try:
    result.output = process.outputStream.readAll()
    result.code = process.waitForExit()
  finally:
    process.close()

proc signArchive(archive: string; privateKey: string): string =
  let openssl = findExe("openssl")
  if openssl.len == 0:
    raise newException(IOError,
      "signing updates needs OpenSSL 1.1.1 or later on PATH")
  let temporary = createTempDir("nim-xplat-update-sign-", "")
  defer:
    if dirExists(temporary):
      removeDir(temporary)
  when defined(posix):
    setFilePermissions(temporary,
      {fpUserRead, fpUserWrite, fpUserExec})

  var der = newStringOfCap(ed25519PrivatePrefix.len + 32)
  for value in ed25519PrivatePrefix:
    der.add char(value)
  der.add privateKey[0 ..< 32]
  let privatePath = temporary / "update-key.der"
  writeFile(privatePath, der)
  when defined(posix):
    setFilePermissions(privatePath, {fpUserRead, fpUserWrite})

  let digestPath = temporary / "archive.sha256"
  let hashed = runTool(openssl, ["dgst", "-sha256", "-binary", "-out",
    digestPath, archive])
  if hashed.code != 0:
    raise newException(IOError,
      "could not hash update archive:\n" & hashed.output.strip())
  if not fileExists(digestPath) or getFileSize(digestPath) != 32:
    raise newException(IOError, "OpenSSL returned an invalid SHA-256 digest")

  let signaturePath = temporary / "archive.signature"
  let signed = runTool(openssl, ["pkeyutl", "-sign", "-rawin", "-inkey",
    privatePath, "-keyform", "DER", "-in", digestPath, "-out",
    signaturePath])
  if signed.code != 0:
    raise newException(IOError,
      "could not sign update archive:\n" & signed.output.strip())
  if not fileExists(signaturePath) or getFileSize(signaturePath) != 64:
    raise newException(IOError, "OpenSSL returned an invalid Ed25519 signature")
  encode(readFile(signaturePath))

proc updateNotes(updates: JsonNode; projectDir, version: string): string =
  var changelog = configString(updates, "changelog", "CHANGELOG.md")
  if changelog.len == 0:
    changelog = "CHANGELOG.md"
  let path = if isAbsolute(changelog): changelog else: projectDir / changelog
  if not fileExists(path):
    if changelog == "CHANGELOG.md":
      return ""
    raise newException(IOError,
      "mygo.json: updates.changelog does not exist: " & path)
  result = releaseNotes(readFile(path), version)
  if result.len == 0:
    raise newException(ValueError,
      path & " has no notes for " & version &
      ": add a \"## " & version & "\" section")

proc archiveEntries(stage, name, target: string): seq[string] =
  if target.startsWith("darwin-"):
    let bundle = updateSlug(name) & ".app"
    if not dirExists(stage / bundle):
      raise newException(IOError,
        "nim-xplat build: missing app bundle for update archive: " & bundle)
    return @[bundle]
  for kind, path in walkDir(stage):
    if kind in {pcDir, pcFile, pcLinkToDir, pcLinkToFile}:
      result.add path.lastPathPart()
  result.sort()
  if result.len == 0:
    raise newException(IOError,
      "nim-xplat build: no installed files for update archive")

proc bytesToString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for index, value in bytes:
    result[index] = char(value)

proc archiveJson(archive: updateRuntime.Archive): JsonNode =
  result = newJObject()
  result["version"] = %archive.version
  result["url"] = %archive.url
  result["size"] = %archive.size
  result["signature"] = %archive.signature

proc deltaJson(delta: updateRuntime.Delta): JsonNode =
  result = newJObject()
  result["from"] = %delta.fromVersion
  result["url"] = %delta.url
  result["size"] = %delta.size
  result["signature"] = %delta.signature

proc writeDeltas(config, updates: JsonNode; stage, name, version, target: string;
    archiveSize: int64; key: string; entries: seq[string];
    deltaCount: int; getter: updateRuntime.HttpGetter;
    downloader: updateRuntime.FileDownloader):
    tuple[files: seq[string], previous: seq[updateRuntime.Archive],
      deltas: seq[updateRuntime.Delta]] =
  if deltaCount <= 0:
    return

  let settings = runtimeUpdateSettings(config, target)
  var getManifest: updateRuntime.HttpGetter
  if getter.isNil:
    getManifest = proc(url: string; maxBytes: int): string =
      updateRuntime.httpGet(url, "mynim", maxBytes)
  else:
    getManifest = getter
  var download: updateRuntime.FileDownloader
  if downloader.isNil:
    download = proc(url, path: string; size: int64;
        progress: updateRuntime.UpdateProgress) =
      updateRuntime.httpDownload(url, "mynim", path, size, progress)
  else:
    download = downloader

  var published: updateRuntime.Manifest
  try:
    let manifestUrl = updateRuntime.resolveFeed(settings.feed, getManifest)
    if manifestUrl.len == 0:
      raise newException(IOError, "the update feed is empty")
    published = updateRuntime.parseManifest(
      getManifest(manifestUrl, updateRuntime.maxManifestSize))
  except CatchableError as error:
    stderr.writeLine("nim-xplat build: no delta updates for " & target &
      ": could not read the published manifest: " & error.msg)
    return

  var bases: seq[updateRuntime.Archive]
  var seen = initHashSet[string]()
  let latest = updateRuntime.Archive(version: published.version,
    url: published.url, size: published.size, signature: published.signature)
  for base in @[latest] & published.previous:
    if base.version.len > 0 and base.version notin seen and
        updateRuntime.compareVersions(base.version, version) < 0:
      bases.add base
      seen.incl base.version
  if bases.len == 0:
    return
  if bases.len > deltaCount:
    bases.setLen(deltaCount)
  let previousCount = min(bases.len, max(0, deltaCount - 1))
  if previousCount > 0:
    result.previous = bases[0 ..< previousCount]

  let work = createTempDir("mynim-delta-", "")
  defer:
    if dirExists(work):
      removeDir(work)
  var newDir = stage
  var newEntries = entries
  if target.startsWith("darwin-"):
    if entries.len != 1:
      raise newException(ValueError,
        "nim-xplat build: expected one app bundle for delta updates")
    newDir = stage / entries[0]
    newEntries = @[]

  for index, base in bases:
    var deltaPath = ""
    try:
      if base.url.len == 0 or base.signature.len == 0:
        raise newException(ValueError, "the previous archive is incomplete")
      if base.size <= 0 or base.size > updateRuntime.maxArchiveSize:
        raise newException(ValueError,
          "invalid previous archive size " & $base.size)
      let baseWork = work / $index
      createDir(baseWork)
      let baseArchive = baseWork / "archive.tar.gz"
      download(base.url, baseArchive, base.size, nil)
      if not fileExists(baseArchive) or getFileSize(baseArchive) != base.size:
        let received = if fileExists(baseArchive): getFileSize(baseArchive) else: 0
        raise newException(IOError,
          "downloaded " & $received & " bytes, want " & $base.size)
      updateRuntime.verifyArchiveSignature(baseArchive, settings.publicKey,
        base.signature, baseWork)
      let unpacked = baseWork / "app"
      updateRuntime.extractArchive(baseArchive, unpacked)
      var oldDir = unpacked
      if target.startsWith("darwin-"):
        var bundles: seq[string]
        var topLevelEntries = 0
        for kind, path in walkDir(unpacked):
          inc topLevelEntries
          if kind == pcDir and path.endsWith(".app"):
            bundles.add path
        if topLevelEntries != 1 or bundles.len != 1:
          raise newException(ValueError,
            "the previous archive holds no single app bundle")
        oldDir = bundles[0]

      let deltaName = updateSlug(name) & "-" &
        escapePathSegment(base.version) & "-to-" &
        escapePathSegment(version) & "-" & target & ".delta"
      deltaPath = stage / deltaName
      let delta = updateDelta.writeDelta(base.version, version, oldDir,
        newDir, newEntries)
      writeFile(deltaPath, bytesToString(delta))
      let deltaSize = getFileSize(deltaPath)
      if deltaSize < archiveSize:
        let signature = signArchive(deltaPath, key)
        result.deltas.add updateRuntime.Delta(fromVersion: base.version,
          url: updateFileUrl(updates, deltaName, version), size: deltaSize,
          signature: signature)
        result.files.add deltaPath
      else:
        removeFile(deltaPath)
        stderr.writeLine("nim-xplat build: no delta update from " &
          base.version & " for " & target &
          ": it is not smaller than the archive")
    except CatchableError as error:
      if deltaPath.len > 0 and fileExists(deltaPath):
        try:
          removeFile(deltaPath)
        except CatchableError:
          discard
      stderr.writeLine("nim-xplat build: no delta update from " &
        base.version & " for " & target & ": " & error.msg)

proc writeUpdateArtifacts*(config: JsonNode; projectDir, stage, name, version,
    target: string; getter: updateRuntime.HttpGetter = nil;
    downloader: updateRuntime.FileDownloader = nil): seq[string] =
  if config.kind != JObject or not config.hasKey("updates") or
      config["updates"].kind == JNull:
    return
  let updates = config["updates"]
  if updates.kind != JObject:
    raise newException(ValueError, "mygo.json: updates must be an object")
  var deltaCount = 3
  if updates.hasKey("deltas") and updates["deltas"].kind != JNull:
    if updates["deltas"].kind != JInt:
      raise newException(ValueError,
        "mygo.json: updates.deltas must be an integer")
    deltaCount = updates["deltas"].getInt()
    if deltaCount < 0:
      raise newException(ValueError,
        "mygo.json: updates.deltas cannot be negative")
  let publicKey = configString(updates, "publicKey", "").strip()
  if publicKey.len == 0:
    raise newException(ValueError,
      "mygo.json: updates needs the publicKey of nim-xplat keygen")
  var decodedPublic: string
  try:
    decodedPublic = decode(publicKey)
  except ValueError:
    raise newException(ValueError, "updates.publicKey: invalid update key")
  if decodedPublic.len != 32:
    raise newException(ValueError, "updates.publicKey: invalid update key")

  for ch in version:
    if ch in {'/', '\\', '\0'}:
      raise newException(ValueError,
        "mygo.json: version cannot contain a path separator")
  let archiveName = updateSlug(name) & "-" & version & "-" & target & ".tar.gz"
  let url = updateFileUrl(updates, archiveName, version)
  let key = signingKey(updates, projectDir, publicKey)
  if key.len == 0:
    stderr.writeLine(
      "nim-xplat build: not signing an update; set MYGO_UPDATER_PRIVATE_KEY " &
      "or updates.privateKey")
    return
  let notes = updateNotes(updates, projectDir, version)
  let archive = stage / archiveName
  let tar = findExe("tar")
  if tar.len == 0:
    raise newException(IOError,
      "creating update archives needs tar on PATH")
  let entries = archiveEntries(stage, name, target)
  var args = @["-czf", archive, "-C", stage]
  args.add entries
  let archived = runTool(tar, args)
  if archived.code != 0:
    if fileExists(archive): removeFile(archive)
    raise newException(IOError,
      "could not create update archive:\n" & archived.output.strip())

  let signature = signArchive(archive, key)
  var manifest = newJObject()
  manifest["version"] = %version
  if notes.len > 0:
    manifest["notes"] = %notes
  manifest["date"] = %getTime().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  manifest["url"] = %url
  manifest["size"] = %getFileSize(archive)
  manifest["signature"] = %signature
  let deltas = writeDeltas(config, updates, stage, name, version, target,
    getFileSize(archive), key, entries, deltaCount, getter, downloader)
  if deltas.deltas.len > 0:
    var deltaNodes = newJArray()
    for delta in deltas.deltas:
      deltaNodes.add deltaJson(delta)
    manifest["deltas"] = deltaNodes
  if deltas.previous.len > 0:
    var previousNodes = newJArray()
    for previous in deltas.previous:
      previousNodes.add archiveJson(previous)
    manifest["previous"] = previousNodes
  let manifestPath = stage / ("update-" & target & ".json")
  writeFile(manifestPath, manifest.pretty & "\n")
  result = @[archive] & deltas.files & @[manifestPath]
