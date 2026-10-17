## Build Linux desktop metadata, release archives, and Debian packages.

import std/[algorithm, json, os, osproc, streams, strutils, tables, tempfiles]
import std/dirs
{.push warning[Deprecated]: off.}
import std/md5
{.pop.}

type
  FileAssociation = object
    extensions: seq[string]
    name, mimeType: string

  LinuxMetadata = object
    name, slug, executable: string
    comment, maintainer, command, iconPath: string
    categories, dependencies, schemes: seq[string]
    associations: seq[FileAssociation]

  LinuxFiles = object
    desktop, icon, mime: string
    iconWidth, iconHeight: int
    hasIcon, hasMime: bool

const debArchitectures = {
  "amd64": "amd64", "arm64": "arm64", "386": "i386",
  "arm": "armhf", "riscv64": "riscv64"}.toTable

proc linuxSlug(value: string): string =
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

proc stringField(node: JsonNode; key, path, fallback: string): string =
  if node.kind != JObject or not node.hasKey(key):
    return fallback
  if node[key].kind != JString:
    raise newException(ValueError, "mygo.json: " & path & " must be a string")
  node[key].getStr()

proc stringArray(node: JsonNode; key, path: string): seq[string] =
  if node.kind != JObject or not node.hasKey(key):
    return
  if node[key].kind != JArray:
    raise newException(ValueError, "mygo.json: " & path & " must be an array")
  for value in node[key]:
    if value.kind != JString or value.getStr().len == 0:
      raise newException(ValueError,
        "mygo.json: " & path & " entries must be nonempty strings")
    result.add value.getStr()

proc validExtension(value: string): bool =
  if value.len == 0 or value[0] notin {'a'..'z', 'A'..'Z', '0'..'9'}:
    return false
  for ch in value:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '+', '-'}:
      return false
  true

proc packageAuthor(projectDir: string): string =
  let path = projectDir / "package.json"
  if not fileExists(path):
    return ""
  try:
    let package = parseFile(path)
    if package.kind != JObject or not package.hasKey("author"):
      return ""
    let author = package["author"]
    var name, email: string
    if author.kind == JString:
      name = author.getStr()
      let open = name.find('<')
      if open >= 0:
        let close = name.find('>', open + 1)
        if close > open:
          email = name[open + 1 ..< close].strip()
          name = name[0 ..< open]
      let paren = name.find('(')
      if paren >= 0:
        name = name[0 ..< paren]
    elif author.kind == JObject:
      name = stringField(author, "name", "author.name", "")
      email = stringField(author, "email", "author.email", "")
    name = name.splitWhitespace().join(" ")
    if name.len == 0:
      return ""
    if email.len == 0: name else: name & " <" & email & ">"
  except CatchableError:
    ""

