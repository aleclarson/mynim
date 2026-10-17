import std/[assertions, json, os, osproc, strtabs, streams, strutils, tempfiles]
import ../src/cmd/init

proc run(command: string; args: seq[string]; workingDir: string;
    env: StringTableRef = nil):
    tuple[code: int, output: string] =
  let process = startProcess(command, args = args, workingDir = workingDir,
    env = env, options = {poUsePath, poStdErrToStdOut})
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

  let invalidLocale = run(cli, @[
    "dev", "-lang", "C", project], project)
  doAssert invalidLocale.code == 1, invalidLocale.output
  doAssert "-lang \"C\" is not a language" in invalidLocale.output,
    invalidLocale.output

  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env["MYNIM_DEV_TEST_MARKER"] = marker
  env.del("NIM_XPLAT_GENERATE")
  var devArgs = @[
    "dev", "-lang", "en-xa", project]
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

when not defined(windows):
  proc testDevTerminalShortcuts(cli, project, marker: string;
      env: StringTableRef) =
    let python = findExe("python3")
    if python.len == 0:
      return
    if fileExists(marker):
      removeFile(marker)
    writeFile(project / "src" / "main.nim", """import std/[os, strutils]
import mynim

app.setName("Dev integration")
if getEnv("NIM_XPLAT_GENERATE").len == 0:
  let marker = getEnv("MYNIM_DEV_TEST_MARKER")
  let count = if fileExists(marker): parseInt(readFile(marker).strip()) else: 0
  writeFile(marker, $(count + 1))
  while true:
    sleep(25)
""")
    let ptyScript = """import os, pty, select, sys, time

cli, project, marker = sys.argv[1:]
pid, master = pty.fork()
if pid == 0:
    os.execv(cli, [cli, "dev", project])
output = bytearray()
child_done = False
child_code = None

def poll_output():
    global child_done, child_code
    ready, _, _ = select.select([master], [], [], 0.05)
    if ready:
        try:
            output.extend(os.read(master, 4096))
        except OSError:
            pass
    if not child_done:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            child_done = True
            child_code = os.waitstatus_to_exitcode(status)

def wait_for(predicate, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and not child_done:
        poll_output()
        if predicate():
            return True
    return predicate()

def count_runs():
    try:
        return int(open(marker).read().strip())
    except (OSError, ValueError):
        return 0

def fail(message):
    try:
        os.write(master, b"q\n")
    except OSError:
        pass
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline and not child_done:
        poll_output()
    if not child_done:
        os.kill(pid, 15)
        os.waitpid(pid, 0)
    print(output.decode(errors="replace"), end="")
    print(message, file=sys.stderr)
    sys.exit(1)

if not wait_for(lambda: count_runs() >= 1, 90):
    fail("dev app did not start under a pseudo-terminal")
wait_for(lambda: b"Changed:" in output, 2)
if b"Changed:" in output and not wait_for(
        lambda: b"Running updated " in output, 90):
    fail("initial dev rebuild did not finish")
wait_for(lambda: False, 2)
before_restart = count_runs()
os.write(master, b"h\n")
if not wait_for(lambda: b"Shortcuts" in output, 10):
    fail("h + enter did not print shortcut help")
os.write(master, b"c\n")
if not wait_for(lambda: b"\x1b[2J\x1b[H" in output, 10):
    fail("c + enter did not clear the console")
os.write(master, b"r\n")
if not wait_for(lambda: count_runs() > before_restart, 90):
    fail("r + enter did not rebuild and restart the app")
os.write(master, b"q\n")
deadline = time.monotonic() + 15
while time.monotonic() < deadline and not child_done:
    poll_output()
if not child_done:
    fail("q + enter did not stop dev")
print(output.decode(errors="replace"), end="")
sys.exit(child_code)
"""
    let checked = run(python, @[
      "-c", ptyScript, cli, project, marker], project, env)
    doAssert checked.code == 0, checked.output
    doAssert "Shortcuts" in checked.output, checked.output
    doAssert "Restarting project Dev" in checked.output, checked.output

  proc testDevTerminalShortcutsOnPty() =
    let temporary = createTempDir("mynim-dev-keys-test-", "")
    defer:
      if dirExists(temporary):
        removeDir(temporary)
    let project = temporary / "project"
    doAssert runInit(@["--nim-xplat", getCurrentDir(), project]) == 0
    let cli = getTempDir() / "mynim-dev-keys-cli"
    let nim = findExe("nim")
    let builtCli = run(nim, @[
      "c", "--path:src", "--out:" & cli,
      getCurrentDir() / "src" / "cmd" / "nim_xplat.nim"], getCurrentDir())
    doAssert builtCli.code == 0, builtCli.output
    defer:
      if fileExists(cli): removeFile(cli)
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      env[key] = value
    let marker = temporary / "runs.txt"
    env["MYNIM_DEV_TEST_MARKER"] = marker
    testDevTerminalShortcuts(cli, project, marker, env)

  testDevTerminalShortcutsOnPty()
