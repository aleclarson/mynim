## Update feed parsing and version selection used by the app runtime.

import std/[base64, json, options, os, osproc, sets, streams, strutils,
  tempfiles, uri]

const
  maxManifestSize* = 1 shl 20
  maxReleaseListSize* = 8 shl 20
  maxArchiveSize* = 1'i64 shl 30
  taggedFeedPrefix* = "mygo+github-tags:"

const ed25519PublicPrefix: array[12, byte] = [
  0x30'u8, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]

type
  Archive* = object
    version*, url*, signature*: string
    size*: int64

  Delta* = object
    fromVersion*, url*, signature*: string
    size*: int64

  Manifest* = object
    version*, notes*, date*, url*, signature*: string
    size*: int64
    deltas*: seq[Delta]
    previous*: seq[Archive]

  UpdateProgress* = proc(downloaded, total: int64) {.closure.}
  FileDownloader* = proc(url, path: string; size: int64;
      progress: UpdateProgress) {.closure.}

  HttpGetter* = proc(url: string; maxBytes: int): string {.closure.}

proc stringField(node: JsonNode; key: string; required = false): string =
  if not node.hasKey(key) or node[key].kind == JNull:
    if required:
      raise newException(ValueError,
        "update manifest has no " & key)
    return ""
  if node[key].kind != JString:
    raise newException(ValueError,
      "update manifest " & key & " must be a string")
  node[key].getStr()

proc intField(node: JsonNode; key: string): int64 =
  if not node.hasKey(key) or node[key].kind == JNull:
    return 0
  if node[key].kind != JInt:
    raise newException(ValueError,
      "update manifest " & key & " must be an integer")
  node[key].getInt()

proc parseArchive(node: JsonNode): Archive =
  if node.kind != JObject:
    raise newException(ValueError, "update manifest archive must be an object")
  result = Archive(
    version: stringField(node, "version"),
    url: stringField(node, "url"),
    signature: stringField(node, "signature"),
    size: intField(node, "size"))

proc parseDelta(node: JsonNode): Delta =
  if node.kind != JObject:
    raise newException(ValueError, "update manifest delta must be an object")
  result = Delta(
    fromVersion: stringField(node, "from"),
    url: stringField(node, "url"),
    signature: stringField(node, "signature"),
    size: intField(node, "size"))

proc parseManifest*(body: string): Manifest =
  if body.len > maxManifestSize:
    raise newException(ValueError, "update manifest is too large")
  let node = parseJson(body)
  if node.kind != JObject:
    raise newException(ValueError, "update manifest must be an object")
  result = Manifest(
    version: stringField(node, "version", required = true),
    notes: stringField(node, "notes"),
    date: stringField(node, "date"),
    url: stringField(node, "url", required = true),
    size: intField(node, "size"),
    signature: stringField(node, "signature", required = true))
  if result.version.len == 0 or result.url.len == 0 or
      result.signature.len == 0:
    raise newException(ValueError, "update manifest is incomplete")
  if node.hasKey("deltas") and node["deltas"].kind != JNull:
    if node["deltas"].kind != JArray:
      raise newException(ValueError,
        "update manifest deltas must be an array")
    for delta in node["deltas"]:
      result.deltas.add parseDelta(delta)
  if node.hasKey("previous") and node["previous"].kind != JNull:
    if node["previous"].kind != JArray:
      raise newException(ValueError,
        "update manifest previous must be an array")
    for archive in node["previous"]:
      result.previous.add parseArchive(archive)

proc compareNumeric(a, b: string): int =
  var left = a
  var right = b
  while left.len > 1 and left[0] == '0':
    left = left[1 .. ^1]
  while right.len > 1 and right[0] == '0':
    right = right[1 .. ^1]
  if left.len < right.len:
    return -1
  if left.len > right.len:
    return 1
  cmp(left, right)

proc isNumeric(value: string): bool =
  if value.len == 0:
    return false
  for ch in value:
    if ch notin {'0'..'9'}:
      return false
  true

proc compareFields(a, b: string): int =
  let left = a.split('.')
  let right = b.split('.')
  let count = max(left.len, right.len)
  for index in 0 ..< count:
    let x = if index < left.len: left[index] else: ""
    let y = if index < right.len: right[index] else: ""
    if x == y:
      continue
    if x.len == 0:
      return -1
    if y.len == 0:
      return 1
    let xNumeric = isNumeric(x)
    let yNumeric = isNumeric(y)
    if xNumeric and yNumeric:
      return compareNumeric(x, y)
    if xNumeric:
      return -1
    if yNumeric:
      return 1
    return cmp(x, y)
  0

proc compareVersions*(a, b: string): int =
  ## Compares dotted numeric versions and semantic pre-release identifiers.
  var left = a
  var right = b
  if left == "v":
    left = ""
  elif left.startsWith('v'):
    left = left[1 .. ^1]
  if right == "v":
    right = ""
  elif right.startsWith('v'):
    right = right[1 .. ^1]
  left = left.split('+', maxsplit = 1)[0]
  right = right.split('+', maxsplit = 1)[0]
  let leftParts = left.split('-', maxsplit = 1)
  let rightParts = right.split('-', maxsplit = 1)
  result = compareFields(leftParts[0], rightParts[0])
  if result != 0:
    return
  let leftPre = if leftParts.len > 1: leftParts[1] else: ""
  let rightPre = if rightParts.len > 1: rightParts[1] else: ""
  if leftPre == rightPre:
    return 0
  if leftPre.len == 0:
    return 1
  if rightPre.len == 0:
    return -1
  result = compareFields(leftPre, rightPre)

proc escapePathSegment(value: string): string =
  const digits = "0123456789ABCDEF"
  for ch in value:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '~'}:
      result.add ch
    else:
      let byteValue = ord(ch)
      result.add '%'
      result.add digits[byteValue shr 4]
      result.add digits[byteValue and 0x0f]

