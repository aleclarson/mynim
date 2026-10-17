## Compile a native MyNim project for the host and package its resources.

import std/[json, os, osproc, streams, strutils, tempfiles]
import ./resources as projectResources

const usageBuild = """Usage: mygo build [flags] [dir]

Build a native project for this machine.

Flags:
  -o path          output directory (default: out from mygo.json, or dist)
  -platform target  host GOOS/GOARCH (default: this machine)
  -debug           compile with checks and debug information
  -h, --help       show this help
"""

proc configString*(config: JsonNode; key, fallback: string): string =
  if not config.hasKey(key):
    return fallback
  if config[key].kind != JString:
    raise newException(ValueError, "mygo.json: " & key & " must be a string")
  config[key].getStr()

proc slug*(value: string): string =
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

proc hostTarget*(): tuple[os, arch, path: string] =
  let targetOs = when hostOS == "macosx": "darwin" else: hostOS
  let targetArch = hostCPU
  (targetOs, targetArch, targetOs & "/" & targetArch)

proc compileApp(projectDir, source, output, cache: string; debug: bool):
    tuple[code: int, log: string] =
  let nim = findExe("nim")
  if nim.len == 0:
    raise newException(IOError, "nim was not found on PATH")
  var args = @["c", "--nimcache:" & cache]
  if not debug:
    args.add "-d:release"
  when hostOS == "windows":
    args.add "--app:gui"
  args.add "--out:" & output
  args.add source
  let process = startProcess(nim, args = args, workingDir = projectDir,
    options = {poUsePath, poStdErrToStdOut})
  try:
    result.log = process.outputStream.readAll()
    result.code = process.waitForExit()
  finally:
    process.close()

proc xmlEscape(value: string): string =
  for ch in value:
    case ch
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&apos;"
    else: result.add ch

proc writeInfoPlist*(path, name, identifier, version, executable: string) =
  var content = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
"""
  content.add("  <key>CFBundleExecutable</key><string>" &
    xmlEscape(executable) & "</string>\n")
  content.add("  <key>CFBundleIdentifier</key><string>" &
    xmlEscape(identifier) & "</string>\n")
  content.add("  <key>CFBundleName</key><string>" &
    xmlEscape(name) & "</string>\n")
  content.add("  <key>CFBundleDisplayName</key><string>" &
    xmlEscape(name) & "</string>\n")
  content.add "  <key>CFBundlePackageType</key><string>APPL</string>\n"
  content.add("  <key>CFBundleShortVersionString</key><string>" &
    xmlEscape(version) & "</string>\n")
  content.add("  <key>CFBundleVersion</key><string>" &
    xmlEscape(version) & "</string>\n")
  content.add """  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
