## Generate the typed TypeScript client of a MyNim application.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles]
import ./i18n_generate

const usageGenerate = """Usage: mynim generate [-o file] [dir]

Write the TypeScript client for the services and events bound by the app, and
`catalog_gen.nim` when i18n catalogs are configured. Web frontends also get a
typed TypeScript module for their catalogs next to the client. The client
output defaults to bindings in mygo.json, or the conventional path for a
project with a frontend. Apps without a frontend produce no client by default.

Flags:
  -o, --output file  output file (overrides mygo.json)
  -h, --help         show this help
"""

proc processOutput(command: string; args: seq[string]; workingDir: string;
    env: StringTableRef = nil): tuple[code: int, output: string] =
  let process = startProcess(command, args = args, workingDir = workingDir,
    env = env, options = {poUsePath, poStdErrToStdOut})
  try:
    result.output = process.outputStream.readAll()
    result.code = process.waitForExit()
  finally:
    process.close()

proc generationOutput(projectDir: string; config: JsonNode): string =
  if config != nil and config.hasKey("bindings"):
    if config["bindings"].kind != JString:
      raise newException(ValueError, "mygo.json: bindings must be a string")
    let configured = config["bindings"].getStr()
    if configured.len == 0:
      return ""
    return absolutePath(if isAbsolute(configured): configured
      else: projectDir / configured)

  if dirExists(projectDir / "frontend"):
    return projectDir / "frontend" / "src" / "mygo.ts"
  if fileExists(projectDir / "package.json"):
    return projectDir / "src" / "mygo.ts"
  if config != nil:
    for key in ["devUrl", "devCommand", "buildCommand", "frontendDist"]:
      if config.hasKey(key) and config[key].kind == JString and
          config[key].getStr().len > 0:
        return projectDir / "mygo.ts"

proc runGenerate*(args: seq[string]): int =
  var outputOption = ""
  var paths: seq[string]
  var index = 0
  while index < args.len:
    let arg = args[index]
    if arg == "--":
      for rest in index + 1 ..< args.len:
        paths.add args[rest]
      break
    if arg in ["-h", "--help"]:
      stdout.write(usageGenerate)
      return 0
    if arg.startsWith("-"):
      let equalAt = arg.find('=')
      let flag = if equalAt < 0: arg else: arg[0 ..< equalAt]
      if flag notin ["-o", "--output"]:
        stderr.writeLine("mynim generate: unknown flag " & flag)
        stderr.write(usageGenerate)
        return 2
      if equalAt >= 0:
        if equalAt + 1 < arg.len:
          outputOption = arg[equalAt + 1 .. ^1]
      else:
        inc index
        if index >= args.len:
          stderr.writeLine("mynim generate: missing value for " & flag)
          return 2
        outputOption = args[index]
      if outputOption.len == 0:
        stderr.writeLine("mynim generate: missing value for " & flag)
        return 2
    else:
      paths.add arg
    inc index

  if paths.len > 1:
    stderr.writeLine("mynim generate: expected at most one project directory")
    stderr.write(usageGenerate)
    return 2

  try:
    let projectDir = if paths.len == 0: getCurrentDir()
      else: absolutePath(paths[0])
    if not dirExists(projectDir):
      raise newException(ValueError,
        "mynim generate: " & projectDir & " is not a directory")
    let source = if fileExists(projectDir / "src" / "main.nim"):
      projectDir / "src" / "main.nim" else: projectDir / "main.nim"
    if not fileExists(source):
      raise newException(ValueError,
        "mynim generate: expected src/main.nim or main.nim in " & projectDir)

    var config: JsonNode
    let configPath = projectDir / "mygo.json"
    if fileExists(configPath):
      config = parseFile(configPath)
      if config.kind != JObject:
        raise newException(ValueError,
          "mynim generate: mygo.json must contain a JSON object")

    let catalogModules = generateCatalogModules(projectDir, source, config,
      generationOutput(projectDir, config))

    let configuredOutput = if outputOption.len > 0:
      absolutePath(if isAbsolute(outputOption): outputOption
        else: projectDir / outputOption)
    else:
      generationOutput(projectDir, config)

    let tempDir = createTempDir("mygo-generate-", "")
    defer:
      if dirExists(tempDir):
        removeDir(tempDir)
    let generatedPath = if configuredOutput.len > 0: configuredOutput
      else: tempDir / "mygo.ts"
    let executable = tempDir / ("mygo-generate" &
      (when hostOS == "windows": ".exe" else: ""))
    let nimble = findExe("nimble")
    if nimble.len == 0:
      raise newException(IOError, "nimble was not found on PATH")

    let compile = processOutput(nimble, @[
      "c", "--nimcache:" & (tempDir / "nimcache"),
      "--out:" & executable, source], projectDir)
    if compile.code != 0:
      stderr.writeLine("mynim generate: app compilation failed")
      stderr.write(compile.output)
      return 1

    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      env[key] = value
    env["MYNIM_GENERATE"] = generatedPath
    let app = processOutput(executable, @[], projectDir, env)
    if app.code != 0:
      stderr.writeLine("mynim generate: app exited with status " & $app.code)
      stderr.write(app.output)
      return 1
    if configuredOutput.len > 0 and fileExists(configuredOutput):
      var shownPath = configuredOutput
      try:
        shownPath = relativePath(configuredOutput, projectDir)
      except ValueError:
        discard
      stdout.writeLine("Generated " & shownPath)
    if catalogModules.nimModule.len > 0:
      var shownPath = catalogModules.nimModule
      try:
        shownPath = relativePath(catalogModules.nimModule, projectDir)
      except ValueError:
        discard
      stdout.writeLine("Generated " & shownPath)
    if catalogModules.typescriptModule.len > 0:
      var shownPath = catalogModules.typescriptModule
      try:
        shownPath = relativePath(catalogModules.typescriptModule, projectDir)
      except ValueError:
        discard
      stdout.writeLine("Generated " & shownPath)
    return 0
  except CatchableError as error:
    stderr.writeLine("mynim generate: " & error.msg)
    return 1
