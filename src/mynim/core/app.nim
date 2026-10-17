## app.go, dev.go, login.go — the application lifecycle, the Dock, and
## login-item integration.

## app is the application singleton (state.nim).

proc prepareQuit(a: Application): bool

proc needsApp*(call: string) =
  ## Panics when main calls something that needs the running app before
  ## run: the backend is not initialized yet (on Linux its libraries are
  ## not even loaded), and main cannot wait for it. Other threads wait
  ## for the app to start instead. call names the method.
  if isMainThread() and not app.initialized:
    raiseAssert("mynim: " & call &
      " called before app.run; call it once the application is ready (app.whenReady)")

proc waitReady(a: Application) =
  ## Blocks a thread other than the main one until the application is
  ## ready.
  discard a.readyCh.recv()

# The handler the backend calls on the main thread; defined below the
# procs it needs.

type AppHandlerImpl = ref object of platform.AppHandler

proc name*(a: Application): string =
  ## The application name. It defaults to the bundle name of a packaged
  ## app, else to the executable name.
  a.mu.acquire()
  let name = a.name
  a.mu.release()
  if name != "":
    return if devLaunched and not name.endsWith(" Dev"):
      name & " Dev" else: name
  let (info, ok) = packageInfo()
  if ok and info.name != "":
    return if devLaunched and not info.name.endsWith(" Dev"):
      info.name & " Dev" else: info.name
  let exe = getAppFilename().extractFilename()
  if exe == "":
    return "MyNim"
  result = exe.changeFileExt("").extractFilename()
  if devLaunched and not result.endsWith(" Dev"):
    result.add " Dev"

proc setName*(a: Application; name: string) =
  ## Overrides the application name. Call it before run.
  a.mu.acquire()
  a.name = name
  a.mu.release()

proc version*(a: Application): string =
  ## The application version, which defaults to the version of the
  ## packaged app.
  a.mu.acquire()
  result = a.version
  a.mu.release()
  if result == "":
    let (info, ok) = packageInfo()
    if ok:
      result = info.version

proc setVersion*(a: Application; v: string) =
  ## Overrides the application version.
  a.mu.acquire()
  a.version = v
  a.mu.release()

proc isPackaged*(a: Application): bool =
  ## Whether the application runs from an app bundle (created by
  ## `mynim dev` and `mynim build`) rather than a plain executable.
  let (_, ok) = packageInfo()
  ok

proc setMenu*(a: Application; m: Menu) =
  ## Sets the application menu: the menu bar on macOS and the menu bar
  ## of windows without their own menu on Linux and Windows. nil
  ## removes it. Without a call to setMenu a default menu with the
  ## usual App, Edit, View and Window items is installed.
  a.mu.acquire()
  a.menu = m
  a.menuSet = true
  let ready = a.ready
  a.mu.release()
  if ready:
    onMain(proc() = backend().setApplicationMenu(m.snapshot()))

proc menu*(a: Application): Menu =
  ## The application menu.
  a.mu.acquire()
  result = a.menu
  a.mu.release()

proc activationPolicy(a: Application): ActivationPolicy =
  a.mu.acquire()
  defer: a.mu.release()
  if a.policy == ActivationPolicy(0) and not a.policySet:
    return policyRegular
  a.policy

proc setActivationPolicy*(a: Application; p: ActivationPolicy) =
  ## Changes how the app appears in the Dock (macOS).
  a.mu.acquire()
  a.policy = p
  a.policySet = true
  let running = a.running
  a.mu.release()
  if running:
    onMain(proc() = backend().app().setActivationPolicy($p))

proc focus*(a: Application) =
  ## Brings the application to the foreground.
  needsApp("app.focus")
  onMain(proc() = backend().app().activate())

proc hide*(a: Application) =
  ## Hides all windows of the application (macOS).
  needsApp("app.hide")
  onMain(proc() = backend().app().hide())