proc isAllowedUrl(rawUrl: string): bool =
  try:
    let parsed = parseUri(rawUrl)
    let scheme = parsed.scheme.toLowerAscii()
    let host = parsed.hostname.toLowerAscii()
    if host.len == 0:
      return false
    if scheme == "https":
      return true
    if scheme != "http":
      return false
    host == "localhost" or host == "::1" or host == "[::1]" or
      host == "127.0.0.1" or host.startsWith("127.")
  except CatchableError:
    return false

proc httpGet*(rawUrl, userAgent: string; maxBytes: int): string =
  ## Fetches update data through curl, with HTTPS required outside loopback.
  if maxBytes <= 0:
    raise newException(ValueError, "update response size limit must be positive")
  if not isAllowedUrl(rawUrl):
    raise newException(IOError, "refusing update URL without HTTPS: " & rawUrl)
  let curl = findExe("curl")
  if curl.len == 0:
    raise newException(IOError, "checking for updates needs curl on PATH")
  let temporary = createTempDir("mynim-update-http-", "")
  defer:
    if dirExists(temporary):
      removeDir(temporary)
  let bodyPath = temporary / "response"
  let process = startProcess(curl, args = @[
    "--disable", "--fail", "--location", "--silent", "--show-error",
    "--max-time", "30",
    "--max-redirs", "5", "--max-filesize", $maxBytes,
    "--proto", "=https,http", "--proto-redir", "=https",
    "--user-agent", userAgent, "--output", bodyPath, rawUrl],
    options = {poUsePath, poStdErrToStdOut})
  var output = ""
  var code = -1
  try:
    output = process.outputStream.readAll()
    code = process.waitForExit()
  finally:
    process.close()
  if code != 0:
    raise newException(IOError,
      "GET " & rawUrl & " failed" &
      (if output.strip().len > 0: ": " & output.strip() else: ""))
  if not fileExists(bodyPath):
    raise newException(IOError, "GET " & rawUrl & " returned no body")
  if getFileSize(bodyPath) > maxBytes:
    raise newException(IOError, "GET " & rawUrl & " response is too large")
  result = readFile(bodyPath)

