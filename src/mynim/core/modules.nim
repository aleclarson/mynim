## modules.go + network.go — the singleton modules that integrate with
## the desktop: shell, clipboard, screen, theme, global shortcuts,
## trays, notifications, network.

## --- Shell ---

proc openExternal*(s: ShellModule; url: string): ref CatchableError =
  ## Opens a URL with the default application, e.g. a web page in the
  ## default browser.
  needsApp("shell.openExternal")
  onMainValue(proc(): ref CatchableError =
    backend().shell().openExternal(url))

proc openPath*(s: ShellModule; path: string) =
  ## Opens a file or directory with the default application.
  needsApp("shell.openPath")
  onMain(proc() = backend().shell().openPath(path))

proc showItemInFolder*(s: ShellModule; path: string) =
  ## Reveals a file in the file manager.
  needsApp("shell.showItemInFolder")
  onMain(proc() = backend().shell().showItemInFolder(path))

proc trashItem*(s: ShellModule; path: string) =
  ## Moves a file or directory to the trash.
  needsApp("shell.trashItem")
  onMain(proc() = backend().shell().trashItem(path))

proc fileIcon*(s: ShellModule; path: string; size: int): seq[byte] =
  ## The icon the file manager shows for a file, a folder or an
  ## application, as a PNG image of size by size pixels: pass the size
  ## in DIPs times the display's scale factor for a sharp icon. On
  ## Windows path may also name a shell item, such as an app of the
  ## Start menu by its shell:AppsFolder\<AppUserModelID> path; on
  ## Linux, the icon of a desktop entry (.desktop) is its
  ## application's, from the icon theme.
  needsApp("shell.fileIcon")
  if size <= 0:
    raise newException(ValueError,
      "mynim: shell.fileIcon: size must be positive")
  onMainValue(proc(): seq[byte] =
    let (png, err) = backend().shell().fileIcon(path, size)
    if err != nil: raise err
    png)

proc installedApps*(s: ShellModule): seq[InstalledApp] =
  ## Lists the applications installed on the computer, sorted by name,
  ## as a launcher shows them. It reads the disk: call it from a thread
  ## of its own, which it does not block the main thread from.
  needsApp("shell.installedApps")
  if not isMainThread():
    app.waitReady()
  let (found, err) = backend().applications()
  if err != nil:
    raise err
  result = newSeq[InstalledApp](found.len)
  for i, a in found:
    result[i] = InstalledApp(name: a.name, id: a.id, path: a.path)
  result.sort(proc(a, b: InstalledApp): int =
    let c = cmp(a.name.toLowerAscii(), b.name.toLowerAscii())
    if c != 0: c else: cmp(a.path, b.path))

proc launchApp*(s: ShellModule; a: InstalledApp) =
  ## Starts an application of installedApps, or brings it to the front
  ## if it runs.
  needsApp("shell.launchApp")
  if a.path == "":
    raise newException(ValueError,
      "mynim: shell.launchApp: the app has no path")
  onMain(proc() = backend().shell().openApplication(a.path))

proc beep*(s: ShellModule) =
  ## Plays the system alert sound.
  needsApp("shell.beep")
  onMain(proc() = backend().shell().beep())

## --- Clipboard ---

proc readText*(c: ClipboardModule): string =
  ## The plain text on the clipboard.
  needsApp("clipboard.readText")
  clipboardNativeValue(proc(): string = backend().clipboard().readText())

proc writeText*(c: ClipboardModule; text: string) =
  ## Puts plain text on the clipboard.
  needsApp("clipboard.writeText")
  discard c.write(textData(text), [])

proc readHTML*(c: ClipboardModule): string =
  ## The HTML on the clipboard.
  needsApp("clipboard.readHTML")
  clipboardNativeValue(proc(): string = backend().clipboard().readHTML())

proc writeHTML*(c: ClipboardModule; markup: string) =
  ## Puts HTML on the clipboard.
  needsApp("clipboard.writeHTML")
  discard c.write(newData(newItem(
    bytes(transfer.HTML, markup),
    bytes(transfer.Text, markup))), [])

proc readImage*(c: ClipboardModule): seq[byte] =
  ## The image on the clipboard as PNG, or empty.
  needsApp("clipboard.readImage")
  clipboardNativeValue(proc(): seq[byte] = backend().clipboard().readImage())

proc writeImage*(c: ClipboardModule; data: seq[byte]) =
  ## Puts a PNG image on the clipboard.
  needsApp("clipboard.writeImage")
  if not looksLikePng(data):
    raise newException(ValueError, "mynim: clipboard.writeImage: not a PNG")
  discard c.write(newData(newItem(bytes(transfer.PNG, data))), [])

