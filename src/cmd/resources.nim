## Copy a project's shared and host-specific runtime resources.

import std/[json, os, strutils, tables]

type
  PlatformFolder = object
    recognized, exact: bool
    os, arch: string

  ResourceTracker = object
    directories, files: Table[string, string]

const platformArchitectures = [
  "386", "amd64", "arm", "arm64", "loong64", "mips", "mips64",
  "mips64le", "mipsle", "ppc64", "ppc64le", "riscv64", "s390x"]

proc canonicalOs(value: string): string =
  case value.toLowerAscii
  of "darwin": "darwin"
  of "linux": "linux"
  of "windows": "windows"
  of "macos", "mac", "osx": "darwin"
  of "win", "win32", "win64": "windows"
  else: ""

proc canonicalArch(value: string): string =
  case value.toLowerAscii
  of "x64", "x86_64": "amd64"
  of "aarch64": "arm64"
  of "x86", "ia32", "i386", "i686": "386"
  else:
    let lower = value.toLowerAscii
    if lower in platformArchitectures: lower else: ""

proc platformFolder(name: string): PlatformFolder =
  let lower = name.toLowerAscii
  let separator = lower.find('-')
  if separator < 0:
    let targetOs = canonicalOs(lower)
    if targetOs.len > 0:
      return PlatformFolder(recognized: true, exact: name == targetOs,
        os: targetOs)
  elif lower == "darwin-universal":
    return PlatformFolder(recognized: true, exact: name == lower,
      os: "darwin", arch: "universal")
  else:
    let targetOs = canonicalOs(lower[0 ..< separator])
    let targetArch = canonicalArch(lower[separator + 1 .. ^1])
    if targetOs.len > 0 and targetArch.len > 0:
      return PlatformFolder(recognized: true,
        exact: name == targetOs & "-" & targetArch,
        os: targetOs, arch: targetArch)

proc resourceKey(path, root: string): string =
  relativePath(path, root).replace('\\', '/').toLowerAscii

proc ensureResourceDir(path, root: string; tracker: var ResourceTracker): string =
  let key = resourceKey(path, root)
  if tracker.files.hasKey(key) or fileExists(path):
    raise newException(ValueError,
      "resource path conflicts with a file: " & path)
  if tracker.directories.hasKey(key):
    return tracker.directories[key]
  tracker.directories[key] = path
  createDir(path)
  path

proc copyResourceFile(source, target, root: string;
    tracker: var ResourceTracker) =
  let key = resourceKey(target, root)
  if tracker.files.hasKey(key) or tracker.directories.hasKey(key) or
      fileExists(target) or dirExists(target):
    raise newException(ValueError,
      "resource files conflict at " & relativePath(target, root))
  tracker.files[key] = source
  copyFile(source, target)

proc copyResourceTree(source, requestedTarget, root: string;
    tracker: var ResourceTracker) =
  let target = ensureResourceDir(requestedTarget, root, tracker)
  for kind, path in walkDir(source):
    let name = path.lastPathPart()
    if not name.startsWith("."):
      let destination = target / name
      case kind
      of pcFile:
        copyResourceFile(path, destination, root, tracker)
      of pcDir:
        copyResourceTree(path, destination, root, tracker)
      else:
        raise newException(ValueError,
          "resource symlinks are not supported: " & path)

proc copyResources*(projectDir, destination, targetOs, targetArch: string;
    config: JsonNode) =
  var tracker = ResourceTracker(
    directories: initTable[string, string](),
    files: initTable[string, string]())
  let sourceRoot = projectDir / "resources"
  if fileExists(sourceRoot):
    raise newException(ValueError, sourceRoot & " is not a directory")
  if dirExists(sourceRoot):
    for kind, path in walkDir(sourceRoot):
      let name = path.lastPathPart()
      if not name.startsWith("."):
        case kind
        of pcFile:
          if platformFolder(name).recognized:
            raise newException(ValueError,
              "resource is named like a platform directory but is a file: " &
              path)
          copyResourceFile(path, destination / name, destination, tracker)
        of pcDir:
          let platform = platformFolder(name)
          if platform.recognized:
            if not platform.exact:
              raise newException(ValueError,
                "platform resources must use GOOS/GOARCH names: " & path)
            if platform.os == targetOs and
                (platform.arch.len == 0 or platform.arch == targetArch):
              copyResourceTree(path, destination, destination, tracker)
          else:
            copyResourceTree(path, destination / name, destination, tracker)
        else:
          raise newException(ValueError,
            "resource symlinks are not supported: " & path)

  if config.hasKey("resources"):
    let listed = config["resources"]
    if listed.kind != JArray:
      raise newException(ValueError, "mygo.json: resources must be an array")
    for item in listed:
      if item.kind != JString or item.getStr().len == 0:
        raise newException(ValueError,
          "mygo.json: resources entries must be nonempty paths")
      let resourcePath = if isAbsolute(item.getStr()): item.getStr()
        else: projectDir / item.getStr()
      let source = absolutePath(resourcePath)
      if source == absolutePath(sourceRoot):
        raise newException(ValueError,
          "mygo.json: resources must not list the resources directory itself")
      if dirExists(source):
        copyResourceTree(source, destination / source.lastPathPart(),
          destination, tracker)
      elif fileExists(source):
        copyResourceFile(source, destination / source.lastPathPart(),
          destination, tracker)
      else:
        raise newException(ValueError,
          "mygo.json: resource does not exist: " & item.getStr())