proc resolveFeed*(feed: string; getter: HttpGetter): string =
  ## Resolves the private tag-prefix feed marker to its newest stable release.
  if not feed.startsWith(taggedFeedPrefix):
    return feed
  let fields = feed[taggedFeedPrefix.len .. ^1].split('/')
  if fields.len != 3:
    raise newException(ValueError, "invalid GitHub update feed")
  let repo = decodeUrl(fields[0])
  let prefix = decodeUrl(fields[1])
  let manifestName = decodeUrl(fields[2])
  let slash = repo.find('/')
  if slash <= 0 or slash == repo.high or repo.find('/', slash + 1) >= 0 or
      prefix.len == 0 or manifestName.len == 0:
    raise newException(ValueError, "invalid GitHub update feed")
  var page = 1
  while page <= 10_000:
    let apiUrl = "https://api.github.com/repos/" & repo &
      "/releases?per_page=100&page=" & $page
    let releases = parseJson(getter(apiUrl, maxReleaseListSize))
    if releases.kind != JArray:
      raise newException(ValueError,
        "GitHub releases response must be an array")
    if releases.len == 0:
      raise newException(IOError, "no release is published")
    for release in releases:
      if release.kind == JObject and release.hasKey("tag_name") and
          release["tag_name"].kind == JString:
        let draft = release.hasKey("draft") and
          release["draft"].kind == JBool and release["draft"].getBool()
        let prerelease = release.hasKey("prerelease") and
          release["prerelease"].kind == JBool and
          release["prerelease"].getBool()
        let tag = release["tag_name"].getStr()
        if not draft and not prerelease and tag.startsWith(prefix):
          return "https://github.com/" & repo & "/releases/download/" &
            escapePathSegment(tag) & "/" & escapePathSegment(manifestName)
    if releases.len < 100:
      raise newException(IOError, "no release is published")
    inc page
  raise newException(IOError, "no release is published")

proc checkUpdate*(feed, current: string; getter: HttpGetter): Option[Manifest] =
  ## Reads a manifest and returns it only when it is newer than current.
  let manifestUrl = resolveFeed(feed, getter)
  if manifestUrl.len == 0:
    return none(Manifest)
  let manifest = parseManifest(getter(manifestUrl, maxManifestSize))
  if compareVersions(manifest.version, current) <= 0:
    return none(Manifest)
  some(manifest)

proc httpDownload*(rawUrl, userAgent, path: string; size: int64;
    progress: UpdateProgress) =
  ## Downloads exactly size bytes through curl, enforcing HTTPS off loopback.
  if size <= 0 or size > maxArchiveSize:
    raise newException(ValueError, "invalid update archive size " & $size)
  if not isAllowedUrl(rawUrl):
    raise newException(IOError, "refusing update URL without HTTPS: " & rawUrl)
  let curl = findExe("curl")
  if curl.len == 0:
    raise newException(IOError, "installing updates needs curl on PATH")
  let process = startProcess(curl, args = @[
    "--disable", "--fail", "--location", "--silent", "--show-error",
    "--max-time", "600", "--max-redirs", "5", "--max-filesize", $size,
    "--proto", "=https,http", "--proto-redir", "=https",
    "--user-agent", userAgent, "--output", path, rawUrl],
    options = {poUsePath, poStdErrToStdOut})
  var output = ""
  var code = -1
  var finished = false
  var lastReported = -1'i64
  try:
    while process.peekExitCode() == -1:
      if fileExists(path):
        let downloaded = getFileSize(path)
        if downloaded > size:
          raise newException(IOError, "update download exceeds its manifest size")
        if progress != nil and downloaded != lastReported:
          progress(downloaded, size)
          lastReported = downloaded
      sleep(100)
    output = process.outputStream.readAll()
    code = process.waitForExit()
    finished = true
  finally:
    if not finished:
      try:
        if process.peekExitCode() == -1:
          process.kill()
        discard process.waitForExit()
      except CatchableError:
        discard
    process.close()
  if code != 0:
    raise newException(IOError,
      "GET " & rawUrl & " failed" &
      (if output.strip().len > 0: ": " & output.strip() else: ""))
  if not fileExists(path) or getFileSize(path) != size:
    let received = if fileExists(path): getFileSize(path) else: 0
    raise newException(IOError,
      "downloaded " & $received & " bytes, want " & $size)
  if progress != nil and lastReported != size:
    progress(size, size)

proc runTool(executable: string; args: openArray[string]):
    tuple[code: int, output: string] =
  let process = startProcess(executable, args = @args,
    options = {poUsePath, poStdErrToStdOut})
  try:
    result.output = process.outputStream.readAll()
    result.code = process.waitForExit()
  finally:
    process.close()

