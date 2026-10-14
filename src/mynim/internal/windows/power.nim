## power.nim (power.go): power and session state.

## Messages about power and the session, which the application window
## gets.
const
  wmPowerBroadcast* = 0x0218'u32
  wmWTSSessionChange* = 0x02B1'u32
  pbtAPMSuspend* = 0x4'u
  pbtAPMResumeAutomatic* = 0x12'u
  wtsSessionLock* = 0x7'u
  wtsSessionUnlock* = 0x8'u

method power*(b: WinBackend): Power = w32Power(b: b)
method secrets*(b: WinBackend): Secrets = w32Secrets()

method watch*(p: w32Power) =
  p.b.watchingPower = true
  const notifyForThisSession = 0
  discard procWTSRegisterSessionNotification(p.b.appHwnd,
    notifyForThisSession)

## powerMessage reports the power and session messages of the
## application window.
proc powerMessage*(b: WinBackend, m: uint32, wp: uint) =
  if not b.watchingPower:
    return
  if m == wmPowerBroadcast and wp == pbtAPMSuspend:
    b.h.powerEvent("suspend")
  elif m == wmPowerBroadcast and wp == pbtAPMResumeAutomatic:
    b.h.powerEvent("resume")
  elif m == wmWTSSessionChange and wp == wtsSessionLock:
    b.h.powerEvent("lock-screen")
  elif m == wmWTSSessionChange and wp == wtsSessionUnlock:
    b.h.powerEvent("unlock-screen")

## reasonContext mirrors REASON_CONTEXT with a simple reason string.
type reasonContext = object
  version*, flags*: uint32
  reason*: ptr uint16
  pad: array[2, uint] ## the rest of the union

method keepAwake*(p: w32Power, display: bool, reason: string): ReleaseProc =
  const
    contextSimpleString = 0x1'u32
    requestDisplay = 0'u ## PowerRequestDisplayRequired
    requestSystem = 1'u  ## PowerRequestSystemRequired
  var ctx = reasonContext(flags: contextSimpleString,
    reason: cast[ptr uint16](u16(reason)))
  let h = procPowerCreateRequest(cast[uint](addr ctx))
  if h == 0 or h == uint.high:
    return nil
  var requests = @[requestSystem]
  if display:
    requests.add requestDisplay
  for r in requests:
    discard procPowerSetRequest(h, r)
  (proc() =
    for r in requests:
      discard procPowerClearRequest(h, r)
    discard procCloseHandle(h))

type systemPowerStatus = object
  acLineStatus*, batteryFlag*, batteryLifePercent*,
    systemStatusFlag*: uint8
  batteryLifeTime*, batteryFullLifeTime*: uint32

method onBattery*(p: w32Power): bool =
  var status: systemPowerStatus
  if procGetSystemPowerStatus(cast[uint](addr status)) == 0:
    return false
  status.acLineStatus == 0

method idleTime*(p: w32Power): Duration =
  var info: array[2, uint32]
  info[0] = 8
  if procGetLastInputInfo(cast[uint](addr info)) == 0:
    return initDuration()
  let now = procGetTickCount()
  initDuration(milliseconds = int64(uint32(now) - info[1]))