proc show*(a: Application) =
  ## Shows the application after hide (macOS).
  needsApp("app.show")
  onMain(proc() = backend().app().unhide())

proc isHidden*(a: Application): bool =
  ## Whether the application is hidden (macOS).
  needsApp("app.isHidden")
  onMainValue(proc(): bool = backend().app().isHidden())

proc setBadgeCount*(a: Application; n: int) =
  ## Shows a counter on the application icon. Zero clears it.
  needsApp("app.setBadgeCount")
  let label = if n > 0: $n else: ""
  a.dock.setBadge(label)

proc showAboutPanel*(a: Application; opts: AboutPanelOptions) =
  ## Shows the standard about panel (macOS).
  needsApp("app.showAboutPanel")
  onMain(proc() = backend().app().showAboutPanel(
    platform.AboutPanelOptions(
      applicationName: opts.applicationName,
      applicationVersion: opts.applicationVersion,
      version: opts.version,
      copyright: opts.copyright,
      credits: opts.credits)))

proc whenReady*(a: Application; fn: proc() {.closure.}) =
  ## Calls fn on the main thread once the application has finished
  ## launching. Windows can only be created after that point. If the
  ## application is already ready, fn is scheduled right away.
  a.mu.acquire()
  if not a.ready:
    a.whenReady.add fn
    a.mu.release()
    return
  a.mu.release()
  discard postMain(fn)

proc isReady*(a: Application): bool =
  ## Whether the application has finished launching.
  a.mu.acquire()
  result = a.ready
  a.mu.release()

proc quit*(a: Application) =
  ## Closes all windows and then quits. onBeforeQuit and onWillQuit
  ## listeners, as well as the onClose listeners of every window, can
  ## cancel it.
  discard postMain(proc() =
    if a.prepareQuit():
      backend().quit())

proc exit*(a: Application; code: int) =
  ## Terminates the process immediately with the given exit code,
  ## without emitting quit events or asking windows.
  onMain(proc() =
    for w in allWindows():
      w.destroy()
    saveWindowStates())
  quit(code)

## prepareQuit runs the quit sequence on the main thread and reports
## whether the application may quit.
proc prepareQuit(a: Application): bool =
  if false:
    return false
  var before = QuitEvent()
  fire1(a.onBeforeQuit, before)
  if before.preventable.prevented:
    return false
  a.quitting = true
  for w in allWindows():
    if not w.tryClose():
      a.quitting = false
      return false
  var will = QuitEvent()
  fire1(a.onWillQuit, will)
  if will.preventable.prevented:
    a.quitting = false
    return false
  # Providers are application-owned, independent of the windows just
  # closed. Persist them before the native loop ends; callers needing
  # error handling may flush explicitly from a quit listener.
  try: discard clipboard.flush()
  except CatchableError: discard
  stopCookieCalls()
  true

## finish runs once after the event loop has stopped.
proc finish(a: Application) =
  if a.finishedOnce.exchange(true):
    return
  stopCookieCalls()
  stopFileWatches()
  clipboardStopped = true
  backend().clipboard().close()
  saveWindowStates()
  fire(a.onQuit)
  if a.relaunch:
    relaunchNow() # after onQuit, which releases the single instance lock
  loop.shutdown()

## lastWindowClosed is called on the main thread when the last window
## has been closed.
proc lastWindowClosed(a: Application) =
  if a.quitting:
    return
  if a.onWindowAllClosed.len() > 0:
    fire(a.onWindowAllClosed)
    return
  a.quit()

proc handleReady(a: Application) =
  a.mu.acquire()
  let menuSet = a.menuSet
  a.mu.release()
  var def: Menu
  if not menuSet:
    # Built outside the lock: role labels need app.name.
    def = defaultMenu()

  a.mu.acquire()
  a.ready = true
  let fns = a.whenReady
  a.whenReady.setLen(0)
  if not menuSet:
    a.menu = def
  let menu = a.menu
  a.mu.release()
  a.readyCh.close()

  backend().setApplicationMenu(if menu == nil: nil else: menu.snapshot())
  fire(a.onReady)
  for fn in fns:
    fn()
  # After the windows the app opens when ready, which URLs may target.
  discard postMain(proc() = launchArgs())

