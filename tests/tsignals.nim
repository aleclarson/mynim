import std/assertions

include "../src/mynim.nim"

when defined(posix):
  from std/posix import SIGINT, SIGKILL, SIGTERM, SIG_IGN, Pid, kill, signal
  import mynim/internal/fake as fakeBackend

  proc runSignalChild(mode, readyPath, quitPath: string) =
    let fake = fakeBackend.newFakeBackend()
    theBackend = platform.Backend(fake)
    backendMade = true
    fake.init(AppHandlerImpl(), platform.AppOptions(name: "signal test"))
    if mode == "ignored":
      discard signal(SIGINT, SIG_IGN)
      doAssert isIgnoredSignal(SIGINT)

    discard app.onReady(proc() = writeFile(readyPath, "ready"))
    discard app.onBeforeQuit(proc(e: var QuitEvent) =
      writeFile(quitPath, "quit")
      if mode == "double":
        sleep(10_000))
    app.run()
    quit(0)

  proc awaitFile(path: string; child: Process; timeoutMs = 5_000): bool =
    let attempts = timeoutMs div 10
    for _ in 0 ..< attempts:
      if fileExists(path):
        return true
      if not child.running():
        return false
      sleep(10)
    fileExists(path)

  proc sendSignal(child: Process; sig: cint) =
    doAssert kill(Pid(child.processID()), sig) == 0

  proc stopChild(child: Process) =
    if child.running():
      discard kill(Pid(child.processID()), SIGKILL)
      discard child.waitForExit(2_000)
    child.close()

  proc startSignalChild(dir, mode: string): tuple[process: Process,
      readyPath, quitPath: string] =
    result.readyPath = dir / (mode & ".ready")
    result.quitPath = dir / (mode & ".quit")
    result.process = startProcess(getAppFilename(),
      args = ["--mynim-signal-child", mode, result.readyPath,
        result.quitPath], workingDir = getCurrentDir())

  if paramCount() > 0 and paramStr(1) == "--mynim-signal-child":
    runSignalChild(paramStr(2), paramStr(3), paramStr(4))
  else:
    block signal_requests_normal_quit:
      let dir = getTempDir() / ("mynim-signals-" & $getCurrentProcessId())
      createDir(dir)
      defer: removeDir(dir)

      var child = startSignalChild(dir, "normal")
      defer: stopChild(child.process)
      doAssert awaitFile(child.readyPath, child.process), "child did not start"
      sendSignal(child.process, SIGINT)
      doAssert awaitFile(child.quitPath, child.process),
        "first signal did not start the cancelable quit sequence"
      doAssert child.process.waitForExit(5_000) == 0,
        "normal signal quit should return from App.Run"

    block second_signal_exits_immediately:
      let dir = getTempDir() / ("mynim-signals-double-" &
        $getCurrentProcessId())
      createDir(dir)
      defer: removeDir(dir)

      var child = startSignalChild(dir, "double")
      defer: stopChild(child.process)
      doAssert awaitFile(child.readyPath, child.process), "child did not start"
      sendSignal(child.process, SIGINT)
      doAssert awaitFile(child.quitPath, child.process),
        "first signal did not start the quit sequence"
      sendSignal(child.process, SIGTERM)
      let exitCode = child.process.waitForExit(5_000)
      doAssert exitCode == 128 + SIGTERM,
        "second signal should exit with 128 plus its signal number; got " &
          $exitCode

    block ignored_signal_stays_ignored:
      let dir = getTempDir() / ("mynim-signals-ignored-" &
        $getCurrentProcessId())
      createDir(dir)
      defer: removeDir(dir)

      var child = startSignalChild(dir, "ignored").process
      defer: stopChild(child)

      let readyPath = dir / "ignored.ready"
      let quitPath = dir / "ignored.quit"
      doAssert awaitFile(readyPath, child), "child did not start"
      sendSignal(child, SIGINT)
      sleep(250)
      doAssert not fileExists(quitPath), "pre-ignored SIGINT was handled"
      sendSignal(child, SIGTERM)
      doAssert awaitFile(quitPath, child), "SIGTERM should still trigger quit"
      doAssert child.waitForExit(5_000) == 0
