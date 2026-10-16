## Create a native UI application project.

import std/[json, math, os, strutils]
import mynim/image as imagePackage
import ./skills

const
  version = "0.1.0"
  usageInit = """Usage: mygo init [flags] <dir>

Create a new MyNim project with a native, GPU-rendered UI.

Flags:
  -name string       application name (defaults to the directory name)
  -package string    Nimble package name (defaults to a slug of the directory)
  -module string     alias for -package
  -template string   native (the default); web is not ported yet
  -mygo path         local MyNim checkout to use instead of a package dependency
  -h, --help         show this help
"""
  nativeMainTemplate = staticRead("templates/native/main.nim.tmpl")
  nativeTestTemplate = staticRead("templates/native/test_app.nim.tmpl")
  iconSize = 1024

proc slugify(value: string): string =
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

proc displayPath(path: string): string =
  try:
    let relative = relativePath(path, getCurrentDir())
    if relative != ".." and not relative.startsWith("../"):
      return relative
  except ValueError:
    discard
  path

proc defaultIcon(): seq[byte] =
  let image = imagePackage.newNrgba(
    imagePackage.rect(0, 0, iconSize, iconSize))
  let fromColor = [59.0, 130.0, 246.0]
  let toColor = [168.0, 85.0, 247.0]
  let inset = 100.0
  let radius = 185.0
  for y in 0 ..< iconSize:
    let fy = float64(y) + 0.5
    for x in 0 ..< iconSize:
      let fx = float64(x) + 0.5
      let qx = abs(fx - iconSize.float64 / 2) -
        (iconSize.float64 / 2 - inset - radius)
      let qy = abs(fy - iconSize.float64 / 2) -
        (iconSize.float64 / 2 - inset - radius)
      let distance = hypot(max(qx, 0.0), max(qy, 0.0)) +
        min(max(qx, qy), 0.0) - radius
      let alpha = min(max(0.5 - distance, 0.0), 1.0)
      if alpha == 0:
        continue
      let gradient = (fx + fy) / (2 * iconSize.float64)
      var color: array[3, float64]
      for i in 0 ..< color.len:
        color[i] = fromColor[i] + (toColor[i] - fromColor[i]) * gradient
      let ring = min(max(0.5 - abs(hypot(fx - iconSize.float64 / 2,
        fy - iconSize.float64 / 2) - 230) + 48, 0.0), 1.0)
      for i in 0 ..< color.len:
        color[i] = color[i] * (1 - ring) + 255 * ring
      image.set(x, y, imagePackage.Nrgba(r: uint8(color[0]),
        g: uint8(color[1]), b: uint8(color[2]), a: uint8(alpha * 255)))
  imagePackage.pngEncode(image)

proc writeBytes(path: string; bytes: seq[byte]) =
  if bytes.len == 0:
    raise newException(IOError, "mygo init: cannot write an empty icon")
  var file: File
  if not open(file, path, fmWrite):
    raise newException(IOError, "mygo init: cannot create " & path)
  try:
    if file.writeBuffer(unsafeAddr bytes[0], bytes.len) != bytes.len:
      raise newException(IOError, "mygo init: could not write " & path)
  finally:
    close(file)

proc writeText(path, content: string) =
  try:
    writeFile(path, content)
  except OSError as error:
    raise newException(IOError, "mygo init: " & error.msg)

proc checkProjectDir(path: string): tuple[dir, name: string] =
  if path.len == 0:
    raise newException(ValueError, "mygo init: missing project directory")
  result.dir = absolutePath(path)
  result.name = splitPath(result.dir).tail
  if result.name.len == 0:
    raise newException(ValueError,
      "mygo init: the project directory must have a name")
  if fileExists(result.dir):
    raise newException(ValueError,
      "mygo init: " & result.dir & " is not a directory")
  if dirExists(result.dir):
    for _ in walkDir(result.dir):
      raise newException(ValueError,
        "mygo init: " & result.dir & " is not empty")

proc localSourcePath(path: string): string =
  if path.len == 0:
    return ""
  result = absolutePath(path)
  if not dirExists(result) or not fileExists(result / "src" / "mynim.nim"):
    raise newException(ValueError,
      "mygo init: " & result & " is not a MyNim checkout")

