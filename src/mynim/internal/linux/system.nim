## system.nim: the clipboard, shell, screen and theme controllers, the
## D-Bus helpers, notifications, the launcher entry and the callbacks of
## the desktop's signals.

var
  cbThemeChanged*, cbMonitorsChanged*, cbNotification*, cbPowerSignal*,
    cbNetworkChanged*: pointer
  cbDecorationLayout*: pointer ## window.nim

# Forward declarations of names defined in files included after this
# one, which the callbacks and methods above reach into.
var
  notifications*: Table[uint32, string]
  notifyDBusIDs*: Table[string, uint32]
  notifySubscribed*: bool

proc clip*(): pointer
proc showNotificationImpl*(b: Backend, n: Notification): ref CatchableError

proc cbThemeChangedFn(a, b, data: pointer) {.cdecl.} =
  theBackend.h.themeChanged()
proc cbMonitorsChangedFn(display, monitor, data: pointer) {.cdecl.} =
  theBackend.h.displaysChanged()
proc cbPowerSignalFn(conn, sender, path, iface, signal, params,
    data: pointer) {.cdecl.} =
  let child = gVariantGetChildValue(params, 0)
  let on = gVariantGetBoolean(child)
  gVariantUnref(child)
  var event = if on: "lock-screen" else: "unlock-screen"
  if goStr(signal) == "PrepareForSleep":
    event = if on: "suspend" else: "resume"
  theBackend.h.powerEvent(event)
proc cbNotificationFn(conn, sender, path, iface, signal, params,
    data: pointer) {.cdecl.} =
  if goStr(signal) != "ActionInvoked": return
  let child = gVariantGetChildValue(params, 0)
  let dbusID = gVariantGetUint32(child)
  gVariantUnref(child)
  if notifications.hasKey(dbusID):
    theBackend.h.notificationClicked(notifications[dbusID])
proc cbNetworkChangedFn(monitor, available, data: pointer) {.cdecl.} =
  theBackend.h.networkChanged(networkImpl(b: theBackend).status())

proc initSystemCallbacks*() =
  cbThemeChanged = cast[pointer](cbThemeChangedFn)
  cbMonitorsChanged = cast[pointer](cbMonitorsChangedFn)
  cbPortalSignal = cast[pointer](portalSignal)
  cbPowerSignal = cast[pointer](cbPowerSignalFn)
  cbNotification = cast[pointer](cbNotificationFn)
  cbNetworkChanged = cast[pointer](cbNetworkChangedFn)

  let settings = gtkSettingsGetDefault()
  discard connect(settings, "notify::gtk-theme-name", cbThemeChanged, nil)
  discard connect(settings, "notify::gtk-font-name", cbThemeChanged, nil)
  discard connect(settings, "notify::gtk-decoration-layout", cbDecorationLayout, nil)
  discard connect(settings, "notify::gtk-application-prefer-dark-theme", cbThemeChanged, nil)
  discard connect(settings, "notify::gtk-enable-animations", cbThemeChanged, nil)
  watchPortalSettings()
  let d = gdkDisplayGetDefault()
  if not d.isNil:
    discard connect(d, "monitor-added", cbMonitorsChanged, nil)
    discard connect(d, "monitor-removed", cbMonitorsChanged, nil)

# --- Clipboard. (clip() and the selection sources are clipboard.nim.)

method readText*(c: clipboardImpl): string =
  takeStr(gtkClipboardWaitForText(clip()))

method writeText*(c: clipboardImpl, text: string) =
  c.writeData(textData(text), nil)

method readHTML*(c: clipboardImpl): string =
  let sd = gtkClipboardWaitForContents(clip(), gdkAtomIntern(cs("text/html"), false))
  if sd.isNil: return ""
  defer: gtkSelectionDataFree(sd)
  let n = gtkSelectionDataGetLength(sd)
  let data = gtkSelectionDataGetData(sd)
  if n <= 0 or data.isNil: return ""
  let bytes = cast[ptr UncheckedArray[char]](cast[ptr pointer](addr data)[])
  $toOpenArray(bytes, 0, int(n) - 1)

