## app.go: the backend itself — NSApplication lifecycle, the delegate
## that reports to AppHandler, the run loop source that drains the
## queue of functions posted from other threads, and appController.

proc registerClasses*()
proc registerAppDelegate*()
proc postEvent*(b: Backend, subtype: int16)

proc newBackend*(): Backend =
  ## newBackend creates the macOS backend.
  loadFrameworks()
  loadCF()
  Backend(
    byDelegate: initTable[id, macWindow](),
    byWebView: initTable[id, macWindow](),
    byNSWindow: initTable[id, macWindow](),
    bySurface: initTable[id, macSurface](),
    byAccess: initTable[id, accessElement](),
    menuItems: initTable[int, seq[id]](),
    trays: initTable[id, tray](),
    hotkeys: initTable[int, uint](),
  )

method name*(b: Backend): string = "darwin/wkwebview"

method isMainThread*(b: Backend): bool = pthreadMainNP() != 0

const
  nsApplicationActivationPolicyRegular = 0
  nsApplicationActivationPolicyAccessory = 1
  nsApplicationActivationPolicyProhibited = 2

proc activationPolicy(p: string): uint =
  case p
  of "accessory": nsApplicationActivationPolicyAccessory
  of "prohibited": nsApplicationActivationPolicyProhibited
  else: nsApplicationActivationPolicyRegular

## dispatchCallback is the perform of the run loop source: it runs the
## queued functions and lets the app dispatch its own.
proc dispatchCallback(info: pointer) {.cdecl.} =
  withPool(proc() =
    drainMainQueue()
    theBackend.h.dispatch())

method init*(b: Backend, h: AppHandler, opts: AppOptions) =
  b.h = h
  theBackend = b
  registerClasses()

  b.app = send(`class`("NSApplication"), "sharedApplication")
  discard send(b.app, "setActivationPolicy:",
               argu(activationPolicy(opts.activationPolicy)))
  ## No automatic "Show Tab Bar" items and window tabbing.
  discard send(`class`("NSWindow"),
               "setAllowsAutomaticWindowTabbing:", argu(0))

  b.delegate = alloc("MyNimAppDelegate")
  discard send(b.app, "setDelegate:", argu(b.delegate))
  b.menuTarget = alloc("MyNimMenuTarget")
  b.attachNotificationDelegate()

  ## A run loop source drives the queue of functions posted from other
  ## threads. It fires in every run loop mode, including while menus
  ## are tracked, windows are resized and modal dialogs run.
  b.mainLoop = cfRunLoopGetMain()
  ## CFRunLoopSourceContext; perform is the last field
  var ctx: array[10, pointer]
  ctx[9] = cast[pointer](dispatchCallback)
  b.source = cfRunLoopSourceCreate(nil, 0, addr ctx[0])
  cfRunLoopAddSource(b.mainLoop, b.source, kCFRunLoopCommonModes)

  ## Appearance (dark mode) and display configuration changes.
  discard send(b.app, "addObserver:forKeyPath:options:context:",
    argu(b.delegate), argu(nsString("effectiveAppearance")), argu(1),
    argu(0))
  let center = send(`class`("NSNotificationCenter"), "defaultCenter")
  discard send(center, "addObserver:selector:name:object:",
    argu(b.delegate), argu(sel("screensChanged:")),
    argu(nsString(
      "NSApplicationDidChangeScreenParametersNotification")), argu(0))
  ## The accent color, and the display settings of accessibility.
  discard send(center, "addObserver:selector:name:object:",
    argu(b.delegate), argu(sel("preferencesChanged:")),
    argu(nsString("NSSystemColorsDidChangeNotification")), argu(0))
  discard send(send(workspace(), "notificationCenter"),
    "addObserver:selector:name:object:", argu(b.delegate),
    argu(sel("preferencesChanged:")),
    argu(nsString(
      "NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification")),
    argu(0))
  ## The languages and regional formats of the user: Foundation tells
  ## of a new current locale, and System Settings of new languages, a
  ## new time and date format, which the current locale may not
  ## change.
  discard send(center, "addObserver:selector:name:object:",
    argu(b.delegate), argu(sel("localeChanged:")),
    argu(nsString("NSCurrentLocaleDidChangeNotification")), argu(0))
  let distributed = send(`class`("NSDistributedNotificationCenter"),
                         "defaultCenter")
  for name in ["AppleLanguagePreferencesChangedNotification",
               "AppleTimePreferencesChangedNotification",
               "AppleDatePreferencesChangedNotification"]:
    discard send(distributed, "addObserver:selector:name:object:",
      argu(b.delegate), argu(sel("localeChanged:")),
      argu(nsString(name)), argu(0))

