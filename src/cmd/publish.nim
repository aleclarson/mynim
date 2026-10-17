## Upload build artifacts to a draft GitHub release.

import std/[base64, json, os, osproc, streams, strutils, uri]
import ./s3 as s3Upload

type
  GitHubRelease* = object
    repo*, tag*, notes*: string
    latest*: bool

  PublisherKind* = enum
    pkGitHub, pkS3

  Publisher* = object
    kind*: PublisherKind
    github*: GitHubRelease
    s3*: s3Upload.S3Config
    url*: string

proc configString(config: JsonNode; key, fallback: string): string =
  if not config.hasKey(key):
    return fallback
  if config[key].kind != JString:
    raise newException(ValueError, "mygo.json: " & key & " must be a string")
  config[key].getStr()

proc headingVersion(value: string): string =
  if value.startsWith("["):
    let closing = value.find(']')
    if closing >= 0:
      return value[1 ..< closing]
  value

proc withoutVersionPrefix(value: string): string =
  if value.len > 0 and value[0] == 'v':
    if value.len > 1: value[1 .. ^1] else: ""
  else:
    value

proc releaseNotes*(changelog, version: string): string =
  let wanted = withoutVersionPrefix(version)
  var found = false
  var notes: seq[string]
  for line in changelog.replace("\r\n", "\n").split('\n'):
    if line.startsWith("## "):
      if found:
        break
      let heading = if line.len > 3: line[3 .. ^1] else: ""
      let fields = heading.splitWhitespace()
      if fields.len > 0 and
          withoutVersionPrefix(headingVersion(fields[0])) == wanted:
        found = true
      continue
    if found:
      notes.add line
  result = notes.join("\n").strip()

proc prepareGitHubRelease*(config: JsonNode; projectDir, version: string):
    GitHubRelease =
  if config.kind != JObject or not config.hasKey("updates") or
      config["updates"].kind != JObject:
    raise newException(ValueError,
      "-upload needs updates.github in mygo.json")
  let updates = config["updates"]
  if updates.hasKey("s3") and updates["s3"].kind != JNull:
    raise newException(ValueError,
      "updates.s3 uses the S3 publisher, not the GitHub release publisher")
  let publicKey = configString(updates, "publicKey", "").strip()
  var decodedKey: string
  try:
    decodedKey = decode(publicKey)
  except ValueError:
    raise newException(ValueError,
      "updates.publicKey: invalid update public key")
  if decodedKey.len != 32:
    raise newException(ValueError,
      "updates.publicKey: invalid update public key")

  result.repo = configString(updates, "github", "")
  if result.repo.len == 0:
    raise newException(ValueError,
      "-upload needs updates.github in mygo.json")
  let slash = result.repo.find('/')
  if slash <= 0 or slash == result.repo.high or
      result.repo.find('/', slash + 1) >= 0:
    raise newException(ValueError,
      "mygo.json: updates.github must be owner/name")

  var prefix = configString(updates, "tagPrefix", "v")
  if prefix.len == 0:
    prefix = "v"
  result.tag = prefix & version
  result.latest = prefix == "v"

  var changelog = configString(updates, "changelog", "CHANGELOG.md")
  if changelog.len == 0:
    changelog = "CHANGELOG.md"
  let changelogPath = if isAbsolute(changelog): changelog
    else: projectDir / changelog
  if fileExists(changelogPath):
    result.notes = releaseNotes(readFile(changelogPath), version)

proc s3String(config: JsonNode; key: string): string =
  if not config.hasKey(key) or config[key].kind == JNull:
    return ""
  if config[key].kind != JString:
    raise newException(ValueError, "mygo.json: updates.s3." & key &
      " must be a string")
  config[key].getStr()

proc preparePublisher*(config: JsonNode; projectDir, version: string):
    Publisher =
  if config.kind != JObject or not config.hasKey("updates") or
      config["updates"].kind != JObject:
    raise newException(ValueError,
      "-upload needs updates.github or updates.s3 in mygo.json")
  let updates = config["updates"]
  if updates.hasKey("s3") and updates["s3"].kind != JNull:
    if updates["s3"].kind != JObject:
      raise newException(ValueError, "mygo.json: updates.s3 must be an object")
    if configString(updates, "github", "").len > 0:
      raise newException(ValueError,
        "mygo.json: updates needs either github or url, not both")
    result.s3.bucket = s3String(updates["s3"], "bucket")
    result.s3.prefix = s3String(updates["s3"], "prefix")
    result.s3.region = s3String(updates["s3"], "region")
    result.s3.endpoint = s3String(updates["s3"], "endpoint")
    if updates["s3"].hasKey("pathStyle") and
        updates["s3"]["pathStyle"].kind != JNull:
      if updates["s3"]["pathStyle"].kind != JBool:
        raise newException(ValueError,
          "mygo.json: updates.s3.pathStyle must be a boolean")
      result.s3.pathStyleSet = true
      result.s3.pathStyle = updates["s3"]["pathStyle"].getBool()
    result.url = configString(updates, "url", "")
    if result.url.len == 0:
      raise newException(ValueError, "mygo.json: updates.s3 needs url")
    let parsedUrl = try: parseUri(result.url)
      except CatchableError:
        raise newException(ValueError, "mygo.json: updates.url must be an HTTPS URL")
    if parsedUrl.scheme.toLowerAscii() != "https" or
        parsedUrl.hostname.len == 0:
      raise newException(ValueError,
        "mygo.json: updates.url must be an HTTPS URL")

    let publicKey = configString(updates, "publicKey", "").strip()
    var decodedKey: string
    try:
      decodedKey = decode(publicKey)
    except ValueError:
      raise newException(ValueError,
        "updates.publicKey: invalid update public key")
    if decodedKey.len != 32:
      raise newException(ValueError,
        "updates.publicKey: invalid update public key")
    discard s3Upload.newS3Client(result.s3)
    result.kind = pkS3
  else:
    result.kind = pkGitHub
    result.github = prepareGitHubRelease(config, projectDir, version)

