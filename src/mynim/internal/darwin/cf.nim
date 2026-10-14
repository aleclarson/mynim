type
  eventHotKeyID* = object
    signature*: uint32
    id*: uint32
  eventTypeSpec* = object
    `class`*: uint32
    kind*: uint32

## cf.go: CoreFoundation and friends, bound through dlsym like the Go
## original's RegisterLibFunc, since some are optional (IOKit).

var
  cfRunLoopGetMain*: proc(): pointer {.cdecl.}
  cfRunLoopSourceCreate*: proc(alloc: pointer, order: int,
                               ctx: pointer): pointer {.cdecl.}
  cfRunLoopAddSource*: proc(rl, src, mode: pointer) {.cdecl.}
  cfRelease*: proc(obj: pointer) {.cdecl.}
  kCFRunLoopCommonModes*: pointer

  # LaunchServices.
  lsSetDefaultHandlerForURLScheme*: proc(scheme, bundleID: id): int32
    {.cdecl.}
  lsCopyDefaultHandlerForURLScheme*: proc(scheme: id): id {.cdecl.}

  # Power.
  iopsCopyPowerSourcesInfo*: proc(): pointer {.cdecl.}
  iopsGetProvidingPowerSourceType*: proc(snapshot: pointer): id {.cdecl.}
  cgEventSourceSecondsSinceLastType*: proc(state: int32,
      eventType: uint32): float64 {.cdecl.}

  cgDisplayIsBuiltin*: proc(display: uint32): bool {.cdecl.}
  cgDisplayRotation*: proc(display: uint32): float64 {.cdecl.}
  nsBeep*: proc() {.cdecl.}

  # Carbon hot keys.
  getApplicationEventTarget*: proc(): pointer {.cdecl.}
  registerEventHotKey*: proc(keyCode, modifiers: uint32,
                             hotKeyID: eventHotKeyID, target: pointer,
                             options: uint32, outRef: ptr uint): int32
    {.cdecl.}
  unregisterEventHotKey*: proc(`ref`: uint): int32 {.cdecl.}
  installEventHandler*: proc(target, handler: pointer, numTypes: uint32,
                             list: ptr eventTypeSpec, userData: pointer,
                             outRef: ptr uint): int32 {.cdecl.}
  getEventParameter*: proc(event: pointer, name, typ: uint32,
                           outType: pointer, size: uint,
                           outSize: ptr uint, data: pointer): int32 {.cdecl.}

  ## Called by address on every Signal.
  cfRunLoopSourceSignal*: proc(src: pointer) {.cdecl.}
  cfRunLoopWakeUp*: proc(rl: pointer) {.cdecl.}

proc loadCF*() =
  cfRunLoopGetMain = cast[typeof cfRunLoopGetMain](
    mustDlsym(libCFH, "CFRunLoopGetMain"))
  cfRunLoopSourceCreate = cast[typeof cfRunLoopSourceCreate](
    mustDlsym(libCFH, "CFRunLoopSourceCreate"))
  cfRunLoopAddSource = cast[typeof cfRunLoopAddSource](
    mustDlsym(libCFH, "CFRunLoopAddSource"))
  cfRunLoopSourceSignal = cast[typeof cfRunLoopSourceSignal](
    mustDlsym(libCFH, "CFRunLoopSourceSignal"))
  cfRunLoopWakeUp = cast[typeof cfRunLoopWakeUp](
    mustDlsym(libCFH, "CFRunLoopWakeUp"))
  cfRelease = cast[typeof cfRelease](mustDlsym(libCFH, "CFRelease"))
  kCFRunLoopCommonModes = deref[pointer](
    mustDlsym(libCFH, "kCFRunLoopCommonModes"))

  lsSetDefaultHandlerForURLScheme =
    cast[typeof lsSetDefaultHandlerForURLScheme](
      mustDlsym(libCoreServicesH, "LSSetDefaultHandlerForURLScheme"))
  lsCopyDefaultHandlerForURLScheme =
    cast[typeof lsCopyDefaultHandlerForURLScheme](
      mustDlsym(libCoreServicesH, "LSCopyDefaultHandlerForURLScheme"))

  if not libIOKitH.isNil:
    iopsCopyPowerSourcesInfo = cast[typeof iopsCopyPowerSourcesInfo](
      dlsym(libIOKitH, "IOPSCopyPowerSourcesInfo"))
    iopsGetProvidingPowerSourceType =
      cast[typeof iopsGetProvidingPowerSourceType](
        dlsym(libIOKitH, "IOPSGetProvidingPowerSourceType"))

  cgEventSourceSecondsSinceLastType =
    cast[typeof cgEventSourceSecondsSinceLastType](
      mustDlsym(libCGH, "CGEventSourceSecondsSinceLastEventType"))
  cgDisplayIsBuiltin = cast[typeof cgDisplayIsBuiltin](
    mustDlsym(libCGH, "CGDisplayIsBuiltin"))
  cgDisplayRotation = cast[typeof cgDisplayRotation](
    mustDlsym(libCGH, "CGDisplayRotation"))
  nsBeep = cast[typeof nsBeep](mustDlsym(libAppKitH, "NSBeep"))

  getApplicationEventTarget = cast[typeof getApplicationEventTarget](
    mustDlsym(libCarbonH, "GetApplicationEventTarget"))
  registerEventHotKey = cast[typeof registerEventHotKey](
    mustDlsym(libCarbonH, "RegisterEventHotKey"))
  unregisterEventHotKey = cast[typeof unregisterEventHotKey](
    mustDlsym(libCarbonH, "UnregisterEventHotKey"))
  installEventHandler = cast[typeof installEventHandler](
    mustDlsym(libCarbonH, "InstallEventHandler"))
  getEventParameter = cast[typeof getEventParameter](
    mustDlsym(libCarbonH, "GetEventParameter"))