method run*(b: Backend) =
  discard send(b.app, "run")

method quit*(b: Backend) =
  if not send(b.app, "modalWindow").isNil:
    ## stop: would end the modal session (an app-modal dialog) rather
    ## than the event loop: abort the session, and stop once it has
    ## unwound (see runPanel).
    b.quitAfterModal = true
    discard send(b.app, "abortModal")
    return
  discard send(b.app, "stop:", argu(0))
  ## stop: takes effect after the next event; make sure there is one.
  b.postEvent(0)

method signal*(b: Backend) =
  if not b.source.isNil:
    cfRunLoopSourceSignal(b.source)
    cfRunLoopWakeUp(b.mainLoop)

const
  nsEventTypeApplicationDefined = 15
  wakeSubtype = 0x6d67 ## 'mg'

proc postEvent*(b: Backend, subtype: int16) =
  withPool(proc() =
    let ev = msgOtherEvent(`class`("NSEvent"),
      sel("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:"),
      nsEventTypeApplicationDefined.uint, NSPoint(), 0, 0, 0, nil,
      subtype, 0, 0)
    discard send(b.app, "postEvent:atStart:", argu(ev), argu(1)))

method step*(b: Backend) =
  inc b.stepping
  defer: dec b.stepping
  withPool(proc() =
    let until = msgDateSince(`class`("NSDate"),
      sel("dateWithTimeIntervalSinceNow:"), 0.5)
    let mode = nsString("kCFRunLoopDefaultMode")
    let ev = msgNextEvent(b.app,
      sel("nextEventMatchingMask:untilDate:inMode:dequeue:"),
      high(uint64), until, mode, true)
    if ev.isNil:
      return
    if sendInt(ev, "type") == nsEventTypeApplicationDefined and
        cast[int16](sendInt(ev, "subtype")) == wakeSubtype:
      return
    discard send(b.app, "sendEvent:", argu(ev)))

## wake makes a pending step return. It is called from any thread.
method wake*(b: Backend) =
  if b.app.isNil:
    return
  b.postEvent(wakeSubtype)

method app*(b: Backend): AppController = appController(b: b)
method dialogs*(b: Backend): Dialogs = dialogsImpl(b: b)
method clipboard*(b: Backend): Clipboard = clipboardImpl()
method shell*(b: Backend): Shell = shellImpl()
method screen*(b: Backend): Screen = screenImpl()
method theme*(b: Backend): Theme = themeImpl(b: b)
method power*(b: Backend): Power = powerImpl(b: b)
method secrets*(b: Backend): Secrets = secretsImpl()

var classesOnce = false

proc registerClasses*() =
  if classesOnce:
    return
  classesOnce = true
  registerAppDelegate()
  registerWindowClasses()
  registerSurfaceClass()
  registerClipboardClass()
  registerAccessClass()
  registerMenuTarget()
  registerSchemeHandler()
  registerTrayTarget()
  registerNotificationDelegate()

const
  nsTerminateCancel = 0
  nsTerminateNow = 1

  kCoreEventClass = 0x61657674 ## 'aevt'
  kAEQuitApplication = 0x71756974 ## 'quit'
  keyErrorNumber = 0x6572726e ## 'errn'
  userCanceledErr = -128

