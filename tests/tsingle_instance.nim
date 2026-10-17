import std/assertions

include "../src/mynim.nim"

when defined(posix) and not defined(emscripten):
  import mynim/internal/fake as fakeBackend

  proc useFakeBackend() =
    theBackend = platform.Backend(fakeBackend.newFakeBackend())
    backendMade = true

  proc runServer(name, readyPath, receivedPath: string) =
    useFakeBackend()
    app.setName(name)
    discard app.onSecondInstance(proc(args: seq[string], workingDir: string) =
      doAssert isMainThread()
      writeFile(receivedPath, $(%*{
        "args": args,
        "workingDir": workingDir
      }))
      app.quit())
    discard app.onReady(proc() = writeFile(readyPath, "ready"))
    doAssert app.requestSingleInstanceLock()
    doAssert app.requestSingleInstanceLock()
    app.run()

  proc waitForFile(path: string; process: Process;
      timeoutMs = 5_000): bool =
    for _ in 0 ..< timeoutMs div 10:
      if fileExists(path):
        return true
      if not process.running():
        return false
      sleep(10)
    fileExists(path)

  proc stopProcess(process: var Process) =
    if process.running():
      process.terminate()
      discard process.waitForExit(2_000)
    process.close()

  if paramCount() > 0 and paramStr(1) == "--mynim-si-server":
    runServer(paramStr(2), paramStr(3), paramStr(4))
    quit(0)
  elif paramCount() > 0 and paramStr(1) == "--mynim-si-client":
    useFakeBackend()
    app.setName(paramStr(2))
    quit(if app.requestSingleInstanceLock(): 7 else: 0)
  else:
    block forwards_a_later_launch_and_cleans_up:
      let dir = createTempDir("mynim-single-instance-", "")
      defer:
        if dirExists(dir):
          removeDir(dir)
      let
        name = "mynim-single-instance-test-" & $getCurrentProcessId()
        readyPath = dir / "ready"
        receivedPath = dir / "received.json"

      useFakeBackend()
      app.setName(name)
      let stalePath = socketPath(singleInstanceKey(app.name()))
      defer:
        if fileExists(stalePath):
          removeFile(stalePath)
      writeFile(stalePath, "stale socket entry")

      var server = startProcess(getAppFilename(),
        args = ["--mynim-si-server", name, readyPath, receivedPath],
        workingDir = getCurrentDir())
      defer: stopProcess(server)
      doAssert waitForFile(readyPath, server),
        "the primary instance did not start"

      var client = startProcess(getAppFilename(),
        args = ["--mynim-si-client", name, "alpha", "beta"],
        workingDir = dir)
      defer: stopProcess(client)
      doAssert client.waitForExit(5_000) == 0,
        "the later instance did not forward its arguments and exit"
      doAssert waitForFile(receivedPath, server),
        "the primary instance did not receive the forwarded arguments"

      let forwarded = parseFile(receivedPath)
      doAssert forwarded["args"] == %*["--mynim-si-client", name, "alpha", "beta"]
      doAssert forwarded["workingDir"].getStr() == expandFilename(dir),
        "forwarded working directory was " &
          forwarded["workingDir"].getStr() & ", expected " & expandFilename(dir)
      doAssert server.waitForExit(5_000) == 0,
        "the primary instance did not finish after the forwarded launch"
      doAssert not fileExists(stalePath),
        "the single-instance socket entry remained after app quit"
else:
  doAssert maxSecondInstanceMessage == 1 shl 20
  let off = app.onSecondInstance(proc(args: seq[string], workingDir: string) =
    discard)
  off()