method writeHTML*(c: clipboardImpl, markup: string) =
  c.writeData(transfer.newData(newItem(
    bytes(HTML, markup), bytes(Text, markup))), nil)

method readImage*(c: clipboardImpl): seq[byte] =
  let pix = gtkClipboardWaitForImage(clip())
  if pix.isNil: return @[]
  defer: gObjectUnref(pix)
  pngFromPixbuf(pix)

method writeImage*(c: clipboardImpl, png: seq[byte]) =
  let (pix, err) = pixbufFromPNG(png)
  if not err.isNil:
    raise err
  defer: gObjectUnref(pix)
  c.writeData(transfer.newData(newItem(bytes(PNG, png))), nil)

method clear*(c: clipboardImpl) = gtkClipboardClear(clip())

method availableFormats*(c: clipboardImpl): seq[string] =
  var atoms: pointer
  var n: int32
  if not gtkClipboardWaitForTargets(clip(), addr atoms, addr n) or atoms.isNil:
    return @[]
  defer: gFree(atoms)
  for i in 0 ..< int(n):
    result.add takeStr(gdkAtomName(field[pointer](atoms, uint(i) * 8)))

# --- Shell. ---

method openExternal*(s: shellImpl, url: string): ref CatchableError =
  launch(url)

method openPath*(s: shellImpl, path: string) =
  let err = launch(fileURI(path))
  if not err.isNil: raise err

method showItemInFolder*(s: shellImpl, path: string) =
  let uri = fileURI(path)
  var arr = @[gVariantNewString(cs(uri))]
  let uris = gVariantNewArray(gVariantTypeNew(cs("s")),
    unsafeAddr arr[0], 1)
  let params = `tuple`(@[uris, gVariantNewString(cs(""))])
  let (res, err) = dbusCall("org.freedesktop.FileManager1",
    "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1",
    "ShowItems", params, "")
  if err.isNil:
    gVariantUnref(res)
  else:
    s.openPath(parentDir(path))

method trashItem*(s: shellImpl, path: string) =
  let f = gFileNewForPath(cs(path))
  defer: gObjectUnref(f)
  var gerr: pointer
  if not gFileTrash(f, nil, addr gerr):
    raise gErr(gerr)

method beep*(s: shellImpl) = gdkDisplayBeep(gdkDisplayGetDefault())

# --- Screen. ---

method displays*(s: screenImpl): seq[platform.Display] =
  let d = gdkDisplayGetDefault()
  if d.isNil: return @[]
  let primary = gdkDisplayGetPrimaryMonitor(d)
  let n = int(gdkDisplayGetNMonitors(d))
  for i in 0 ..< n:
    let m = gdkDisplayGetMonitor(d, int32(i))
    var geo, work: gdkRectangle
    gdkMonitorGetGeometry(m, addr geo)
    gdkMonitorGetWorkarea(m, addr work)
    result.add platform.Display(
      id: int64(i),
      label: goStr(gdkMonitorGetModel(m)),
      bounds: platform.Rect(x: int(geo.x), y: int(geo.y),
        width: int(geo.width), height: int(geo.height)),
      workArea: platform.Rect(x: int(work.x), y: int(work.y),
        width: int(work.width), height: int(work.height)),
      scaleFactor: float64(gdkMonitorGetScaleFactor(m)),
      primary: m == primary or (primary.isNil and i == 0))
  # Primary first, like on other platforms.
  for i, disp in result:
    if disp.primary and i > 0:
      swap(result[0], result[i])
      break

method cursorPoint*(s: screenImpl): platform.Point =
  let d = gdkDisplayGetDefault()
  if d.isNil: return platform.Point()
  var x, y: int32
  gdkDeviceGetPosition(gdkSeatGetPointer(gdkDisplayGetDefaultSeat(d)),
    nil, addr x, addr y)
  platform.Point(x: int(x), y: int(y))

# --- Theme. ---

