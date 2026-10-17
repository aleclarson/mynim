## Build, run, and watch a native MyNim application during development.

import std/[algorithm, hashes, httpclient, json, os, osproc, streams, strtabs,
  strutils, tables, tempfiles]
import ./build as nativeBuild
import ./generate
import ./resources as projectResources

type DevSnapshot = Table[string, string]
type DevSettings = tuple[name, identifier, version, devCommand, devUrl,
  frontendDist: string]

const usageDev = """Usage: mygo dev [flags] [dir]

Build and run a native project, rebuilding it when Nim source, resources,
catalogs, or project configuration changes.

Flags:
  -skip-dev-command  do not start devCommand from mygo.json
  -sign identity     custom signing is not ported yet
  -lang tag          run in a language such as de or zh-Hant
  -web               browser development is not ported yet
  -h, --help         show this help
"""

proc watchFile(relative: string): bool =
  let path = relative.replace('\\', '/')
  if path in ["mygo.json", "nim.cfg", "config.nims"] or
      path.endsWith(".nim") or path.endsWith(".nims") or
      path.endsWith(".nimble"):
    return true
  path.startsWith("resources/") or path.startsWith("locales/")

proc ignoredDirectory(relative: string): bool =
  let name = relative.lastPathPart()
  name.startsWith(".") or name in ["node_modules", "build", "dist", "out",
    "nimcache", "vendor-cache"]

proc snapshotDir(dir, relative: string; snapshot: var DevSnapshot) =
  try:
    for kind, path in walkDir(dir):
      let name = path.lastPathPart()
      let rel = (if relative.len == 0: name else: relative / name)
        .replace('\\', '/')
      case kind
      of pcDir:
        if not ignoredDirectory(rel) and rel != "frontend" and
            not rel.startsWith("frontend/"):
          snapshotDir(path, rel, snapshot)
      of pcFile:
        if not watchFile(rel):
          continue
        try:
          let info = getFileInfo(path, followSymlink = false)
          var stamp = $info.size & ":" & $info.lastWriteTime
          if info.size <= 8 * 1024 * 1024:
            stamp.add ":" & $hash(readFile(path))
          snapshot[rel] = stamp
        except CatchableError:
          discard
      else:
        discard
  except CatchableError:
    discard

proc fileSnapshot(projectDir: string): DevSnapshot =
  result = initTable[string, string]()
  snapshotDir(projectDir, "", result)

proc changedFiles(before, after: DevSnapshot): seq[string] =
  for path, stamp in before:
    if not after.hasKey(path) or after[path] != stamp:
      result.add path
  for path in after.keys:
    if not before.hasKey(path):
      result.add path
  result.sort()

proc stableChanges(projectDir: string; previous: DevSnapshot):
    tuple[snapshot: DevSnapshot, paths: seq[string]] =
  var current = fileSnapshot(projectDir)
  if current == previous:
    return (current, @[])
  var stableScans = 0
  while stableScans < 2:
    sleep(150)
    let next = fileSnapshot(projectDir)
    if next == current:
      inc stableScans
    else:
      current = next
      stableScans = 0
  (current, changedFiles(previous, current))

proc captured(command: string; args: seq[string]; workingDir: string):
    tuple[code: int, output: string] =
  let process = startProcess(command, args = args, workingDir = workingDir,
    options = {poUsePath, poStdErrToStdOut})
  try:
    result.output = process.outputStream.readAll()
    result.code = process.waitForExit()
  finally:
    process.close()

proc appEnvironment(projectDir, devUrl, frontendDist, lang: string):
    StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["MYNIM_DEV"] = "1"
  result["MYNIM_DEV_URL"] = devUrl
  result["MYGO_DEV_URL"] = devUrl
  if frontendDist.len > 0:
    result["MYGO_FRONTEND_DIST"] = absolutePath(
      if isAbsolute(frontendDist): frontendDist else: projectDir / frontendDist)
  if lang.len > 0:
    result["MYNIM_LOCALE"] = lang
    result["MYGO_LOCALE"] = lang

proc appExecutable(stage, name: string):
    tuple[executable, resources: string] =
  let binary = nativeBuild.slug(name) & "-dev" &
    (when hostOS == "windows": ".exe" else: "")
  when hostOS == "macosx":
    let bundle = stage / (nativeBuild.slug(name) & "-dev.app")
    let contents = bundle / "Contents"
    let executablePath = contents / "MacOS" / binary
    createDir(executablePath.parentDir())
    createDir(contents / "Resources")
    result = (executablePath, contents / "Resources")
  else:
    result = (stage / binary, stage)