proc metadata(projectDir, appName, executable: string;
    config: JsonNode): LinuxMetadata =
  result.name = appName
  result.slug = linuxSlug(appName)
  result.executable = executable
  var linux = newJObject()
  if config.kind == JObject and config.hasKey("linux") and
      config["linux"].kind != JNull:
    if config["linux"].kind != JObject:
      raise newException(ValueError, "mygo.json: linux must be an object")
    linux = config["linux"]
  result.comment = stringField(linux, "comment", "linux.comment", "")
  result.command = stringField(linux, "command", "linux.command", "")
  if result.command.len > 0:
    if result.command[0] notin {'a'..'z', 'A'..'Z', '0'..'9'}:
      raise newException(ValueError,
        "mygo.json: linux.command is not a command name")
    for ch in result.command:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '+', '-'}:
        raise newException(ValueError,
          "mygo.json: linux.command is not a command name")
  result.categories = stringArray(linux, "categories", "linux.categories")
  if result.categories.len == 0:
    result.categories = @["Utility"]
  result.dependencies = @[
    "libgtk-3-0 | libgtk-3-0t64", "libwebkit2gtk-4.1-0"] &
    stringArray(linux, "depends", "linux.depends")
  for dependency in result.dependencies:
    for ch in dependency:
      if ord(ch) < 32 or ord(ch) == 127:
        raise newException(ValueError,
          "mygo.json: linux.depends cannot contain control characters")
  result.maintainer = stringField(linux, "maintainer", "linux.maintainer", "")
  if result.maintainer.len == 0:
    result.maintainer = packageAuthor(projectDir)
  if result.maintainer.len == 0:
    result.maintainer = appName

  let icon = stringField(config, "icon", "icon", "")
  result.iconPath = if icon.len > 0:
    (if isAbsolute(icon): icon else: projectDir / icon)
    elif fileExists(projectDir / "resources" / "icon.png"):
      projectDir / "resources" / "icon.png"
    else: ""

  if config.kind == JObject and config.hasKey("fileAssociations"):
    if config["fileAssociations"].kind != JArray:
      raise newException(ValueError,
        "mygo.json: fileAssociations must be an array")
    for index in 0 ..< config["fileAssociations"].len:
      let item = config["fileAssociations"][index]
      if item.kind != JObject:
        raise newException(ValueError,
          "mygo.json: fileAssociations[" & $index & "] must be an object")
      let extensions = stringArray(item, "ext",
        "fileAssociations[" & $index & "].ext")
      if extensions.len == 0:
        raise newException(ValueError,
          "mygo.json: fileAssociations[" & $index & "] has no ext")
      for extension in extensions:
        if not validExtension(extension):
          raise newException(ValueError,
            "mygo.json: fileAssociations[" & $index & "] has invalid extension " &
            extension)
      result.associations.add FileAssociation(extensions: extensions,
        name: stringField(item, "name", "fileAssociations.name", ""),
        mimeType: stringField(item, "mimeType",
          "fileAssociations.mimeType", ""))
  result.schemes = stringArray(config, "urlSchemes", "urlSchemes")
  for scheme in result.schemes:
    if scheme.len == 0 or scheme[0] notin {'a'..'z', 'A'..'Z'}:
      raise newException(ValueError,
        "mygo.json: urlSchemes contains an invalid scheme")
    for ch in scheme:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '+', '-', '.'}:
        raise newException(ValueError,
          "mygo.json: urlSchemes contains an invalid scheme")

proc associationMime(meta: LinuxMetadata; association: FileAssociation):
    tuple[value: string, appDefined: bool] =
  if association.mimeType.len > 0:
    return (association.mimeType, false)
  ("application/x-" & meta.slug & "-" &
    association.extensions[0].toLowerAscii(), true)

proc desktopEscape(value: string): string =
  for ch in value:
    case ch
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else: result.add ch

proc desktopEntry(meta: LinuxMetadata; executablePath, icon: string): string =
  result = "[Desktop Entry]\nType=Application\nName=" &
    desktopEscape(meta.name) & "\n"
  if meta.comment.len > 0:
    result.add "Comment=" & desktopEscape(meta.comment) & "\n"
  var mimeTypes: seq[string]
  for association in meta.associations:
    mimeTypes.add associationMime(meta, association).value
  for scheme in meta.schemes:
    mimeTypes.add "x-scheme-handler/" & scheme
  let appExec = executablePath & (if mimeTypes.len > 0: " %U" else: "")
  result.add "Exec=" & appExec & "\nIcon=" & icon & "\nCategories=" &
    desktopEscape(meta.categories.join(";")) & ";\nTerminal=false\n"
  if mimeTypes.len > 0:
    result.add "MimeType=" & desktopEscape(mimeTypes.join(";")) & ";\n"

proc xmlEscape(value: string): string =
  for ch in value:
    case ch
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&apos;"
    else: result.add ch