proc uploadFiles*(artifacts: openArray[string]):
    tuple[files, manifests: seq[string]] =
  for artifact in artifacts:
    if not fileExists(artifact) or dirExists(artifact):
      continue
    let name = artifact.lastPathPart()
    if name.startsWith("update-") and name.endsWith(".json"):
      result.manifests.add artifact
    elif name == "install.sh":
      var found = false
      for file in result.files:
        if file.lastPathPart() == name:
          found = true
          break
      if not found:
        result.files.add artifact
    elif name.endsWith(".dmg") or
        (name.endsWith(".exe") and name.contains(" Setup ")) or
        name.endsWith(".deb") or name.endsWith(".tar.gz") or
        name.endsWith(".delta"):
      result.files.add artifact

  if result.files.len + result.manifests.len == 0:
    raise newException(ValueError, "nothing to upload")

proc runGh(gh: string; args: seq[string]):
    tuple[code: int, output: string] =
  let process = startProcess(gh, args = args,
    options = {poUsePath, poStdErrToStdOut})
  try:
    result.output = process.outputStream.readAll()
    result.code = process.waitForExit()
  finally:
    process.close()

proc uploadName(files: openArray[string]): string =
  if files.len == 1: files[0].lastPathPart()
  else: $files.len & " files"

proc publishGitHub*(release: GitHubRelease; artifacts: openArray[string]) =
  let gh = findExe("gh")
  if gh.len == 0:
    raise newException(IOError,
      "-upload needs the GitHub CLI (https://cli.github.com), signed in " &
      "with gh auth login or GH_TOKEN")
  let (files, manifests) = uploadFiles(artifacts)
  let view = runGh(gh, @["release", "view", release.tag, "--repo",
    release.repo])
  if view.code != 0:
    var args = @["release", "create", release.tag, "--repo", release.repo,
      "--draft", "--title", release.tag, "--notes", release.notes]
    if not release.latest:
      args.add "--latest=false"
    let created = runGh(gh, args)
    if created.code != 0:
      raise newException(IOError,
        "gh release create failed (status " & $created.code & "):\n" &
        created.output)
    stdout.writeLine("Created draft release " & release.tag & " of " &
      release.repo)

  for batch in [files, manifests]:
    if batch.len == 0:
      continue
    var args = @["release", "upload", release.tag, "--repo", release.repo,
      "--clobber"]
    args.add batch
    let uploaded = runGh(gh, args)
    if uploaded.code != 0:
      raise newException(IOError,
        "gh release upload failed (status " & $uploaded.code & "):\n" &
        uploaded.output)
    stdout.writeLine("Uploaded " & uploadName(batch))

  let latest = if release.latest: "" else: " --latest=false"
  stdout.writeLine("Uploaded to release " & release.tag & " of " &
    release.repo & "; publish it with:\n  gh release edit " & release.tag &
    " --repo " & release.repo & " --draft=false" & latest)

proc uploadHeaders(name: string): seq[tuple[name, value: string]] =
  let extension = name.splitFile().ext.toLowerAscii()
  let contentType = case extension
    of ".dmg": "application/x-apple-diskimage"
    of ".exe": "application/vnd.microsoft.portable-executable"
    of ".deb": "application/vnd.debian.binary-package"
    of ".gz": "application/gzip"
    of ".json": "application/json"
    of ".sh": "text/plain; charset=utf-8"
    else: "application/octet-stream"
  result.add ("Content-Type", contentType)
  if name == "install.sh" or
      (name.startsWith("update-") and name.endsWith(".json")):
    result.add ("Cache-Control", "no-cache")

proc publishS3*(config: s3Upload.S3Config; url: string;
    artifacts: openArray[string]) =
  let client = s3Upload.newS3Client(config)
  let (files, manifests) = uploadFiles(artifacts)
  for path in files & manifests:
    let name = path.lastPathPart()
    let key = client.objectKey(name)
    client.put(key, path, uploadHeaders(name))
    stdout.writeLine("Uploaded " & name)
  let prefix = config.prefix.strip(chars = {'/'})
  stdout.writeLine("Uploaded to s3://" & config.bucket & "/" & prefix &
    ", which " & url & " serves")

proc publish*(publisher: Publisher; artifacts: openArray[string]) =
  case publisher.kind
  of pkGitHub:
    publishGitHub(publisher.github, artifacts)
  of pkS3:
    publishS3(publisher.s3, publisher.url, artifacts)
