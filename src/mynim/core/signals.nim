## signal_unix.go — turn the first SIGINT/SIGTERM into a normal app quit.

when defined(posix) and not defined(emscripten):
  from std/posix import Sigaction, Sigset, SIG_BLOCK, SIG_IGN, SIGINT, SIG_SETMASK,
    SIGTERM, pthread_sigmask, sigaddset, sigemptyset, sigwait

  var watchedSignals: Sigset
  var signalWaiter: Thread[void]

  proc cSigaction(signalNumber: cint; action, oldAction: ptr Sigaction): cint {.
    importc: "sigaction", header: "<signal.h>".}
  proc immediateExit(status: cint) {.importc: "_exit", header: "<unistd.h>",
      noreturn.}

  proc isIgnoredSignal(signalNumber: cint): bool =
    var current: Sigaction
    cSigaction(signalNumber, nil, addr current) == 0 and
      current.sa_handler == SIG_IGN

  proc requestAppQuitFromSignalThread() {.gcsafe.} =
    # Application.quit only posts the quit sequence to the main thread.
    {.cast(gcsafe).}:
      app.quit()

  proc waitForAppSignals() {.thread.} =
    var received: cint
    if sigwait(watchedSignals, received) != 0:
      return
    requestAppQuitFromSignalThread()
    if sigwait(watchedSignals, received) == 0:
      immediateExit(128 + received)

  proc quitOnSignals() =
    discard sigemptyset(watchedSignals)
    var hasSignals = false
    for signalNumber in [SIGINT, SIGTERM]:
      # Preserve signals ignored by the process that launched this app.
      if not isIgnoredSignal(signalNumber) and
          sigaddset(watchedSignals, signalNumber) == 0:
        hasSignals = true
    if not hasSignals:
      return

    var oldMask: Sigset
    if pthread_sigmask(SIG_BLOCK, watchedSignals, oldMask) != 0:
      return
    try:
      createThread(signalWaiter, waitForAppSignals)
    except CatchableError:
      var ignoredMask: Sigset
      discard pthread_sigmask(SIG_SETMASK, oldMask, ignoredMask)
else:
  proc quitOnSignals() = discard