## run starts the native event loop and blocks until the application
## quits. It must be called from the main thread, usually as the last
## statement of main.
##
## SIGINT and SIGTERM quit the application like quit; a second signal
## exits immediately.
##
## When the MYNIM_GENERATE environment variable is set (see
## `mynim generate`), run writes the TypeScript client for the bound
## services to that path, or nothing when the app binds none, and
## returns without starting the event loop.
proc run*(a: Application) =
  let genEnv = getEnv("MYNIM_GENERATE", getEnv("MYGO_GENERATE"))
  if genEnv != "":
    writeTypeScript(genEnv)
    return
  if not isMainThread():
    raise newException(ValueError,
      "mynim: app.run must be called from the main thread")
  a.mu.acquire()
  if a.running:
    a.mu.release()
    raise newException(ValueError, "mynim: app.run called twice")
  a.running = true
  a.mu.release()

  let b = backend()
  # POSIX signal masks are per-thread, so install the waiter before the
  # backend or cleanup worker can create threads that inherit the mask.
  quitOnSignals()
  var t: Thread[void]
  createThread(t, proc() {.thread.} = cleanUpdateLeftovers())
  b.init(AppHandlerImpl(), platform.AppOptions(
    name: a.name(),
    activationPolicy: $a.activationPolicy()))
  a.initialized = true
  # Settings made before run, which the backend could not take yet.
  theme.apply()
  a.startLocale()
  if a.dock.menu() != nil:
    b.app().setDockMenu(a.dock.menu().snapshot())
  # Run whatever was scheduled before the event loop existed.
  b.signal()
  b.run()
  a.finish()

## --- event listeners ---