## fontRendering returns GTK's gtk-xft settings, which the desktop's
## settings daemon gives (XSETTINGS) or GDK's defaults, as GTK makes them
## the screen's font options: no hinting where hinting is off, and
## subpixel antialiasing where the screen's subpixels have an order.
method fontRendering*(t: themeImpl): platform.FontRendering =
  let settings = gtkSettingsGetDefault()
  if settings.isNil: return platform.FontRendering()
  var antialias, hinting: int32
  var style, rgba: pointer
  gObjectGetPtr(settings, cs("gtk-xft-antialias"), addr antialias, nil)
  gObjectGetPtr(settings, cs("gtk-xft-hinting"), addr hinting, nil)
  gObjectGetPtr(settings, cs("gtk-xft-hintstyle"), addr style, nil)
  gObjectGetPtr(settings, cs("gtk-xft-rgba"), addr rgba, nil)
  var r: platform.FontRendering
  let hintStyle = takeStr(style)
  if hinting == 0:
    r.hinting = "none"
  elif hinting == 1 and hintStyle.startsWith("hint"):
    let h = hintStyle["hint".len .. ^1]
    if h in ["none", "slight", "medium", "full"]:
      r.hinting = h
  let order = takeStr(rgba)
  if order in ["rgb", "bgr", "vrgb", "vbgr"]:
    r.subpixels = order
  if antialias == 0:
    r.antialias = "none"
  elif antialias == 1 and r.subpixels != "":
    r.antialias = "subpixel"
  elif antialias == 1:
    r.antialias = "gray"
  r

## uiFont returns the family of the font GTK apps show their interface
## in, gtk-font-name, such as "Cantarell 11" on GNOME, which the desktop's
## settings daemon or settings.ini gives; fontconfig knows only a default
## sans-serif.
method uiFont*(t: themeImpl): string =
  var name: pointer
  gObjectGetPtr(gtkSettingsGetDefault(), cs("gtk-font-name"), addr name, nil)
  let spec = takeStr(name)
  if spec == "": return ""
  var
    fromString: proc(s: cstring): pointer {.cdecl.}
    getFamily: proc(d: pointer): pointer {.cdecl.}
    freeDesc: proc(d: pointer) {.cdecl.}
  let (pango, err) = openLib("libpango-1.0.so.0")
  if not err.isNil or
      not bindFunc(pango, cast[ptr pointer](addr fromString), "pango_font_description_from_string") or
      not bindFunc(pango, cast[ptr pointer](addr getFamily), "pango_font_description_get_family") or
      not bindFunc(pango, cast[ptr pointer](addr freeDesc), "pango_font_description_free"):
    return ""
  let desc = fromString(cs(spec))
  defer: freeDesc(desc)
  goStr(getFamily(desc))