proc verifyArchiveSignature(archive, publicKey, signature, work: string) =
  var publicBytes, signatureBytes: string
  try:
    publicBytes = decode(publicKey.strip())
    signatureBytes = decode(signature.strip())
  except ValueError:
    raise newException(ValueError, "invalid update key or signature")
  if publicBytes.len != 32 or signatureBytes.len != 64:
    raise newException(ValueError, "invalid update key or signature length")
  let openssl = findExe("openssl")
  if openssl.len == 0:
    raise newException(IOError,
      "verifying updates needs OpenSSL 1.1.1 or later on PATH")
  var publicDer = newStringOfCap(ed25519PublicPrefix.len + publicBytes.len)
  for value in ed25519PublicPrefix:
    publicDer.add char(value)
  publicDer.add publicBytes
  let publicPath = work / "update-public.der"
  let signaturePath = work / "update.signature"
  let digestPath = work / "update.sha256"
  writeFile(publicPath, publicDer)
  writeFile(signaturePath, signatureBytes)
  let hashed = runTool(openssl,
    ["dgst", "-sha256", "-binary", "-out", digestPath, archive])
  if hashed.code != 0:
    raise newException(IOError,
      "could not hash update archive: " & hashed.output.strip())
  if not fileExists(digestPath) or getFileSize(digestPath) != 32:
    raise newException(IOError, "OpenSSL returned an invalid SHA-256 digest")
  let verified = runTool(openssl, ["pkeyutl", "-verify", "-rawin", "-pubin",
    "-inkey", publicPath, "-keyform", "DER", "-in", digestPath,
    "-sigfile", signaturePath])
  if verified.code != 0:
    raise newException(IOError,
      "the update is not signed with the app's key" &
      (if verified.output.strip().len > 0: ": " & verified.output.strip()
      else: ""))

proc safeArchivePath(name: string): bool =
  if name.len == 0 or name[0] == '/' or '\\' in name or '\0' in name:
    return false
  if name.len >= 2 and name[1] == ':':
    return false
  var normalized = name
  while normalized.len > 0 and normalized[^1] == '/':
    normalized.setLen(normalized.len - 1)
  if normalized.len == 0:
    return false
  for part in normalized.split('/'):
    if part.len == 0 or part == "." or part == "..":
      return false
  true

proc linkStaysInArchive(root, path, target: string): bool =
  if target.len == 0 or target[0] == '/' or '\\' in target or '\0' in target:
    return false
  if target.len >= 2 and target[1] == ':':
    return false
  let relative = relativePath(path, root).replace('\\', '/')
  let parts = relative.split('/')
  var depth = parts.len - 1
  for part in target.split('/'):
    if part == "" or part == ".":
      continue
    if part == "..":
      if depth == 0:
        return false
      dec depth
    else:
      inc depth
  true

proc extractArchive(archive, directory: string) =
  let tar = findExe("tar")
  if tar.len == 0:
    raise newException(IOError, "extracting updates needs tar on PATH")
  let listed = runTool(tar, ["-tzf", archive])
  if listed.code != 0:
    raise newException(IOError,
      "could not list update archive: " & listed.output.strip())
  var names: seq[string]
  var nameSet = initHashSet[string]()
  for rawName in listed.output.splitLines():
    if rawName.len == 0:
      continue
    if not safeArchivePath(rawName):
      raise newException(ValueError,
        "invalid path in update archive: " & rawName.escape())
    var name = rawName
    while name.len > 0 and name[^1] == '/':
      name.setLen(name.len - 1)
    if name in nameSet:
      raise newException(ValueError,
        "duplicate path in update archive: " & rawName.escape())
    names.add rawName
    nameSet.incl name
  if names.len == 0:
    raise newException(ValueError, "the update archive is empty")
  let verbose = runTool(tar, ["-tvzf", archive])
  if verbose.code != 0:
    raise newException(IOError,
      "could not inspect update archive: " & verbose.output.strip())
  var lines: seq[string]
  for line in verbose.output.splitLines():
    if line.len > 0:
      lines.add line
  if lines.len != names.len:
    raise newException(ValueError,
      "could not safely inspect update archive entries")
  var links = initHashSet[string]()
  for index, line in lines:
    if line.len == 0 or line[0] notin {'-', 'd', 'l'}:
      raise newException(ValueError,
        "unsupported entry in update archive: " & line.escape())
    if line[0] == 'l':
      let marker = " " & names[index] & " -> "
      let markerAt = line.find(marker)
      if markerAt < 0:
        raise newException(ValueError,
          "could not safely inspect update archive link: " &
          names[index].escape())
      let target = line[markerAt + marker.len .. ^1]
      var linkPath = names[index]
      while linkPath.len > 0 and linkPath[^1] == '/':
        linkPath.setLen(linkPath.len - 1)
      if not linkStaysInArchive(directory, directory / linkPath, target):
        raise newException(ValueError,
          "update archive link points outside the app: " &
          names[index].escape())
      links.incl linkPath
  for rawName in names:
    var name = rawName
    while name.len > 0 and name[^1] == '/':
      name.setLen(name.len - 1)
    let parts = name.split('/')
    var prefix = ""
    for index, part in parts:
      if index == parts.high:
        break
      if prefix.len > 0:
        prefix.add '/'
      prefix.add part
      if prefix in links:
        raise newException(ValueError,
          "update archive path passes through a symbolic link: " &
          rawName.escape())
  createDir(directory)
  let extracted = runTool(tar,
    ["-xzf", archive, "-C", directory, "--no-same-owner"])
  if extracted.code != 0:
    raise newException(IOError,
      "could not extract update archive: " & extracted.output.strip())

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc movePath(source, destination: string) =
  let info = getFileInfo(source, followSymlink = false)
  if info.kind == pcDir:
    moveDir(source, destination)
  else:
    moveFile(source, destination)