proc onReady*(a: Application; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called once the application has finished launching.
  a.onReady.add(fn, false)

proc onWindowAllClosed*(a: Application; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the last window has been closed, unless the
  ## application is quitting. Without listeners the application quits;
  ## registering one keeps it running (the common choice on macOS).
  a.onWindowAllClosed.add(fn, false)

proc onBeforeQuit*(a: Application; fn: proc(e: var QuitEvent) {.closure.}): proc() {.closure.} =
  ## Called when a quit starts, before windows are closed.
  a.onBeforeQuit.add(fn, false)

proc onWillQuit*(a: Application; fn: proc(e: var QuitEvent) {.closure.}): proc() {.closure.} =
  ## Called after all windows have been closed, right before the event
  ## loop stops.
  a.onWillQuit.add(fn, false)

proc onQuit*(a: Application; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called after the event loop has stopped.
  a.onQuit.add(fn, false)

proc onActivate*(a: Application; fn: proc(v: bool) {.closure.}): proc() {.closure.} =
  ## Called when the application is re-activated, for example by
  ## clicking its Dock icon (macOS). Apps usually open a window when
  ## hasVisibleWindows is false.
  a.onActivate.add(fn, false)

proc onDidBecomeActive*(a: Application; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the application becomes the active one.
  a.onDidBecomeActive.add(fn, false)

proc onDidResignActive*(a: Application; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the application stops being active.
  a.onDidResignActive.add(fn, false)

proc onOpenURL*(a: Application; fn: proc(u: string) {.closure.}): proc() {.closure.} =
  ## Called when the application is asked to open a URL of a scheme it
  ## handles. Register it before run to receive the URL the app was
  ## launched with.
  a.onOpenURL.add(fn, false)

proc onOpenFile*(a: Application; fn: proc(p: string) {.closure.}): proc() {.closure.} =
  ## Called when a file is opened with the application. Register it
  ## before run to receive the files the app was launched with.
  a.onOpenFile.add(fn, false)

proc onNotificationClick*(a: Application; fn: proc(id: string) {.closure.}): proc() {.closure.} =
  ## Called with the ID of every notification of the app that the user
  ## clicks, after its onClick listeners: also one of an earlier run,
  ## which no Notification of this run holds, such as the one whose
  ## click launched the app (macOS). Register it before run to receive
  ## that one. Give notifications IDs of the app's own, such as the
  ## conversation they are about, to know what to open.
  a.onNotificationClick.add(fn, false)

proc onWindowCreated*(a: Application; fn: proc(w: Window) {.closure.}): proc() {.closure.} =
  ## Called for every new window.
  a.onWindowCreated.add(fn, false)

proc clearBrowsingData*(a: Application) =
  ## Deletes what the app's pages stored: cookies, local and session
  ## storage, IndexedDB, service workers and caches, e.g. when the user
  ## signs out. Open pages keep what they hold in memory until they are
  ## reloaded.
  needsApp("app.clearBrowsingData")
  var ch: system.Channel[ref CatchableError]
  ch.open(1)
  let pch = addr ch
  onMain(proc() =
    backend().app().clearBrowsingData(
      proc(err: ref CatchableError) = deliver(pch[], err)))
  let err = ch.await()
  if err != nil: raise err

## --- Dock ---

proc setMenu*(d: Dock; m: Menu) =
  ## Sets the menu the Dock icon shows above the standard items, e.g.
  ## to open a new window; nil removes it. It may be called before
  ## app.run.
  d.mu.acquire()
  d.menu = m # its items must stay reachable for clicks
  d.mu.release()
  onMain(proc() =
    if app.initialized: # else run installs it
      # The menu set last: calls may reach the main thread in
      # another order.
      backend().app().setDockMenu(
        if d.menu() == nil: nil else: d.menu().snapshot()))

proc menu*(d: Dock): Menu =
  ## The menu set with setMenu.
  d.mu.acquire()
  result = d.menu
  d.mu.release()

proc setBadge*(d: Dock; text: string) =
  ## Shows text on the Dock icon; "" clears it.
  needsApp("app.dock.setBadge")
  onMain(proc() = backend().app().setBadge(text))

proc badge*(d: Dock): string =
  ## The text shown on the Dock icon.
  needsApp("app.dock.badge")
  onMainValue(proc(): string = backend().app().badge())

proc bounce*(d: Dock; critical: bool): int =
  ## Bounces the Dock icon to request attention and returns an id for
  ## cancelBounce. Critical bounces continue until the app is
  ## activated.
  needsApp("app.dock.bounce")
  onMainValue(proc(): int = backend().app().bounce(critical))

proc cancelBounce*(d: Dock; id: int) =
  ## Stops a bounce started with bounce.
  needsApp("app.dock.cancelBounce")
  onMain(proc() = backend().app().cancelBounce(id))

proc setIcon*(d: Dock; png: seq[byte]) =
  ## Replaces the Dock icon with a PNG image.
  needsApp("app.dock.setIcon")
  onMain(proc() = backend().app().setDockIcon(png))

proc hide*(d: Dock) = app.setActivationPolicy(policyAccessory)
  ## Removes the Dock icon (accessory activation policy).

proc show*(d: Dock) = app.setActivationPolicy(policyRegular)
  ## Restores the Dock icon (regular activation policy).

## --- login.go ---

## loginArg is passed by the command that starts the app at login
## (Linux, Windows, and macOS 12).
const loginArg = "--mygo-opened-at-login"

proc takeLoginArg(args: seq[string]): tuple[rest: seq[string], ok: bool] =
  ## Removes loginArg from a command line.
  for i, a in args:
    if a == loginArg and i > 0:
      var r = args
      r.delete(i)
      return (r, true)
  (args, false)

proc appID(): string =
  ## Identifies the app to the system: its identifier, else its name.
  let (info, ok) = packageInfo()
  if ok and info.identifier != "":
    return info.identifier
  app.name()

## devRelaunchCode is the exit code with which a development build asks
## `mynim dev` to start it again (relaunch).
const devRelaunchCode = 75

proc setOpenAtLogin*(a: Application; open: bool) =
  ## Makes the app start when the user logs in, or stops it from doing
  ## so. Apps usually offer it as a setting:
  ##
  ##   app.setOpenAtLogin(enabled)
  ##
  ## On macOS 13 and later the app becomes a login item of the user
  ## (System Settings > General > Login Items), which needs an app
  ## bundle; on macOS 12 a launch agent starts it. On Linux it gets an
  ## XDG autostart entry, on Windows a Run entry of the user, which
  ## Task Manager can disable.
  let id = appID()
  let name = a.name()
  onMain(proc() =
    backend().app().setOpenAtLogin(open, id, name, loginArg))

proc openAtLogin*(a: Application): bool =
  ## Whether the app starts when the user logs in.
  let id = appID()
  let name = a.name()
  onMainValue(proc(): bool =
    backend().app().openAtLogin(id, name, loginArg))

proc wasOpenedAtLogin*(a: Application): bool =
  ## Whether the system started the app because the user logged in,
  ## e.g. to start it in the background:
  ##
  ##   newWindow(WindowOptions(url: "/", hidden: app.wasOpenedAtLogin()))
  openedAtLogin or
    onMainValue(proc(): bool = backend().app().openedAtLogin())

proc relaunch*(a: Application) =
  ## Quits the app like quit, then starts it again with the same
  ## arguments, e.g. after changing a setting that needs a restart.
  ## Nothing happens when onBeforeQuit, onWillQuit or a window cancels
  ## the quit. Under `mynim dev` the build exits once it has quit and
  ## mynim dev starts it again.
  discard postMain(proc() =
    a.relaunch = true
    if a.prepareQuit():
      backend().quit()
    else:
      a.relaunch = false)

## --- the AppHandler the backend calls (appHandler in Go) ---

method ready(h: AppHandlerImpl) = app.handleReady()
method dispatch(h: AppHandlerImpl) = loop.drain()
method quitRequested(h: AppHandlerImpl): bool = app.prepareQuit()
method terminating(h: AppHandlerImpl) = app.finish()
method activated(h: AppHandlerImpl; v: bool) =
  fire1(app.onActivate, v)
method didBecomeActive(h: AppHandlerImpl) =
  fire(app.onDidBecomeActive)
method didResignActive(h: AppHandlerImpl) =
  fire(app.onDidResignActive)
method openURLs(h: AppHandlerImpl; urls: seq[string]) =
  for u in urls:
    fire1(app.onOpenURL, u)
method openFiles(h: AppHandlerImpl; paths: seq[string]) =
  for p in paths:
    fire1(app.onOpenFile, p)
method menuItemClicked(h: AppHandlerImpl; id: int) =
  menuItemClicked(id, focusedWindow())
method themeChanged(h: AppHandlerImpl) =
  updateBackgrounds()
  contentThemeChanged()
  theme.changed()
  # Pages hear the accent and the settings of accessibility, which the
  # media queries do not tell them.
  sendPreferences()
method displaysChanged(h: AppHandlerImpl) = screen.changed()
method localeChanged(h: AppHandlerImpl) = app.localeChangedFromSystem()
method powerEvent(h: AppHandlerImpl; event: string) = power.event(event)
method hotkeyPressed(h: AppHandlerImpl; id: int) = globalShortcut.pressed(id)
method notificationClicked(h: AppHandlerImpl; id: string) =
  notificationClicked(id)
method networkChanged(h: AppHandlerImpl; s: platform.NetworkStatus) =
  network.changed(networkStatus(s))