proc registerAppDelegate*() =
  discard classDef("MyNimAppDelegate", "NSObject",
    @["NSApplicationDelegate"], @[
    # The end of a printToPDF job (printJobs). WebKit's print
    # operations may finish on a background thread.
    methodDef("mynimPrintOperationDidRun:success:contextInfo:",
      cast[pointer](proc(self: id, cmd: SEL, op: id, success: bool,
                         job: pointer) {.cdecl.} =
        let j = job
        theBackend.runOnMain(proc() =
          let jn = printJobs.getOrDefault(cast[uint](j))
          if jn != nil:
            printJobs.del(cast[uint](j))
            jn.done(success))),
      "v@:@@B^v"),
    methodDef("applicationWillFinishLaunching:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        # Handle the quit Apple Event (Dock > Quit, AppleScript,
        # logout) ourselves so the sender gets a proper reply while
        # run still returns normally. AppKit installs its default
        # handlers right before this notification.
        let aem = send(`class`("NSAppleEventManager"),
                       "sharedAppleEventManager")
        discard send(aem,
          "setEventHandler:andSelector:forEventClass:andEventID:",
          argu(self),
          argu(sel("mynimHandleQuitEvent:withReplyEvent:")),
          argu(kCoreEventClass), argu(kAEQuitApplication))
        theBackend.openedAtLogin = launchedAsLoginItem()),
      "v@:@"),
    methodDef("applicationDidFinishLaunching:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        let b = theBackend
        if sendInt(b.app, "activationPolicy") ==
            nsApplicationActivationPolicyRegular:
          # Plain executables (nimble run) do not come to the front
          # on their own.
          discard send(b.app, "activateIgnoringOtherApps:", argu(1))
        b.h.ready()),
      "v@:@"),
    # terminate: (Cmd+Q and the Quit menu item) ends up here. Rather
    # than letting AppKit exit the process, stop the run loop so run
    # returns and deferred cleanup in main runs.
    methodDef("applicationShouldTerminate:",
      cast[pointer](proc(self: id, cmd: SEL, app: id): uint {.cdecl.} =
        let b = theBackend
        if b.h.quitRequested():
          b.quit()
        nsTerminateCancel.uint),
      "Q@:@"),
    # Power and session notifications (backend.powerImpl().watch).
    methodDef("mynimPowerNotification:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        let name = goString(send(n, "name"))
        for (k, v) in powerEvents:
          if k == name:
            theBackend.h.powerEvent(v)
            break),
      "v@:@"),
    methodDef("mynimHandleQuitEvent:withReplyEvent:",
      cast[pointer](proc(self: id, cmd: SEL, event, reply: id)
                    {.cdecl.} =
        let b = theBackend
        if b.h.quitRequested():
          b.quit()
          return
        if not reply.isNil:
          let canceled = int32(userCanceledErr)
          let code = send(`class`("NSAppleEventDescriptor"),
            "descriptorWithInt32:", argu(cast[uint32](canceled)))
          discard send(reply, "setParamDescriptor:forKeyword:",
                       argu(code), argu(keyErrorNumber))),
      "v@:@@"),
    methodDef("applicationWillTerminate:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        theBackend.h.terminating()),
      "v@:@"),
    methodDef("applicationDockMenu:",
      cast[pointer](proc(self: id, cmd: SEL, app: id): id {.cdecl.} =
        theBackend.dockMenu),
      "@@:@"),
    methodDef("applicationShouldHandleReopen:hasVisibleWindows:",
      cast[pointer](proc(self: id, cmd: SEL, app: id,
                         visible: bool): bool {.cdecl.} =
        theBackend.h.activated(visible)
        true),
      "B@:@B"),
    methodDef("applicationDidBecomeActive:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        theBackend.h.didBecomeActive()),
      "v@:@"),
    methodDef("applicationDidResignActive:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        theBackend.h.didResignActive()),
      "v@:@"),
    methodDef("application:openURLs:",
      cast[pointer](proc(self: id, cmd: SEL, app, urls: id) {.cdecl.} =
        var files, links: seq[string]
        for u in arrayItems(urls):
          if sendBool(u, "isFileURL"):
            files.add goString(send(u, "path"))
          else:
            links.add goString(send(u, "absoluteString"))
        if files.len > 0:
          theBackend.h.openFiles(files)
        if links.len > 0:
          theBackend.h.openURLs(links)),
      "v@:@@"),
    methodDef("applicationSupportsSecureRestorableState:",
      cast[pointer](proc(self: id, cmd: SEL, app: id): bool {.cdecl.} =
        true),
      "B@:@"),
    methodDef("applicationShouldTerminateAfterLastWindowClosed:",
      cast[pointer](proc(self: id, cmd: SEL, app: id): bool {.cdecl.} =
        false),
      "B@:@"),
    methodDef("observeValueForKeyPath:ofObject:change:context:",
      cast[pointer](proc(self: id, cmd: SEL, keyPath, obj, change: id,
                         ctx: pointer) {.cdecl.} =
        if goString(keyPath) == "effectiveAppearance":
          theBackend.h.themeChanged()),
      "v@:@@@^v"),
    methodDef("screensChanged:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        theBackend.h.displaysChanged()),
      "v@:@"),
    methodDef("preferencesChanged:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        theBackend.h.themeChanged()),
      "v@:@"),
    methodDef("localeChanged:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        theBackend.h.localeChanged()),
      "v@:@"),
  ])

method setActivationPolicy*(a: appController, p: string) =
  discard send(a.b.app, "setActivationPolicy:", argu(activationPolicy(p)))
  if p == "regular":
    discard send(a.b.app, "activateIgnoringOtherApps:", argu(1))

method activate*(a: appController) =
  discard send(a.b.app, "activateIgnoringOtherApps:", argu(1))

method hide*(a: appController) = discard send(a.b.app, "hide:", argu(0))
method unhide*(a: appController) =
  discard send(a.b.app, "unhide:", argu(0))
method isHidden*(a: appController): bool =
  sendBool(a.b.app, "isHidden")