proc mimePackage(meta: LinuxMetadata): string =
  var content = ""
  for association in meta.associations:
    let mime = associationMime(meta, association)
    if not mime.appDefined:
      continue
    content.add "  <mime-type type=\"" & mime.value & "\">\n"
    if association.name.len > 0:
      content.add "    <comment>" & xmlEscape(association.name) &
        "</comment>\n"
    for extension in association.extensions:
      content.add "    <glob pattern=\"*." & xmlEscape(extension) &
        "\"/>\n"
    content.add "  </mime-type>\n"
  if content.len > 0:
    result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
      "<mime-info xmlns=\"http://www.freedesktop.org/standards/shared-mime-info\">\n" &
      content & "</mime-info>\n"

proc pngSize(path: string): tuple[width, height: int] =
  let content = readFile(path)
  if content.len < 24 or content[0 ..< 8] != "\x89PNG\r\n\x1a\n" or
      content[12 ..< 16] != "IHDR":
    raise newException(ValueError, "icon " & path & " is not a PNG")
  for i in 16 ..< 20:
    result.width = (result.width shl 8) or ord(content[i])
  for i in 20 ..< 24:
    result.height = (result.height shl 8) or ord(content[i])
  if result.width <= 0 or result.height <= 0 or result.width != result.height:
    raise newException(ValueError, "icon " & path & " must be a square PNG")

proc writeLinuxDesktop*(projectDir, stage, appName, executable: string;
    config: JsonNode): seq[string] =
  let meta = metadata(projectDir, appName, executable, config)
  if meta.iconPath.len > 0 and not fileExists(meta.iconPath):
    raise newException(IOError, "mygo.json: icon does not exist: " & meta.iconPath)
  var files = LinuxFiles(desktop: meta.slug & ".desktop",
    icon: meta.slug & ".png", mime: meta.slug & ".xml")
  if fileExists(stage / files.desktop) or dirExists(stage / files.desktop):
    raise newException(ValueError,
      "Linux metadata conflicts with staged resource " & files.desktop)
  if meta.iconPath.len > 0:
    if fileExists(stage / files.icon) or dirExists(stage / files.icon):
      raise newException(ValueError,
        "Linux metadata conflicts with staged resource " & files.icon)
    let dimensions = pngSize(meta.iconPath)
    files.iconWidth = dimensions.width
    files.iconHeight = dimensions.height
    files.hasIcon = true
    copyFile(meta.iconPath, stage / files.icon)
    setFilePermissions(stage / files.icon, {fpUserRead, fpUserWrite,
      fpGroupRead, fpOthersRead})
    result.add files.icon
  let xml = mimePackage(meta)
  if xml.len > 0:
    if fileExists(stage / files.mime) or dirExists(stage / files.mime):
      raise newException(ValueError,
        "Linux metadata conflicts with staged resource " & files.mime)
    writeFile(stage / files.mime, xml)
    files.hasMime = true
    result.add files.mime
  writeFile(stage / files.desktop,
    desktopEntry(meta, executable, if meta.iconPath.len > 0: meta.slug else: ""))
  result.add files.desktop

proc stageEntries*(stage: string): seq[string] =
  for kind, path in walkDir(stage):
    if kind in {pcDir, pcFile, pcLinkToDir, pcLinkToFile}:
      result.add path.lastPathPart()
  result.sort()

proc runTool(executable: string; args: openArray[string]):
    tuple[code: int, output: string] =
  let process = startProcess(executable, args = @args,
    options = {poUsePath, poStdErrToStdOut})
  try:
    result.output = process.outputStream.readAll()
    result.code = process.waitForExit()
  finally:
    process.close()

proc writeTarGz(root, output: string; entries: openArray[string]) =
  let tar = findExe("tar")
  if tar.len == 0:
    raise newException(IOError,
      "creating Linux release archives needs tar on PATH")
  var args = @["-czf", output, "-C", root, "--"]
  for entry in entries:
    args.add entry
  let archived = runTool(tar, args)
  if archived.code != 0:
    if fileExists(output): removeFile(output)
    raise newException(IOError,
      "could not create Linux tar.gz archive:\n" & archived.output.strip())