## portalColorScheme reads the desktop wide preference (1 = dark, 2 =
## light, 0 = no preference) from the settings portal.
proc portalColorScheme*(): tuple[scheme: uint32, ok: bool] =
  let params = `tuple`(@[
    gVariantNewString(cs("org.freedesktop.appearance")),
    gVariantNewString(cs("color-scheme"))])
  let (res, err) = portalCall(portalPath,
    "org.freedesktop.portal.Settings", "Read", params, "(v)")
  if not err.isNil: return (0'u32, false)
  defer: gVariantUnref(res)
  let v = gVariantGetChildValue(res, 0) # v
  var inner = gVariantGetVariant(v)     # v (the portal wraps twice)
  gVariantUnref(v)
  defer: gVariantUnref(inner)
  while goStr(gVariantGetTypeString(inner)).startsWith("v"):
    let next = gVariantGetVariant(inner)
    gVariantUnref(inner)
    inner = next
  if goStr(gVariantGetTypeString(inner)) != "u": return (0'u32, false)
  (gVariantGetUint32(inner), true)

## preferences reads GTK's animations setting, and the accent, contrast
## and text size the desktop portal gives, as GNOME's and KDE's do.
method preferences*(t: themeImpl): platform.Preferences =
  var p: platform.Preferences
  let settings = gtkSettingsGetDefault()
  var animations: int32 = 1
  gObjectGetPtr(settings, cs("gtk-enable-animations"), addr animations, nil)
  p.reduceMotion = animations == 0
  var name: pointer
  gObjectGetPtr(settings, cs("gtk-theme-name"), addr name, nil)
  p.highContrast = takeStr(name).toLower.contains("highcontrast")
  let (all, ok) = portalSettings(appearanceSettings, gnomeInterfaceSettings)
  if not ok: return p
  defer: gVariantUnref(all)
  # The accent: red, green and blue between 0 and 1, others for none.
  let v = portalSetting(all, appearanceSettings, "accent-color", "(ddd)")
  if not v.isNil:
    var rgb: array[3, float64]
    var inRange = true
    for i in 0 .. 2:
      let c = gVariantGetChildValue(v, uint(i))
      rgb[i] = gVariantGetDouble(c)
      gVariantUnref(c)
      inRange = inRange and rgb[i] >= 0 and rgb[i] <= 1
    gVariantUnref(v)
    if inRange:
      p.accent = platform.Color(
        r: uint8(rgb[0] * 255 + 0.5), g: uint8(rgb[1] * 255 + 0.5),
        b: uint8(rgb[2] * 255 + 0.5), a: 255)
  let cv = portalSetting(all, appearanceSettings, "contrast", "u")
  if not cv.isNil:
    p.highContrast = p.highContrast or gVariantGetUint32(cv) == 1
    gVariantUnref(cv)
  let tv = portalSetting(all, gnomeInterfaceSettings, "text-scaling-factor", "d")
  if not tv.isNil:
    let s = gVariantGetDouble(tv)
    if s >= 0.5 and s <= 5: p.textScale = s
    gVariantUnref(tv)
  p

method isDark*(t: themeImpl): bool =
  let settings = gtkSettingsGetDefault()
  var prefer: int32
  gObjectGetPtr(settings, cs("gtk-application-prefer-dark-theme"),
    addr prefer, nil)
  if prefer != 0: return true
  let (scheme, ok) = portalColorScheme()
  if ok and scheme != 0: return scheme == 1
  var name: pointer
  gObjectGetPtr(settings, cs("gtk-theme-name"), addr name, nil)
  takeStr(name).toLower.contains("dark")

method setSource*(t: themeImpl, source: string) =
  var dark = source == "dark"
  if source == "system":
    let (scheme, _) = portalColorScheme()
    dark = scheme == 1
  gObjectSetBool(gtkSettingsGetDefault(),
    cs("gtk-application-prefer-dark-theme"), dark, nil)

# --- The launcher entry (Unity API). ---

## updateLauncherEntry shows the progress and badge count on the app's
## launcher entry with the Unity launcher API, which the docks of KDE
## Plasma and Ubuntu, Dash to Dock and Plank implement. They find the app
## by its desktop entry.
proc updateLauncherEntry*(b: Backend) =
  let (conn, err) = bus()
  if not err.isNil: return
  let l = addr b.launcher
  var count = 0
  try: count = parseInt(l.badge)
  except ValueError: discard
  proc entry(key: string, v: pointer): pointer =
    gVariantNewDictEntry(gVariantNewString(cs(key)), gVariantNewVariant(v))
  let props = @[
    entry("progress", gVariantNewDouble(l.progress)),
    entry("progress-visible", gVariantNewBoolean(l.showing)),
    entry("count", gVariantNewInt64(int64(count))),
    entry("count-visible", gVariantNewBoolean(count > 0))]
  let id = desktopEntryID()
  let params = `tuple`(@[
    gVariantNewString(cs("application://" & id)),
    gVariantNewArray(nil, unsafeAddr props[0], uint(props.len))])
  # fnv-1a 32 of the desktop entry ID names the object path.
  var h: uint32 = 2166136261'u32
  for c in id:
    h = (h xor uint32(uint8(c))) * 16777619'u32
  let path = "/com/canonical/unity/launcherentry/" & $h
  var gerr: pointer
  if not gDBusConnectionEmitSignal(conn, nil, cs(path),
      cs("com.canonical.Unity.LauncherEntry"), cs("Update"), params,
      addr gerr):
    discard gErr(gerr)

## desktopEntryID is the file name of the app's desktop entry: the one it
## was launched from, else the one `mynim build` writes, named after the
## executable.
proc desktopEntryID*(): string =
  for env in ["GIO_LAUNCHED_DESKTOP_FILE", "BAMF_DESKTOP_FILE_HINT"]:
    let p = getEnv(env)
    if p != "": return extractFilename(p)
  extractFilename(getAppFilename()) & ".desktop"

# --- Notifications (org.freedesktop.Notifications). ---

method notificationsSupported*(b: Backend): bool =
  let (_, err) = bus()
  err.isNil

## webViewSupported reports whether a window showing a web page can have
## one: WebKitGTK, JavaScriptCore and libsoup, which it needs. Windows
## showing native UI need GTK alone, so an app whose windows all do runs
## without them. Loading the libraries is as much as can be known before a
## page loads.
method webViewSupported*(b: Backend): bool = webKit().isNil

method showNotification*(b: Backend, n: Notification,
    done: proc(err: ref CatchableError)) =
  done(b.showNotificationImpl(n))

proc showNotificationImpl*(b: Backend, n: Notification):
    ref CatchableError =
  let (conn, err) = bus()
  if not err.isNil:
    return newException(CatchableError,
      "mynim: notifications need a D-Bus session: " & err.msg)
  if not notifySubscribed:
    notifySubscribed = true
    discard gDBusConnectionSignalSubscribe(conn,
      cs("org.freedesktop.Notifications"), cs("org.freedesktop.Notifications"),
      cs("ActionInvoked"), cs("/org/freedesktop/Notifications"), nil, 0,
      cbNotification, nil, nil)
  let actions = @[gVariantNewString(cs("default")),
                  gVariantNewString(cs("Open"))]
  var hints: seq[pointer]
  if n.silent:
    hints.add gVariantNewDictEntry(gVariantNewString(cs("suppress-sound")),
      gVariantNewVariant(gVariantNewBoolean(true)))
  var hintArray = gVariantNewArray(gVariantTypeNew(cs("{sv}")), nil, 0)
  if hints.len > 0:
    hintArray = gVariantNewArray(nil, unsafeAddr hints[0], uint(hints.len))
  var body = n.body
  if n.subtitle != "": body = n.subtitle & "\n" & body
  let params = `tuple`(@[
    gVariantNewString(cs(appName())),
    gVariantNewUint32(notifyDBusIDs.getOrDefault(n.id)),
    gVariantNewString(cs("")),
    gVariantNewString(cs(n.title)),
    gVariantNewString(cs(body)),
    gVariantNewArray(nil, unsafeAddr actions[0], uint(actions.len)),
    hintArray,
    gVariantNewInt32(-1)])
  var res: pointer
  var err3: ref CatchableError
  (res, err3) = dbusCall("org.freedesktop.Notifications",
    "/org/freedesktop/Notifications", "org.freedesktop.Notifications",
    "Notify", params, "(u)")
  if not err3.isNil: return err3
  let child = gVariantGetChildValue(res, 0)
  let dbusID = gVariantGetUint32(child)
  gVariantUnref(child)
  gVariantUnref(res)
  notifications[dbusID] = n.id
  notifyDBusIDs[n.id] = dbusID
  nil

method removeNotification*(b: Backend, id: string) =
  if not notifyDBusIDs.hasKey(id): return
  let dbusID = notifyDBusIDs[id]
  notifyDBusIDs.del(id)
  notifications.del(dbusID)
  let (res, err) = dbusCall("org.freedesktop.Notifications",
    "/org/freedesktop/Notifications", "org.freedesktop.Notifications",
    "CloseNotification", `tuple`(@[gVariantNewUint32(dbusID)]), "")
  if err.isNil: gVariantUnref(res)

method removeAllNotifications*(b: Backend) =
  for id in toSeq(notifyDBusIDs.keys):
    b.removeNotification(id)