method setBadge*(a: appController, label: string) =
  let tile = send(a.b.app, "dockTile")
  var s: id
  if label != "":
    s = nsString(label)
  discard send(tile, "setBadgeLabel:", argu(s))

method badge*(a: appController): string =
  goString(send(send(a.b.app, "dockTile"), "badgeLabel"))

method bounce*(a: appController, critical: bool): int =
  var kind = 10 ## NSInformationalRequest
  if critical:
    kind = 0 ## NSCriticalRequest
  sendInt(a.b.app, "requestUserAttention:", argu(kind))

method cancelBounce*(a: appController, requestID: int) =
  discard send(a.b.app, "cancelUserAttentionRequest:", argu(requestID))

method setDockMenu*(a: appController, m: Menu) =
  let b = a.b
  if b.dockMenuOwner == 0:
    b.dockMenuOwner = newOwner()
  withPool(proc() =
    dropOwner(b.dockMenuOwner)
    release(b.dockMenu)
    b.dockMenu = nil
    if m != nil:
      b.dockMenu = retain(b.buildMenu(m, "", b.dockMenuOwner)))

method setDockIcon*(a: appController, png: seq[byte]) =
  var img: id
  if png.len > 0:
    img = send(send(`class`("NSImage"), "alloc"), "initWithData:",
               argu(nsData(png)))
    if img.isNil:
      raise errInvalidImage()
    defer: release(img)
  discard send(a.b.app, "setApplicationIconImage:", argu(img))

method showAboutPanel*(a: appController, o: AboutPanelOptions) =
  let dict = send(`class`("NSMutableDictionary"), "dictionary")
  let set = proc(key, value: string) =
    if value != "":
      discard send(dict, "setObject:forKey:", argu(nsString(value)),
                   argu(nsString(key)))
  set("ApplicationName", o.applicationName)
  set("ApplicationVersion", o.applicationVersion)
  set("Version", o.version)
  set("Copyright", o.copyright)
  if o.credits != "":
    let credits = autorelease(send(
      send(`class`("NSAttributedString"), "alloc"), "initWithString:",
      argu(nsString(o.credits))))
    discard send(dict, "setObject:forKey:", argu(credits),
                 argu(nsString("Credits")))
  discard send(a.b.app, "activateIgnoringOtherApps:", argu(1))
  discard send(a.b.app, "orderFrontStandardAboutPanelWithOptions:",
               argu(dict))

method `package`*(a: appController):
    tuple[info: PackageInfo, ok: bool] =
  var info: PackageInfo
  var ok = false
  withPool(proc() =
    let bundle = send(`class`("NSBundle"), "mainBundle")
    let path = goString(send(bundle, "bundlePath"))
    if not path.endsWith(".app"):
      return
    ok = true
    let get = proc(key: string): string =
      goString(send(bundle, "objectForInfoDictionaryKey:",
                    argu(nsString(key))))
    info.name = get("CFBundleDisplayName")
    if info.name == "":
      info.name = get("CFBundleName")
    info.version = get("CFBundleShortVersionString")
    info.identifier = goString(send(bundle, "bundleIdentifier")))
  (info, ok)

method clearBrowsingData*(a: appController,
                          done: proc(err: ref CatchableError)) =
  withPool(proc() =
    let store = send(`class`("WKWebsiteDataStore"), "defaultDataStore")
    let types = send(`class`("WKWebsiteDataStore"),
                     "allWebsiteDataTypes")
    let blk = mkBlockVoid(proc() =
      a.b.runOnMain(proc() = done(nil)))
    discard send(store,
      "removeDataOfTypes:modifiedSince:completionHandler:",
      argu(types), argu(send(`class`("NSDate"), "distantPast")),
      argu(blk))
    blockRelease(blk))

## addRecentDocument and clearRecentDocuments use the shared document
## controller, as Electron does: AppKit lists its recent documents in
## the Dock menu, and in an Open Recent menu.
method addRecentDocument*(a: appController, path: string) =
  withPool(proc() =
    discard send(send(`class`("NSDocumentController"),
                      "sharedDocumentController"),
                 "noteNewRecentDocumentURL:", argu(fileURL(path))))

method clearRecentDocuments*(a: appController) =
  withPool(proc() =
    discard send(send(`class`("NSDocumentController"),
                      "sharedDocumentController"),
                 "clearRecentDocuments:", argu(0)))

method setJumpListTasks*(a: appController,
                         tasks: seq[JumpListTask]) = discard

## webViewSupported reports whether a window showing a web page can
## have one. WKWebView is part of macOS, so this holds wherever the
## app runs.
method webViewSupported*(b: Backend): bool = hasClass("WKWebView")
