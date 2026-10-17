## Update feed parsing and version selection used by the app runtime.

import std/[json, options, os, osproc, streams, strutils, tempfiles, uri]

const
  maxManifestSize* = 1 shl 20
  maxReleaseListSize* = 8 shl 20
  taggedFeedPrefix* = "mygo+github-tags:"

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
    "--fail", "--location", "--silent", "--show-error", "--max-time", "30",
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