proc debVersion(version: string): string =
  result = if version.startsWith("v"): version[1 .. ^1] else: version
  if result.len == 0:
    raise newException(ValueError, "mygo.json: Debian version cannot be empty")
  let separator = result.find('-')
  if separator >= 0:
    result = result[0 ..< separator] & "~" &
      result[separator + 1 .. ^1].replace('-', '.')
  result = result.replace('+', '~')
  for ch in result:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '+', '~', '-', ':'}:
      raise newException(ValueError,
        "mygo.json: version is not valid for a Debian package")

proc validateLinuxArtifactNames*(appName, version, arch: string;
    entries: openArray[string]) =
  if "install.sh" in entries:
    raise newException(ValueError,
      "Linux installer conflicts with staged resource install.sh")
  for ch in version:
    if ch in {'/', '\\', '\0'}:
      raise newException(ValueError,
        "mygo.json: version cannot contain a path separator")
  let appSlug = linuxSlug(appName)
  if (appSlug & "-" & version & "-linux-" & arch & ".tar.gz") in entries:
    raise newException(ValueError,
      "Linux release archive conflicts with a staged resource")
  if debArchitectures.hasKey(arch) and
      (appSlug & "_" & debVersion(version) & "_" &
        debArchitectures[arch] & ".deb") in entries:
    raise newException(ValueError,
      "Debian package conflicts with a staged resource")

proc copyPackageEntry(source, target: string) =
  let info = getFileInfo(source, followSymlink = false)
  if info.kind == pcDir:
    copyDirWithPermissions(source, target, ignorePermissionErrors = false,
      skipSpecial = true)
  else:
    copyFile(source, target, {cfSymlinkAsIs})
    if info.kind == pcFile:
      setFilePermissions(target, getFilePermissions(source))

proc collectPackageFiles(root, relative: string; paths: var seq[string];
    size: var int64) =
  for kind, path in walkDir(root / relative):
    let rel = if relative.len == 0: path.lastPathPart()
      else: relative / path.lastPathPart()
    case kind
    of pcDir:
      collectPackageFiles(root, rel, paths, size)
    of pcFile:
      paths.add rel.replace('\\', '/')
      size += getFileSize(path)
    else:
      discard

proc arField(value: string; width: int): string =
  if value.len > width:
    raise newException(ValueError, "Debian archive member field is too long")
  value & repeat(' ', width - value.len)

proc appendArMember(archive: var string; name, content: string) =
  let header = arField(name & "/", 16) & arField("0", 12) &
    arField("0", 6) & arField("0", 6) & arField("100644", 8) &
    arField($content.len, 10) & "`\n"
  doAssert header.len == 60
  archive.add header
  archive.add content
  if content.len mod 2 == 1:
    archive.add '\n'