proc clear*(c: ClipboardModule) =
  ## Empties the clipboard.
  needsApp("clipboard.clear")
  onMain(proc() =
    if not clipboardProviding and not clipboardStopped:
      withClipboardOperation(proc() = backend().clipboard().clear()))

proc availableFormats*(c: ClipboardModule): seq[string] =
  ## The formats (MIME types or platform types) on the clipboard.
  needsApp("clipboard.availableFormats")
  clipboardNativeValue(proc(): seq[string] =
    backend().clipboard().availableFormats())

## --- Screen ---


proc displays*(s: ScreenModule): seq[Display] =
  ## All displays; the primary one comes first.
  needsApp("screen.displays")
  onMainValue(proc(): seq[Display] =
    for d in backend().screen().displays():
      result.add Display(id: d.id, label: d.label,
        bounds: Rectangle(x: d.bounds.x, y: d.bounds.y,
                          width: d.bounds.width, height: d.bounds.height),
        workArea: Rectangle(x: d.workArea.x, y: d.workArea.y,
                            width: d.workArea.width,
                            height: d.workArea.height),
        scaleFactor: d.scaleFactor, rotation: d.rotation,
        internal: d.`internal`, primary: d.primary))

proc primaryDisplay*(s: ScreenModule): Display =
  ## The display with the menu bar or taskbar.
  needsApp("screen.primaryDisplay")
  let ds = s.displays()
  for d in ds:
    if d.primary:
      return d
  if ds.len > 0:
    return ds[0]
  Display()

proc cursorScreenPoint*(s: ScreenModule): Point =
  ## The mouse position in screen coordinates.
  needsApp("screen.cursorScreenPoint")
  onMainValue(proc(): Point =
    let p = backend().screen().cursorPoint()
    Point(x: p.x, y: p.y))

proc displayNearestPoint*(s: ScreenModule; p: Point): Display =
  ## The display closest to p.
  needsApp("screen.displayNearestPoint")
  var bestDist = Inf
  for d in s.displays():
    let b = d.bounds
    let dx = max(max(float(b.x - p.x), 0.0), float(p.x - (b.x + b.width)))
    let dy = max(max(float(b.y - p.y), 0.0), float(p.y - (b.y + b.height)))
    let dist = dx * dx + dy * dy
    if dist < bestDist:
      result = d
      bestDist = dist

proc displayMatching*(s: ScreenModule; r: Rectangle): Display =
  ## The display that overlaps r the most.
  needsApp("screen.displayMatching")
  var bestArea = -1
  for d in s.displays():
    let b = d.bounds
    let w = min(b.x + b.width, r.x + r.width) - max(b.x, r.x)
    let h = min(b.y + b.height, r.y + r.height) - max(b.y, r.y)
    let area = max(w, 0) * max(h, 0)
    if area > bestArea:
      result = d
      bestArea = area