proc nimbleFile(local: bool): string =
  result = """version       = "0.1.0"
author        = "MyNim app"
description   = "Native UI application built with MyNim"
license       = "MIT"
srcDir        = "src"
bin           = @["main"]

requires "nim >= 2.2.0"
"""
  if not local:
    result.add "requires \"mynim >= " & version & "\"\n"
  result.add """

task run, "Run the application":
  exec "nim c -r src/main.nim"

task test, "Run the headless UI test":
  exec "nim c -r tests/test_app.nim"
"""

proc writeProject(dir, appName, packageName, local: string) =
  createDir(dir)
  createDir(dir / "src")
  createDir(dir / "tests")
  createDir(dir / "resources")

  let appNameLiteral = appName.escape()
  let main = nativeMainTemplate.replace("{{APP_NAME}}", appNameLiteral)
  let test = nativeTestTemplate
  writeText(dir / "src" / "main.nim", main)
  writeText(dir / "tests" / "test_app.nim", test)
  writeText(dir / (packageName & ".nimble"), nimbleFile(local.len > 0))
  writeText(dir / ".gitignore", "/build/\n/dist/\n/main\n/main.exe\n")

  var config = newJObject()
  config["name"] = %appName
  config["identifier"] = %("com.example." &
    slugify(appName).replace("-", ""))
  config["version"] = %version
  config["out"] = %"build"
  writeText(dir / "mygo.json", config.pretty & "\n")

  if local.len > 0:
    writeText(dir / "config.nims",
      "switch(\"path\", " & (local / "src").escape() & ")\n")
  writeBytes(dir / "resources" / "icon.png", defaultIcon())
  installBundledSkills(dir)

proc runInit*(args: seq[string]): int =
  var appName, packageOption, localOption = ""
  var projectTemplate = "native"
  var paths: seq[string]
  var index = 0
  while index < args.len:
    let arg = args[index]
    if arg == "--":
      for rest in index + 1 ..< args.len:
        paths.add args[rest]
      break
    if arg in ["-h", "--help"]:
      stdout.write(usageInit)
      return 0
    if arg.startsWith("-"):
      let equalAt = arg.find('=')
      let flag = (if equalAt < 0: arg else: arg[0 ..< equalAt])
        .strip(leading = true, trailing = false, chars = {'-'})
      var value = ""
      if equalAt >= 0:
        if equalAt + 1 < arg.len:
          value = arg[equalAt + 1 .. ^1]
      else:
        inc index
        if index >= args.len:
          stderr.writeLine("mygo init: missing value for -" & flag)
          stderr.write(usageInit)
          return 2
        value = args[index]
      case flag
      of "name": appName = value
      of "package", "module": packageOption = value
      of "mynim", "mygo": localOption = value
      of "template": projectTemplate = value
      else:
        stderr.writeLine("mygo init: unknown flag -" & flag)
        stderr.write(usageInit)
        return 2
    else:
      paths.add arg
    inc index

  if projectTemplate != "native":
    stderr.writeLine("mygo init: only the native template is ported so far")
    return 1
  if paths.len != 1:
    stderr.writeLine("mygo init: expected one project directory")
    stderr.write(usageInit)
    return 2

  try:
    let (dir, directoryName) = checkProjectDir(paths[0])
    let name = if appName.len > 0: appName else: directoryName
    let packageBase = if packageOption.len > 0:
      splitPath(packageOption).tail else: directoryName
    let packageName = slugify(packageBase).replace("-", "_")
    let local = localSourcePath(localOption)
    writeProject(dir, name, packageName, local)
    let shownPath = displayPath(dir)
    stdout.writeLine("Created " & name & " at " & shownPath & ".")
    stdout.writeLine("Next steps:")
    stdout.writeLine("  cd " & shownPath)
    stdout.writeLine("  nimble test")
    stdout.writeLine("  nimble build")
    stdout.writeLine("  ./main")
    return 0
  except CatchableError as error:
    stderr.writeLine(error.msg)
    return 1
