## power.go: powerImpl events and assertions.

type powerImpl = ref object of Power
  b*: Backend

## powerEvents maps the notifications the app delegate observes to power
## events.
const powerEvents = {
  "NSWorkspaceWillSleepNotification": "suspend",
  "NSWorkspaceDidWakeNotification": "resume",
  "com.apple.screenIsLocked": "lock-screen",
  "com.apple.screenIsUnlocked": "unlock-screen",
}

method watch*(p: powerImpl) =
  withPool(proc() =
    proc observe(center: id, name: string) =
      discard send(center, "addObserver:selector:name:object:",
                   argu(p.b.delegate),
                   argu(sel("mynimPowerNotification:")),
                   argu(nsString(name)), argu(nil))
    let ws = send(send(`class`("NSWorkspace"), "sharedWorkspace"),
                  "notificationCenter")
    observe(ws, "NSWorkspaceWillSleepNotification")
    observe(ws, "NSWorkspaceDidWakeNotification")
    # Screen locking is only announced to other processes.
    let distributed = send(`class`("NSDistributedNotificationCenter"),
                           "defaultCenter")
    observe(distributed, "com.apple.screenIsLocked")
    observe(distributed, "com.apple.screenIsUnlocked"))

method keepAwake*(p: powerImpl, display: bool, reason: string): proc() =
  const idleSystemSleepDisabled = 1'u64 shl 20
  const idleDisplaySleepDisabled = 1'u64 shl 40
  var opts = idleSystemSleepDisabled
  if display:
    opts = opts or idleDisplaySleepDisabled
  var token: id
  withPool(proc() =
    let info = send(`class`("NSProcessInfo"), "processInfo")
    token = retain(send(info, "beginActivityWithOptions:reason:",
                        argu(opts), argu(nsString(reason)))))
  proc() =
    discard send(send(`class`("NSProcessInfo"), "processInfo"),
                 "endActivity:", argu(token))
    release(token)

method onBattery*(p: powerImpl): bool =
  if iopsCopyPowerSourcesInfo == nil:
    return false
  let info = iopsCopyPowerSourcesInfo()
  if info.isNil:
    return false
  defer: cfRelease(info)
  goString(iopsGetProvidingPowerSourceType(info)) == "Battery Power"

method idleTime*(p: powerImpl): Duration =
  const combinedSessionState = 0
  const anyInputEvent = not 0'u32
  initDuration(nanoseconds = int64(
    cgEventSourceSecondsSinceLastType(combinedSessionState,
                                      anyInputEvent) * 1e9))