proc buildDevApp(projectDir, source, devRoot, name, identifier, version: string;
    config: JsonNode): tuple[stage, executable: string, code: int, log: string] =
  result.stage = createTempDir(".mynim-dev-", "", devRoot)
  try:
    let nimble = findExe("nimble")
    if nimble.len == 0:
      raise newException(IOError, "nimble was not found on PATH")
    let (executable, resourceDir) = appExecutable(result.stage, name)
    var args = @[
      "c", "--nimcache:" & (result.stage / "nimcache"),
      "--out:" & executable]
    when hostOS == "windows":
      args.add "--app:gui"
    args.add source
    let compiled = captured(nimble, args, projectDir)
    if compiled.code != 0:
      result.code = compiled.code
      result.log = compiled.output
      removeDir(result.stage)
      result.stage = ""
      return
    let cache = result.stage / "nimcache"
    if dirExists(cache):
      removeDir(cache)
    let (osName, arch, _) = nativeBuild.hostTarget()
    projectResources.copyResources(projectDir, resourceDir, osName, arch,
      config)
    when hostOS == "macosx":
      nativeBuild.writeInfoPlist(resourceDir.parentDir() / "Info.plist",
        name & " Dev", identifier & ".dev", version, executable.lastPathPart())
    result.executable = executable
    result.code = 0
  except CatchableError as error:
    result.code = 1
    result.log = error.msg
    if result.stage.len > 0 and dirExists(result.stage):
      try: removeDir(result.stage)
      except CatchableError: discard
    result.stage = ""

proc launchApp(executable, projectDir, devUrl, frontendDist, lang: string):
    Process =
  startProcess(executable, workingDir = projectDir,
    env = appEnvironment(projectDir, devUrl, frontendDist, lang),
    options = {poParentStreams, poUsePath})

proc projectSettings(projectDir: string; config: JsonNode): DevSettings =
  result.name = nativeBuild.configString(config, "name",
    projectDir.lastPathPart())
  result.identifier = nativeBuild.configString(config, "identifier",
    "com.mygo." & nativeBuild.slug(result.name).replace("-", ""))
  result.version = nativeBuild.configString(config, "version", "0.1.0")
  result.devCommand = nativeBuild.configString(config, "devCommand", "")
  result.devUrl = nativeBuild.configString(config, "devUrl", "")
  result.frontendDist = nativeBuild.configString(config, "frontendDist", "")

proc stopProcess(process: var Process) =
  if process == nil:
    return
  if process.peekExitCode() == -1:
    process.terminate()
    var elapsed = 0
    while elapsed < 2000 and process.peekExitCode() == -1:
      sleep(50)
      elapsed += 50
    if process.peekExitCode() == -1:
      process.kill()
  try: discard process.waitForExit()
  except CatchableError: discard
  process.close()
  process = nil

proc startCommand(command, projectDir: string): Process =
  when defined(windows):
    let shell = getEnv("COMSPEC", "cmd.exe")
    startProcess(shell, args = @["/C", command], workingDir = projectDir,
      options = {poParentStreams, poUsePath})
  else:
    startProcess("/bin/sh", args = @["-c", command], workingDir = projectDir,
      options = {poParentStreams, poUsePath})

proc waitForDevUrl(url: string; server: Process): bool =
  const timeoutMs = 90_000
  var elapsed = 0
  while elapsed < timeoutMs:
    if server != nil and server.peekExitCode() != -1:
      return false
    var client = newHttpClient(timeout = 1000)
    try:
      discard client.get(url)
      client.close()
      return true
    except CatchableError:
      client.close()
    sleep(250)
    elapsed += 250