proc removePath(path: string) =
  let info = getFileInfo(path, followSymlink = false)
  if info.kind == pcDir:
    removeDir(path)
  else:
    removeFile(path)

proc rollbackFiles(changed: seq[tuple[destination, backup: string]]) =
  var index = changed.len
  while index > 0:
    dec index
    let item = changed[index]
    try:
      if pathExists(item.destination):
        removePath(item.destination)
      if item.backup.len > 0 and pathExists(item.backup):
        movePath(item.backup, item.destination)
    except CatchableError:
      discard

proc swapBundle(directory, target: string) =
  var entries: seq[string]
  for kind, path in walkDir(directory):
    if kind == pcDir and path.endsWith(".app"):
      entries.add path
  if entries.len != 1:
    raise newException(ValueError, "the update holds no app bundle")
  var allEntries = 0
  for _ in walkDir(directory):
    inc allEntries
  if allEntries != 1:
    raise newException(ValueError, "the update holds no single app bundle")
  let old = parentDir(target) / ("." & target.lastPathPart() & ".old-" &
    $getCurrentProcessId())
  if pathExists(old):
    raise newException(IOError, "an earlier update backup already exists")
  movePath(target, old)
  try:
    movePath(entries[0], target)
  except CatchableError:
    if pathExists(target):
      removePath(target)
    if pathExists(old):
      movePath(old, target)
    raise
  try:
    removePath(old)
  except CatchableError:
    discard

proc swapFiles(directory, target: string) =
  var entries: seq[string]
  for kind, path in walkDir(directory):
    if kind in {pcFile, pcDir, pcLinkToDir, pcLinkToFile}:
      entries.add path
  if entries.len == 0:
    raise newException(ValueError, "the update is empty")
  let suffix = ".old-" & $getCurrentProcessId()
  var changed: seq[tuple[destination, backup: string]]
  for source in entries:
    let destination = target / source.lastPathPart()
    var backup = ""
    try:
      if pathExists(destination):
        backup = target / ("." & source.lastPathPart() & suffix)
        if pathExists(backup):
          raise newException(IOError,
            "an earlier update backup already exists: " & backup)
        movePath(destination, backup)
      changed.add (destination, backup)
      movePath(source, destination)
    except CatchableError:
      rollbackFiles(changed)
      if backup.len > 0 and pathExists(backup) and not pathExists(destination):
        try:
          movePath(backup, destination)
        except CatchableError:
          discard
      raise
  for item in changed:
    if item.backup.len > 0:
      try:
        removePath(item.backup)
      except CatchableError:
        discard

