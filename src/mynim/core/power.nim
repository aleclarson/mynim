## power.go — power and session changes, keeping the computer awake.


proc powerStart(p: var PowerModule; l: var Listeners[proc() {.closure.}];
                fn: proc() {.closure.}): proc() {.closure.} =
  ## Registers fn and starts watching on first use.
  p.mu.acquire()
  p.watching = true
  let off = l.add(fn, false)
  p.mu.release()
  app.whenReady(proc() = backend().power().watch())
  off

proc onSuspend*(p: var PowerModule; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the system is about to sleep.
  powerStart(p, p.onSuspend, fn)
proc onResume*(p: var PowerModule; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the system woke up.
  powerStart(p, p.onResume, fn)
proc onLockScreen*(p: var PowerModule; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the session is locked.
  powerStart(p, p.onLockScreen, fn)
proc onUnlockScreen*(p: var PowerModule; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the session is unlocked.
  powerStart(p, p.onUnlockScreen, fn)

proc event*(p: var PowerModule; event: string) =
  case event
  of "suspend": fire(p.onSuspend)
  of "resume": fire(p.onResume)
  of "lock-screen": fire(p.onLockScreen)
  of "unlock-screen": fire(p.onUnlockScreen)
  else: discard

proc keepAwake*(p: var PowerModule; reason: string; display: bool): proc() {.closure.} =
  ## Keeps the computer from sleeping while idle, and with display the
  ## display from turning off, e.g. during a long task or while a video
  ## plays, until release is called:
  ##
  ##   let release = power.keepAwake("Exporting the video", false)
  ##   defer: release()
  ##
  ## The reason shows where the system lists what keeps it awake.
  needsApp("power.keepAwake")
  var r: ReleaseProc
  onMain(proc() = r = backend().power().keepAwake(display, reason))
  if r == nil:
    return proc() = discard
  var once = false
  var onceLock: Lock
  proc() =
    onceLock.acquire()
    if not once:
      once = true
      onceLock.release()
      onMain(r)
    else:
      onceLock.release()

proc isOnBattery*(p: var PowerModule): bool =
  ## Whether the computer runs on battery power.
  onMainValue(proc(): bool = backend().power().onBattery())

proc idleTime*(p: var PowerModule): Duration =
  ## How long the user has not used the keyboard or mouse, or 0 when
  ## the system does not tell (some Linux desktops).
  needsApp("power.idleTime")
  onMainValue(proc(): Duration = backend().power().idleTime())
