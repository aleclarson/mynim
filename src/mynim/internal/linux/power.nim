## power.nim: power and session events come from logind on the system
## bus, and from the screen savers of GNOME and of the freedesktop
## specification (KDE and others) on the session bus.

## watch listens to logind for sleep, on the system bus, and to the
## screen savers, which lock the screen, on the session bus.
method watch*(p: powerImpl) =
  var gerr: pointer
  let system = gBusGetSync(1, nil, addr gerr) # G_BUS_TYPE_SYSTEM
  if not system.isNil:
    discard gDBusConnectionSignalSubscribe(system, cs("org.freedesktop.login1"),
      cs("org.freedesktop.login1.Manager"), cs("PrepareForSleep"),
      cs("/org/freedesktop/login1"), nil, 0, cbPowerSignal, nil, nil)
  else:
    discard gErr(gerr)
  let (session, err) = bus()
  if err.isNil:
    for iface in ["org.gnome.ScreenSaver", "org.freedesktop.ScreenSaver"]:
      discard gDBusConnectionSignalSubscribe(session, nil, cs(iface),
        cs("ActiveChanged"), nil, nil, 0, cbPowerSignal, nil, nil)

## keepAwake asks the XDG desktop portal to inhibit suspending (and, with
## display, the session going idle), else the freedesktop screen saver to
## inhibit idleness.
method keepAwake*(p: powerImpl, display: bool,
    reason: string): ReleaseProc =
  const inhibitSuspend = 4'u32
  const inhibitIdle = 8'u32
  var flags = inhibitSuspend
  if display: flags = flags or inhibitIdle
  let params = `tuple`(@[
    gVariantNewString(cs("")),
    gVariantNewUint32(flags),
    vardict(@[vardictEntry("reason", gVariantNewString(cs(reason)))])])
  let (res, err) = portalCall(portalPath, "org.freedesktop.portal.Inhibit",
    "Inhibit", params, "(o)")
  if err.isNil:
    let child = gVariantGetChildValue(res, 0)
    let handle = goStr(gVariantGetString(child, nil))
    gVariantUnref(child)
    gVariantUnref(res)
    return proc() =
      let (r, e) = portalCall(handle, "org.freedesktop.portal.Request",
        "Close", nil, "")
      if e.isNil: gVariantUnref(r)
  let (res2, err2) = dbusCall("org.freedesktop.ScreenSaver",
    "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver",
    "Inhibit", `tuple`(@[gVariantNewString(cs(appName())),
                         gVariantNewString(cs(reason))]), "(u)")
  if not err2.isNil: return nil
  let child = gVariantGetChildValue(res2, 0)
  let cookie = gVariantGetUint32(child)
  gVariantUnref(child)
  gVariantUnref(res2)
  proc() =
    let (r, e) = dbusCall("org.freedesktop.ScreenSaver",
      "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver",
      "UnInhibit", `tuple`(@[gVariantNewUint32(cookie)]), "")
    if e.isNil: gVariantUnref(r)

## onBattery reports whether a battery discharges while no power supply
## is online, from /sys/class/power_supply.
method onBattery*(p: powerImpl): bool =
  proc read(dir, name: string): string =
    try: readFile(dir / name).strip()
    except IOError: ""
  var discharging = false
  for s in walkPattern("/sys/class/power_supply/*"):
    case read(s, "type")
    of "Mains", "USB":
      if read(s, "online") == "1":
        return false
    of "Battery":
      if read(s, "scope") != "Device" and read(s, "status") == "Discharging":
        discharging = true
    else: discard
  discharging

## idleTime asks GNOME's idle monitor, else the freedesktop screen saver
## (KDE).
method idleTime*(p: powerImpl): Duration =
  let (res, err) = dbusCall("org.gnome.Mutter.IdleMonitor",
    "/org/gnome/Mutter/IdleMonitor/Core", "org.gnome.Mutter.IdleMonitor",
    "GetIdletime", nil, "(t)")
  if err.isNil:
    let child = gVariantGetChildValue(res, 0)
    let ms = gVariantGetUint64(child)
    gVariantUnref(child)
    gVariantUnref(res)
    return initDuration(milliseconds = int64(ms))
  let (res2, err2) = dbusCall("org.freedesktop.ScreenSaver",
    "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver",
    "GetSessionIdleTime", nil, "(u)")
  if err2.isNil:
    let child = gVariantGetChildValue(res2, 0)
    let s = gVariantGetUint32(child)
    gVariantUnref(child)
    gVariantUnref(res2)
    return initDuration(seconds = int64(s))
  initDuration()