proc writeDeb(stage, appName, executable, version, arch: string;
    entries: openArray[string]; files: LinuxFiles;
    meta: LinuxMetadata): string =
  if not debArchitectures.hasKey(arch):
    return ""
  let temporary = createTempDir("mynim-deb-", "", stage)
  defer:
    if dirExists(temporary): removeDir(temporary)
  let dataRoot = temporary / "data"
  let appRoot = dataRoot / "opt" / meta.slug
  let controlRoot = temporary / "control"
  createDir(appRoot)
  createDir(controlRoot)
  for entry in entries:
    if entry == files.desktop or
        (files.hasIcon and entry == files.icon) or
        (files.hasMime and entry == files.mime):
      continue
    copyPackageEntry(stage / entry, appRoot / entry)

  let desktopDir = dataRoot / "usr" / "share" / "applications"
  createDir(desktopDir)
  writeFile(desktopDir / files.desktop,
    desktopEntry(meta, "/opt/" & meta.slug & "/" & executable,
      if meta.iconPath.len > 0: meta.slug else: ""))
  if files.hasIcon and fileExists(stage / files.icon):
    let iconDir = dataRoot / "usr" / "share" / "icons" / "hicolor" /
      ($files.iconWidth & "x" & $files.iconHeight) / "apps"
    createDir(iconDir)
    copyFile(stage / files.icon, iconDir / files.icon)
  if files.hasMime and fileExists(stage / files.mime):
    let mimeDir = dataRoot / "usr" / "share" / "mime" / "packages"
    createDir(mimeDir)
    copyFile(stage / files.mime, mimeDir / files.mime)
  if meta.command.len > 0:
    let binDir = dataRoot / "usr" / "bin"
    createDir(binDir)
    createSymlink("../../opt/" & meta.slug & "/" & executable,
      binDir / meta.command)

  var filesToHash: seq[string]
  var installedSize = 0'i64
  collectPackageFiles(dataRoot, "", filesToHash, installedSize)
  filesToHash.sort()
  var checksums = ""
  for path in filesToHash:
    checksums.add getMD5(readFile(dataRoot / path)) & "  " & path & "\n"

  let depends = meta.dependencies.join(", ")
  let description = if meta.comment.len > 0: meta.comment else: appName
  let control = "Package: " & meta.slug & "\n" &
    "Version: " & debVersion(version) & "\n" &
    "Architecture: " & debArchitectures[arch] & "\n" &
    "Maintainer: " & meta.maintainer.replace('\n', ' ').replace('\r', ' ') & "\n" &
    "Installed-Size: " & $((installedSize + 1023) div 1024) & "\n" &
    "Depends: " & depends & "\nSection: utils\nPriority: optional\n" &
    "Description: " & description.replace('\n', ' ').replace('\r', ' ') & "\n " &
    appName.replace('\n', ' ').replace('\r', ' ') &
    " is a desktop application.\n"
  writeFile(controlRoot / "control", control)
  writeFile(controlRoot / "md5sums", checksums)

  let controlArchive = temporary / "control.tar.gz"
  let dataArchive = temporary / "data.tar.gz"
  writeTarGz(controlRoot, controlArchive, ["."])
  writeTarGz(dataRoot, dataArchive, ["."])
  var archive = "!<arch>\n"
  appendArMember(archive, "debian-binary", "2.0\n")
  appendArMember(archive, "control.tar.gz", readFile(controlArchive))
  appendArMember(archive, "data.tar.gz", readFile(dataArchive))
  result = stage / (meta.slug & "_" & debVersion(version) & "_" &
    debArchitectures[arch] & ".deb")
  writeFile(result, archive)

proc writeLinuxArtifacts*(projectDir, stage, appName, executable, version,
    arch: string; config: JsonNode; entries: openArray[string];
    reuseArchive = false): seq[string] =
  validateLinuxArtifactNames(appName, version, arch, entries)
  let meta = metadata(projectDir, appName, executable, config)
  let dimensions = if meta.iconPath.len > 0: pngSize(meta.iconPath)
    else: (width: 0, height: 0)
  let files = LinuxFiles(desktop: meta.slug & ".desktop",
    icon: meta.slug & ".png", mime: meta.slug & ".xml",
    iconWidth: dimensions.width, iconHeight: dimensions.height,
    hasIcon: meta.iconPath.len > 0, hasMime: mimePackage(meta).len > 0)
  let archive = stage / (meta.slug & "-" & version & "-linux-" & arch &
    ".tar.gz")
  if reuseArchive:
    if not fileExists(archive):
      raise newException(IOError,
        "signed Linux update archive was not written: " & archive)
  else:
    writeTarGz(stage, archive, entries)
  result.add archive
  let deb = writeDeb(stage, appName, executable, version, arch,
    entries, files, meta)
  if deb.len > 0:
    result.add deb