proc onDisplaysChanged*(s: ScreenModule; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when displays are added, removed or change resolution.
  s.onChanged.add(fn, false)

proc changed(s: ScreenModule) = fire(s.onChanged)

## --- Theme ---

## Theme sources.
const
  themeSystem* = ThemeSource"system"
  themeLight* = ThemeSource"light"
  themeDark* = ThemeSource"dark"

## theme is the system appearance. Pages follow it through the
## prefers-color-scheme media query, and the accent color and
## accessibility settings through the --mygo-accent and
## --mygo-text-scale CSS variables and the mygo:preferences event.

proc isDark*(t: ThemeModule): bool =
  ## Whether the app currently uses a dark appearance.
  needsApp("theme.isDark")
  onMainValue(proc(): bool = backend().theme().isDark())

proc themePreferences(p: platform.Preferences): ThemePreferences =
  ## The public view of a backend's preferences. Policy lives here, not
  ## in the backends.
  result = ThemePreferences(
    accent: Color(r: p.accent.r, g: p.accent.g, b: p.accent.b,
                  a: p.accent.a),
    reduceMotion: p.reduceMotion,
    highContrast: p.highContrast,
    textScale: p.textScale)
  if result.textScale <= 0:
    result.textScale = 1 # the usual size, as package ui normalizes it

proc prefsRead(t: ThemeModule): ThemePreferences =
  ## The desktop's preferences, read once per change. The read can call
  ## out to the desktop (the settings portal on Linux), so it is kept
  ## until the next change, as package ui keeps it. Main thread only.
  if not t.prefsOK:
    t.prefs = themePreferences(backend().theme().preferences())
    t.prefsOK = true
  t.prefs

proc preferences*(t: ThemeModule): ThemePreferences =
  ## The accent color and the accessibility settings of the desktop. It
  ## is safe from any thread.
  needsApp("theme.preferences")
  var prefs = onMainValue(proc(): ThemePreferences = t.prefsRead())
  # A call made before app.run from another thread is dropped by
  # onMain and answers the zero value; 0 is not a text scale.
  if prefs.textScale <= 0:
    prefs.textScale = 1
  prefs

proc accentColor*(t: ThemeModule): Color = t.preferences().accent
  ## The color of the desktop's controls, or a Color with a 0 where the
  ## desktop has none. It is safe from any thread.

proc reduceMotion*(t: ThemeModule): bool = t.preferences().reduceMotion
  ## Whether the desktop asks for less animation. Safe from any thread.

proc highContrast*(t: ThemeModule): bool = t.preferences().highContrast
  ## Whether the desktop uses a contrast theme. Safe from any thread.

proc textScale*(t: ThemeModule): float64 = t.preferences().textScale
  ## The factor the desktop asks text to grow by; 1 is the usual size,
  ## and the value macOS reports, which has no text scale. Safe from
  ## any thread.

proc source*(t: ThemeModule): ThemeSource =
  ## The appearance override.
  t.mu.acquire()
  defer: t.mu.release()
  if string(t.source) == "":
    return themeSystem
  t.source

proc apply(t: ThemeModule) =
  ## Gives the backend the source set last, if any: calls made on
  ## several threads may reach the main thread in another order. Main
  ## thread only.
  t.mu.acquire()
  let s = t.source
  t.mu.release()
  if string(s) != "":
    backend().theme().setSource(string(s))

proc setSource*(t: ThemeModule; s: ThemeSource) =
  ## Forces a light or dark appearance, or follows the system. It may
  ## be called before app.run, e.g. with a saved preference, to start
  ## the app in that appearance.
  var s = s
  if string(s) == "":
    s = themeSystem
  t.mu.acquire()
  t.source = s
  t.mu.release()
  onMain(proc() =
    if not app.initialized:
      return # run applies it
    t.apply()
    # Not every backend reports its own change.
    updateBackgrounds()
    contentThemeChanged())

proc onUpdated*(t: ThemeModule; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the effective appearance, or the desktop's preferences
  ## (preferences), change.
  t.onUpdated.add(fn, false)

proc changed(t: ThemeModule) =
  ## Forgets the preferences read before and tells the listeners that
  ## the system appearance changed. Main thread only.
  t.prefs = ThemePreferences()
  t.prefsOK = false
  fire(t.onUpdated)

## --- GlobalShortcut ---


proc register*(g: GlobalShortcutModule; acc: string; fn: proc() {.closure.}) =
  ## Calls fn on the main thread whenever accelerator (e.g.
  ## "CmdOrCtrl+Shift+Space") is pressed, even when the app is not
  ## focused.
  ##
  ## On Wayland the desktop binds the shortcut, through the XDG desktop
  ## portal, shortly after register returns: it may ask the user to
  ## confirm it, lets them pick other keys, and needs the app installed
  ## with its desktop entry. The window fn shows or focuses first gets
  ## the activation token of the key press, which lets it take the
  ## focus.
  needsApp("globalShortcut.register")
  let a = accelerator.parse(acc, hostOS)
  let key = $a
  g.mu.acquire()
  if g.byKey.hasKey(key):
    g.mu.release()
    raise newException(ValueError,
      "mynim: shortcut " & key & " is already registered")
  inc g.next
  let id = g.next
  g.mu.release()
  onMain(proc() =
    try:
      backend().registerHotkey(id, acc)
    except CatchableError as e:
      raise e)
  g.mu.acquire()
  g.byKey[key] = id
  g.byID[id] = fn
  g.keyByID[id] = key
  g.mu.release()

proc isRegistered*(g: GlobalShortcutModule; acc: string): bool =
  ## Whether accelerator is registered by this app.
  let a = try: accelerator.parse(acc, hostOS)
          except AcceleratorError: return false
  g.mu.acquire()
  result = g.byKey.hasKey($a)
  g.mu.release()

proc unregister*(g: GlobalShortcutModule; acc: string) =
  ## Removes a shortcut.
  let a = try: accelerator.parse(acc, hostOS)
          except AcceleratorError: return
  g.mu.acquire()
  var id = 0
  var ok = false
  if g.byKey.hasKey($a):
    id = g.byKey[$a]
    ok = true
    g.byKey.del($a)
    g.byID.del(id)
    g.keyByID.del(id)
  g.mu.release()
  if ok:
    onMain(proc() = backend().unregisterHotkey(id))

proc unregisterAll*(g: GlobalShortcutModule) =
  ## Removes all shortcuts registered by this app.
  g.mu.acquire()
  var ids: seq[int]
  for id in g.byID.keys: ids.add id
  g.byKey.clear()
  g.byID.clear()
  g.keyByID.clear()
  g.mu.release()
  onMain(proc() =
    for id in ids:
      backend().unregisterHotkey(id))

proc pressed(g: GlobalShortcutModule; id: int) =
  g.mu.acquire()
  let fn = g.byID.getOrDefault(id)
  g.mu.release()
  if fn != nil:
    fn()

## --- Tray ---

type TrayHandlerImpl = ref object of platform.TrayHandler
  t: Tray

method clicked(h: TrayHandlerImpl) = fire(h.t.onClick)
method rightClicked(h: TrayHandlerImpl) = fire(h.t.onRight)

proc newTray*(opts: TrayOptions): tuple[t: Tray, err: ref CatchableError] =
  ## Adds an icon to the menu bar or notification area. It must be
  ## called after the application is ready.
  if not isMainThread():
    app.waitReady()
  elif not app.isReady():
    raiseAssert("mynim: newTray called before the application is ready; " &
      "create trays in app.whenReady")
  let t = Tray(menu: opts.menu)
  var err: ref CatchableError
  onMain(proc() =
    try:
      let (nt, e) = backend().newTray(TrayHandlerImpl(t: t))
      if e != nil:
        err = e
        return
      t.native = nt
      if opts.icon.len > 0:
        try:
          t.native.setImage(opts.icon, opts.iconIsTemplate)
        except CatchableError as e2:
          err = e2
          return
      if opts.title != "":
        t.native.setTitle(opts.title)
      if opts.toolTip != "":
        t.native.setToolTip(opts.toolTip)
      if opts.menu != nil:
        t.native.setMenu(opts.menu.snapshot())
    except CatchableError as e:
      err = e)
  if err != nil:
    return (nil, err)
  if t.native == nil:
    return (nil, errLoopStopped)
  (t, nil)

proc doTray(t: Tray; fn: proc(n: platform.Tray) {.closure.}) =
  onMain(proc() =
    if t.native != nil:
      fn(t.native))

proc setIcon*(t: Tray; png: seq[byte]; `template`: bool) =
  ## Replaces the icon with a PNG image.
  t.doTray(proc(n: platform.Tray) = n.setImage(png, `template`))

proc setTitle*(t: Tray; title: string) =
  ## Sets the text next to the icon (macOS).
  t.doTray(proc(n: platform.Tray) = n.setTitle(title))

proc setToolTip*(t: Tray; tip: string) =
  ## Sets the hover text.
  t.doTray(proc(n: platform.Tray) = n.setToolTip(tip))

proc setMenu*(t: Tray; m: Menu) =
  ## Sets the menu shown when the icon is clicked; nil removes it so
  ## clicks reach onClick.
  t.menu = m
  let snap = if m == nil: nil else: m.snapshot()
  t.doTray(proc(n: platform.Tray) = n.setMenu(snap))

proc popUpMenu*(t: Tray) =
  ## Shows the tray menu programmatically.
  let snap = if t.menu == nil: nil else: t.menu.snapshot()
  t.doTray(proc(n: platform.Tray) = n.popUpMenu(snap))

proc bounds*(t: Tray): Rectangle =
  ## The position of the icon on screen.
  onMainValue(proc(): Rectangle =
    if t.native == nil:
      return Rectangle()
    let b = t.native.bounds()
    Rectangle(x: b.x, y: b.y, width: b.width, height: b.height))

proc destroy*(t: Tray) =
  ## Removes the icon.
  onMain(proc() =
    if t.native != nil:
      t.native.destroy()
      t.native = nil)

proc onClick*(t: Tray; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the icon is clicked and it has no menu.
  t.onClick.add(fn, false)

proc onRightClick*(t: Tray; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the icon is right-clicked.
  t.onRight.add(fn, false)

## --- Notifications ---

proc notificationsSupported*(): bool =
  ## Whether desktop notifications can be shown. On macOS they require
  ## a packaged app, which `nim-xplat dev` and `nim-xplat build` produce.
  needsApp("notificationsSupported")
  onMainValue(proc(): bool = backend().notificationsSupported())

proc webViewSupported*(): bool =
  ## Whether the system webview is there, and so whether a window
  ## showing a web page can work: WKWebView on macOS, WebKitGTK on
  ## Linux, the WebView2 Runtime on Windows. A window showing native UI
  ## (WindowOptions.content) needs none, so an app whose windows all do
  ## runs without one, and this reports false in browsers, which show
  ## native UI only.
  ##
  ## Ask before creating the first window showing a page, as newWindow
  ## raises when the platform has no webview.
  ##
  ## It looks for the runtime without starting it: on Windows for the
  ## WebView2 Runtime or a WebView2Loader.dll next to the executable,
  ## on Linux by loading WebKitGTK. A runtime that is there but broken
  ## still reports true; the window then reports calls that need its
  ## page as failed. Once a window showing a page started the runtime,
  ## it reports whether that worked.
  needsApp("webViewSupported")
  onMainValue(proc(): bool = backend().webViewSupported())

proc newNotification*(opts: NotificationOptions): Notification =
  ## Creates a notification; call show to display it.
  var id = opts.id
  if id == "":
    # Unique across runs too, as notifications outlive them.
    id = "mynim-" & randomText()
  Notification(id: id, opts: opts)

proc id*(n: Notification): string =
  ## The notification's ID: NotificationOptions.id, or the one it was
  ## given.
  n.id

proc show*(n: Notification) =
  ## Displays the notification, and returns once the system has it. On
  ## macOS the first notification asks the user whether to allow them,
  ## and show waits for the answer; it returns
  ## errNotificationsDenied when they are not allowed.
  needsApp("notification.show")
  notifications.mu.acquire()
  let shown = notifications.byID.hasKey(n.id)
  notifications.byID[n.id] = n
  notifications.mu.release()
  var ch: system.Channel[ref CatchableError]
  ch.open(1)
  let pch = addr ch
  onMain(proc() =
    backend().showNotification(
      platform.Notification(id: n.id, title: n.opts.title,
        subtitle: n.opts.subtitle, body: n.opts.body,
        silent: n.opts.silent, group: n.opts.group),
      proc(err: ref CatchableError) = deliver(pch[], err)))
  let err = ch.await()
  if err != nil and not shown:
    # Nothing will be clicked.
    notifications.mu.acquire()
    notifications.byID.del(n.id)
    notifications.mu.release()
  if err != nil:
    raise err

proc close*(n: Notification) =
  ## Removes the notification.
  notifications.mu.acquire()
  notifications.byID.del(n.id)
  notifications.mu.release()
  onMain(proc() = backend().removeNotification(n.id))

proc clearNotifications*() =
  ## Removes the app's notifications, on macOS those of earlier runs
  ## left in Notification Center too. An app calls it as it comes to
  ## the front, so that what the user has seen in the app does not wait
  ## there:
  ##
  ##   discard app.onDidBecomeActive(proc() = clearNotifications())
  notifications.mu.acquire()
  notifications.byID.clear()
  notifications.mu.release()
  onMain(proc() = backend().removeAllNotifications())

proc onClick*(n: Notification; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the user clicks the notification.
  n.onClick.add(fn, false)

proc notificationClicked(id: string) =
  notifications.mu.acquire()
  let n = notifications.byID.getOrDefault(id)
  notifications.mu.release()
  if n != nil:
    fire(n.onClick)
  fire1(app.onNotificationClick, id)

## --- Network (network.go) ---

## network reports whether the computer is online.

proc networkStatus(s: platform.NetworkStatus): NetworkStatus =
  NetworkStatus(online: s.online, constrained: s.constrained)

proc status*(n: NetworkModule): NetworkStatus =
  ## The computer's network state.
  needsApp("network.status")
  onMainValue(proc(): NetworkStatus =
    networkStatus(backend().network().status()))

proc onChanged*(n: NetworkModule; fn: proc(s: NetworkStatus) {.closure.}):
    proc() {.closure.} =
  ## Called on the main thread when the computer's network state
  ## changes, with the new state.
  let off = n.onChanged.add(fn, false)
  n.mu.acquire()
  let start = not n.watching
  n.watching = true
  n.mu.release()
  if start:
    app.whenReady(proc() =
      let b = backend().network()
      b.watch()
      let s = networkStatus(b.status())
      n.mu.acquire()
      n.last = s
      n.mu.release())
  off

proc changed(n: NetworkModule; status: NetworkStatus) =
  ## Records a status from the backend and calls the listeners when it
  ## differs from the last one.
  n.mu.acquire()
  let same = status == n.last
  n.last = status
  n.mu.release()
  if not same:
    fire1(n.onChanged, status)