"""
  writeFile(path, content)

proc replaceBuildDir(stage, target, parent: string) =
  var backup = ""
  let markerDir = parent / ".mynim-build"
  let marker = markerDir / target.lastPathPart()
  if fileExists(target):
    raise newException(IOError,
      "refusing to replace file at build output " & target)
  if dirExists(target):
    var empty = true
    for _ in walkDir(target):
      empty = false
    if not empty and not fileExists(marker):
      raise newException(IOError,
        "refusing to replace unowned build output " & target)
  createDir(markerDir)
  if dirExists(target):
    backup = createTempDir(".mygo-build-backup-", "", parent)
    removeDir(backup)
    moveDir(target, backup)
  try:
    moveDir(stage, target)
    writeFile(marker, "mygo native build output\n")
  except CatchableError:
    if dirExists(target) and not dirExists(stage):
      moveDir(target, stage)
    if backup.len > 0 and dirExists(backup):
      moveDir(backup, target)
    raise
  if backup.len > 0 and dirExists(backup):
    try:
      removeDir(backup)
    except CatchableError as error:
      stderr.writeLine("mygo build: could not remove previous output: " &
        error.msg)

proc runBuild*(args: seq[string]): int =
  var outputOption, platformOption = ""
  var debug = false
  var paths: seq[string]
  var index = 0
  while index < args.len:
    let arg = args[index]
    if arg == "--":
      for rest in index + 1 ..< args.len:
        paths.add args[rest]
      break
    if arg in ["-h", "--help"]:
      stdout.write(usageBuild)
      return 0
    if arg == "-debug" or arg == "--debug":
      debug = true
    elif arg.startsWith("-"):
      let equalAt = arg.find('=')
      let flag = if equalAt < 0: arg else: arg[0 ..< equalAt]
      var value = ""
      if equalAt >= 0:
        if equalAt + 1 < arg.len:
          value = arg[equalAt + 1 .. ^1]
      else:
        inc index
        if index >= args.len:
          stderr.writeLine("mygo build: missing value for " & flag)
          return 2
        value = args[index]
      if value.len == 0:
        stderr.writeLine("mygo build: missing value for " & flag)
        return 2
      case flag
      of "-o", "--output": outputOption = value
      of "-platform", "--platform": platformOption = value
      else:
        stderr.writeLine("mygo build: unknown flag " & flag)
        stderr.write(usageBuild)
        return 2
    else:
      paths.add arg
    inc index

  if paths.len > 1:
    stderr.writeLine("mygo build: expected at most one project directory")
    stderr.write(usageBuild)
    return 2

  let (targetOs, targetArch, hostPlatform) = hostTarget()
  if platformOption.len > 0 and platformOption notin [hostPlatform, "host"]:
    stderr.writeLine("mygo build: only the host platform is supported (" &
      hostPlatform & ")")
    return 1

  try:
    let projectDir = if paths.len == 0: getCurrentDir()
      else: absolutePath(paths[0])
    if not dirExists(projectDir):
      raise newException(ValueError,
        "mygo build: " & projectDir & " is not a directory")
    let configPath = projectDir / "mygo.json"
    if not fileExists(configPath):
      raise newException(ValueError,
        "mygo build: expected mygo.json in " & projectDir)
    let config = parseFile(configPath)
    if config.kind != JObject:
      raise newException(ValueError, "mygo.json must contain a JSON object")
    let name = configString(config, "name", projectDir.lastPathPart())
    let identifier = configString(config, "identifier",
      "com.mygo." & slug(name).replace("-", ""))
    let version = configString(config, "version", "0.1.0")
    if configString(config, "buildCommand", "").len > 0:
      raise newException(ValueError,
        "mygo build: configured buildCommand is not supported yet")
    let configuredOut = if outputOption.len > 0: outputOption
      else: configString(config, "out", "dist")
    let outputRoot = absolutePath(if isAbsolute(configuredOut): configuredOut
      else: projectDir / configuredOut)
    let source = if fileExists(projectDir / "src" / "main.nim"):
      projectDir / "src" / "main.nim" else: projectDir / "main.nim"
    if not fileExists(source):
      raise newException(ValueError,
        "mygo build: expected src/main.nim or main.nim in " & projectDir)

    let executable = slug(name) & (when hostOS == "windows": ".exe" else: "")
    let targetName = targetOs & "-" & targetArch
    createDir(outputRoot)
    let stage = createTempDir(".mygo-stage-", "", outputRoot)
    defer:
      if dirExists(stage):
        removeDir(stage)
    let cache = createTempDir(".mygo-cache-", "", outputRoot)
    defer:
      if dirExists(cache):
        removeDir(cache)

    when hostOS == "macosx":
      let bundleName = slug(name) & ".app"
      let bundle = stage / bundleName
      let contents = bundle / "Contents"
      let macOSDir = contents / "MacOS"
      let resourcesDir = contents / "Resources"
      createDir(macOSDir)
      createDir(resourcesDir)
      let binary = macOSDir / executable
      let compiled = compileApp(projectDir, source, binary, cache, debug)
      if compiled.code != 0:
        stderr.write(compiled.log)
        return 1
      projectResources.copyResources(projectDir, resourcesDir, targetOs,
        targetArch, config)
      writeInfoPlist(contents / "Info.plist", name, identifier, version,
        executable)
    else:
      let binary = stage / executable
      let compiled = compileApp(projectDir, source, binary, cache, debug)
      if compiled.code != 0:
        stderr.write(compiled.log)
        return 1
      projectResources.copyResources(projectDir, stage, targetOs, targetArch,
        config)

    let targetDir = outputRoot / targetName
    replaceBuildDir(stage, targetDir, outputRoot)
    stdout.writeLine("Built " & name & " for " & hostPlatform & " at " &
      targetDir)
    return 0
  except CatchableError as error:
    let message = if error.msg.startsWith("mygo build:"): error.msg
      else: "mygo build: " & error.msg
    stderr.writeLine(message)
    return 1