proc runDev*(args: seq[string]): int =
  var skipDevCommand = false
  var web = false
  var lang, sign = ""
  var paths: seq[string]
  var index = 0
  while index < args.len:
    let arg = args[index]
    if arg == "--":
      for rest in index + 1 ..< args.len:
        paths.add args[rest]
      break
    if arg in ["-h", "--help"]:
      stdout.write(usageDev)
      return 0
    if arg == "-skip-dev-command" or arg == "--skip-dev-command":
      skipDevCommand = true
    elif arg == "-web" or arg == "--web":
      web = true
    elif arg.startsWith("-"):
      let equalAt = arg.find('=')
      let flag = if equalAt < 0: arg else: arg[0 ..< equalAt]
      if flag notin ["-lang", "--lang", "-sign", "--sign"]:
        stderr.writeLine("mygo dev: unknown flag " & flag)
        stderr.write(usageDev)
        return 2
      var value = ""
      if equalAt >= 0:
        if equalAt + 1 < arg.len:
          value = arg[equalAt + 1 .. ^1]
      else:
        inc index
        if index < args.len:
          value = args[index]
      if value.len == 0:
        stderr.writeLine("mygo dev: missing value for " & flag)
        return 2
      if flag in ["-lang", "--lang"]: lang = value
      else: sign = value
    else:
      paths.add arg
    inc index

  if paths.len > 1:
    stderr.writeLine("mygo dev: expected at most one project directory")
    stderr.write(usageDev)
    return 2
  if web:
    stderr.writeLine("mygo dev: browser development is not ported yet")
    return 1
  if sign.len > 0 and sign != "-":
    stderr.writeLine("mygo dev: code signing is not ported yet")
    return 1

  var app: Process
  var server: Process
  var currentStage = ""
  try:
    let projectDir = if paths.len == 0: getCurrentDir()
      else: absolutePath(paths[0])
    if not dirExists(projectDir):
      raise newException(ValueError,
        "mygo dev: " & projectDir & " is not a directory")
    let configPath = projectDir / "mygo.json"
    if not fileExists(configPath):
      raise newException(ValueError,
        "mygo dev: expected mygo.json in " & projectDir)
    var config = parseFile(configPath)
    if config.kind != JObject:
      raise newException(ValueError, "mygo.json must contain a JSON object")
    var settings = projectSettings(projectDir, config)
    let source = if fileExists(projectDir / "src" / "main.nim"):
      projectDir / "src" / "main.nim" else: projectDir / "main.nim"
    if not fileExists(source):
      raise newException(ValueError,
        "mygo dev: expected src/main.nim or main.nim in " & projectDir)
    var watched = fileSnapshot(projectDir)

    if runGenerate(@[projectDir]) != 0:
      return 1
    if not skipDevCommand and settings.devCommand.len > 0:
      server = startCommand(settings.devCommand, projectDir)
    if settings.devUrl.len > 0 and not waitForDevUrl(settings.devUrl, server):
      raise newException(IOError,
        if server != nil and server.peekExitCode() != -1:
          "devCommand exited before devUrl answered"
        else: "timed out waiting for devUrl " & settings.devUrl)

    let devDir = projectDir / ".mygo" / "dev"
    createDir(devDir)
    let (_, _, platformName) = nativeBuild.hostTarget()
    var built = buildDevApp(projectDir, source, devDir, settings.name,
      settings.identifier, settings.version, config)
    if built.code != 0:
      stderr.writeLine("mygo dev: app compilation failed")
      stderr.writeLine(built.log)
      return 1
    currentStage = built.stage
    stdout.writeLine("Built " & settings.name & " Dev for " & platformName)
    app = launchApp(built.executable, projectDir, settings.devUrl,
      settings.frontendDist, lang)
    stdout.writeLine("Running " & settings.name & " Dev; press Ctrl+C to quit")

    while true:
      let code = app.peekExitCode()
      if code != -1:
        app.close()
        app = nil
        if code == 75:
          app = launchApp(built.executable, projectDir, settings.devUrl,
            settings.frontendDist, lang)
          continue
        if code == 0:
          return 0
        stderr.writeLine("mygo dev: app exited with status " & $code &
          "; waiting for a source change")

      let (nextSnapshot, changed) = stableChanges(projectDir, watched)
      if changed.len == 0:
        continue
      watched = nextSnapshot
      stdout.writeLine("Changed: " & changed.join(", "))
      var nextConfig: JsonNode
      var nextSettings: DevSettings
      try:
        nextConfig = parseFile(configPath)
        if nextConfig.kind != JObject:
          raise newException(ValueError,
            "mygo.json must contain a JSON object")
        nextSettings = projectSettings(projectDir, nextConfig)
      except CatchableError as error:
        stderr.writeLine("mygo dev: invalid configuration; keeping the current app: " &
          error.msg)
        continue
      if runGenerate(@[projectDir]) != 0:
        stderr.writeLine("mygo dev: keeping the current app after generation failed")
        continue
      let next = buildDevApp(projectDir, source, devDir, nextSettings.name,
        nextSettings.identifier, nextSettings.version, nextConfig)
      if next.code != 0:
        stderr.writeLine("mygo dev: app compilation failed; keeping the current app")
        stderr.writeLine(next.log)
        continue
      stopProcess(app)
      let previousStage = currentStage
      built = next
      currentStage = built.stage
      try:
        if not skipDevCommand and
            (settings.devCommand != nextSettings.devCommand or
             settings.devUrl != nextSettings.devUrl):
          stopProcess(server)
          if nextSettings.devCommand.len > 0:
            server = startCommand(nextSettings.devCommand, projectDir)
          if nextSettings.devUrl.len > 0 and
              not waitForDevUrl(nextSettings.devUrl, server):
            raise newException(IOError,
              "devCommand failed to serve devUrl " & nextSettings.devUrl)
        app = launchApp(built.executable, projectDir, nextSettings.devUrl,
          nextSettings.frontendDist, lang)
        if previousStage.len > 0 and dirExists(previousStage):
          try: removeDir(previousStage)
          except CatchableError: discard
      except CatchableError:
        currentStage = previousStage
        try: removeDir(built.stage)
        except CatchableError: discard
        raise
      config = nextConfig
      settings = nextSettings
      stdout.writeLine("Running updated " & settings.name & " Dev")
  except CatchableError as error:
    stderr.writeLine("mygo dev: " & error.msg)
    return 1
  finally:
    stopProcess(app)
    stopProcess(server)
    if currentStage.len > 0 and dirExists(currentStage):
      try: removeDir(currentStage)
      except CatchableError: discard