proc installUpdate*(manifest: Manifest; publicKey, target: string;
    progress: UpdateProgress; download: FileDownloader): ref CatchableError =
  ## Downloads, verifies, extracts, and replaces an app from its full archive.
  try:
    if manifest.size <= 0 or manifest.size > maxArchiveSize:
      raise newException(ValueError, "invalid update archive size " &
        $manifest.size)
    if manifest.url.len == 0 or manifest.signature.len == 0:
      raise newException(ValueError, "incomplete update manifest")
    if download.isNil:
      raise newException(ValueError, "no update downloader was provided")
    if not dirExists(parentDir(target)) or not pathExists(target):
      raise newException(IOError, "cannot write beside the installed app")
    let work = createTempDir("." & target.lastPathPart() & ".update-", "",
      parentDir(target))
    defer:
      if dirExists(work):
        try:
          removeDir(work)
        except CatchableError:
          discard
    let archive = work / "update.tar.gz"
    download(manifest.url, archive, manifest.size, progress)
    if not fileExists(archive) or getFileSize(archive) != manifest.size:
      let received = if fileExists(archive): getFileSize(archive) else: 0
      raise newException(IOError,
        "downloaded " & $received & " bytes, want " & $manifest.size)
    verifyArchiveSignature(archive, publicKey, manifest.signature, work)
    let unpacked = work / "app"
    extractArchive(archive, unpacked)
    when defined(macosx):
      swapBundle(unpacked, target)
    else:
      swapFiles(unpacked, target)
  except CatchableError as error:
    result = newException(IOError,
      "mynim: installing the update: " & error.msg)

proc registeredExec(entry: string): string =
  for line in entry.splitLines():
    if line.startsWith("Exec=\"") and line.len > 6:
      let value = line[6 .. ^1]
      let endQuote = value.find('"')
      if endQuote > 0:
        let executable = value[0 ..< endQuote]
        if isAbsolute(executable):
          return executable

proc desktopEntry(packaged, directory, name: string): string =
  let icon = directory / (name & ".png")
  let hasIcon = fileExists(icon)
  let execPrefix = "Exec=" & name
  var offset = 0
  while offset < packaged.len:
    var endLine = packaged.find('\n', offset)
    if endLine < 0:
      endLine = packaged.len
    var line = packaged[offset ..< endLine]
    if line.startsWith(execPrefix):
      let rest = if line.len == execPrefix.len: ""
        else: line[execPrefix.len .. ^1]
      if rest.len == 0 or rest[0] == ' ':
        line = "Exec=\"" & (directory / name) & "\"" & rest
    elif line == "Icon=" & name and hasIcon:
      line = "Icon=" & icon
    result.add line & "\n"
    offset = endLine + 1

proc sameFile(first, second: string): bool =
  try:
    expandFilename(first) == expandFilename(second)
  except OSError:
    false

proc runDesktopTool(name, path: string) =
  let executable = findExe(name)
  if executable.len == 0:
    return
  try:
    let process = startProcess(executable, args = @[path],
      options = {poStdErrToStdOut})
    try:
      discard process.outputStream.readAll()
      discard process.waitForExit()
    finally:
      process.close()
  except CatchableError:
    discard

proc writeDesktopFile(path, contents: string) =
  writeFile(path, contents)
  when defined(posix):
    setFilePermissions(path,
      {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})

proc refreshDesktopEntry*(directory, name: string): ref CatchableError =
  ## Refreshes a registered Linux desktop entry and MIME package after install.
  try:
    let configuredData = getEnv("XDG_DATA_HOME")
    let data = if isAbsolute(configuredData): configuredData
      else: getHomeDir() / ".local" / "share"
    let entryPath = data / "applications" / (name & ".desktop")
    var registered: string
    try:
      registered = readFile(entryPath)
    except OSError:
      return
    let executable = registeredExec(registered)
    if executable.len == 0 or executable.lastPathPart() != name or
        not sameFile(executable, directory / name):
      return
    let appDirectory = executable.parentDir()
    let packaged = readFile(appDirectory / (name & ".desktop"))
    let updatedEntry = desktopEntry(packaged, appDirectory, name)
    if updatedEntry != registered:
      writeDesktopFile(entryPath, updatedEntry)
      runDesktopTool("update-desktop-database", data / "applications")

    let packagedMimePath = appDirectory / (name & ".xml")
    let registeredMimePath = data / "mime" / "packages" / (name & ".xml")
    if fileExists(packagedMimePath):
      let mime = readFile(packagedMimePath)
      if not fileExists(registeredMimePath) or
          readFile(registeredMimePath) != mime:
        createDir(registeredMimePath.parentDir())
        writeDesktopFile(registeredMimePath, mime)
        runDesktopTool("update-mime-database", data / "mime")
    elif fileExists(registeredMimePath):
      removeFile(registeredMimePath)
      runDesktopTool("update-mime-database", data / "mime")
  except CatchableError as error:
    result = error
