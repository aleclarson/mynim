import std/[assertions, json, os, osproc, strtabs, streams, strutils, tempfiles]
import ../src/cmd/init

proc run(command: string; args: seq[string]; workingDir: string):
    tuple[code: int, output: string] =
  let process = startProcess(command, args = args, workingDir = workingDir,
    options = {poUsePath, poStdErrToStdOut})
  try:
    result.output = process.outputStream.readAll()
    result.code = process.waitForExit()
  finally:
    process.close()

proc waitForRuns(marker: string; process: Process; count, timeoutMs: int): bool =
  var elapsed = 0
  while elapsed < timeoutMs:
    if fileExists(marker):
      try:
        if parseInt(readFile(marker).strip()) >= count:
          return true
      except ValueError:
        discard
    if process.peekExitCode() != -1:
      return false
    sleep(50)
    elapsed += 50

proc testDevRebuildsAndRestartsNativeApp() =
  let temporary = createTempDir("mynim-dev-test-", "")
  defer:
    if dirExists(temporary):
      removeDir(temporary)
  let project = temporary / "project with spaces"
  doAssert runInit(@["--nim-xplat", getCurrentDir(), project]) == 0
  let marker = temporary / "runs.txt"
  let sourcePath = project / "src" / "main.nim"
  writeFile(sourcePath, """import std/[os, strutils]
import mynim

app.setName("Dev integration")
echo app.name()
echo getEnv("MYNIM_LOCALE")
if getEnv("NIM_XPLAT_GENERATE").len == 0:
  let marker = getEnv("MYNIM_DEV_TEST_MARKER")
  let count = if fileExists(marker): parseInt(readFile(marker).strip()) else: 0
  writeFile(marker, $(count + 1))
  if count == 0:
    while true:
      sleep(25)
""")

  let nimble = findExe("nimble")
  doAssert nimble.len > 0, "nimble was not found on PATH"
  let nim = findExe("nim")
  doAssert nim.len > 0, "nim was not found on PATH"
  let cli = temporary / "nim-xplat"
  let builtCli = run(nim, @[
    "c", "--path:src", "--out:" & cli,
    getCurrentDir() / "src" / "cmd" / "nim_xplat.nim"], getCurrentDir())
  doAssert builtCli.code == 0, builtCli.output

  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env["MYNIM_DEV_TEST_MARKER"] = marker
  env.del("NIM_XPLAT_GENERATE")
  var devArgs = @[
    "dev", "-lang", "en-XA", project]
  when hostOS == "macosx":
    let fakeBin = temporary / "fake-bin"
    createDir(fakeBin)
    let fakeCodesign = fakeBin / "codesign"
    writeFile(fakeCodesign, """#!/bin/sh
printf '%s\n' "$*" >> "$MYNIM_TEST_CODESIGN_LOG"
exit 0
""")
    setFilePermissions(fakeCodesign, {fpUserRead, fpUserWrite, fpUserExec})
    env["PATH"] = fakeBin & ":" & getEnv("PATH")
    env["MYNIM_TEST_CODESIGN_LOG"] = temporary / "codesign-calls.txt"
    devArgs.insert("Development Identity", 1)
    devArgs.insert("-sign", 1)
  let process = startProcess(cli, args = devArgs,
    workingDir = project, env = env, options = {poUsePath, poStdErrToStdOut})
  try:
    if not waitForRuns(marker, process, 1, 60_000):
      let status = process.peekExitCode()
      if status == -1:
        process.terminate()
      discard process.waitForExit()
      let output = process.outputStream.readAll()
      doAssert false, "dev app did not launch (status " & $status & "): " &
        output
    let configPath = project / "mygo.json"
    var config = parseFile(configPath)
    config["name"] = %"Dev Reloaded"
    writeFile(configPath, $config)
    writeFile(sourcePath, readFile(sourcePath) & "\n# reload trigger\n")
    let code = process.waitForExit(timeout = 120_000)
    doAssert code == 0, "dev failed; output: " & process.outputStream.readAll()
    let output = process.outputStream.readAll()
    doAssert readFile(marker).strip() == "2"
    doAssert "src/main.nim" in output, output
    doAssert "Dev integration Dev" in output, output
    doAssert "en-XA" in output, output
    doAssert "Running updated Dev Reloaded Dev" in output, output
    when hostOS == "macosx":
      let signingCalls = readFile(env["MYNIM_TEST_CODESIGN_LOG"])
      doAssert "--sign Development Identity" in signingCalls, signingCalls
  finally:
    if process.peekExitCode() == -1:
      process.terminate()
      discard process.waitForExit()
    process.close()

testDevRebuildsAndRestartsNativeApp()
