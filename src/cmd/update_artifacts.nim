## Create signed update archives and manifests for a native build.

import std/[algorithm, base64, json, os, osproc, streams, strutils, tempfiles,
  times, uri]
import ./publish

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

proc writeUpdateArtifacts*(config: JsonNode; projectDir, stage, name, version,
    target: string): seq[string] =
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
  if deltaCount > 0:
    stderr.writeLine("nim-xplat build: delta updates are not ported yet; " &
      "the update manifest will contain only the full archive")

  let notes = updateNotes(updates, projectDir, version)
  let archive = stage / archiveName
  let tar = findExe("tar")
  if tar.len == 0:
    raise newException(IOError,
      "creating update archives needs tar on PATH")
  var args = @["-czf", archive, "-C", stage]
  args.add archiveEntries(stage, name, target)
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
  let manifestPath = stage / ("update-" & target & ".json")
  writeFile(manifestPath, manifest.pretty & "\n")
  result = @[archive, manifestPath]
