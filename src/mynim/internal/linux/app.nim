## app.nim: the Linux (GTK 3 + WebKitGTK) backend's lifecycle and the
## appController that whole-application calls go through.

proc getTid(): Pid {.importc: "gettid", header: "<unistd.h>".}

## newBackend creates the Linux backend. Libraries are loaded by init so
## that programs still start (and report a clear error) on machines
## without GTK.
proc newBackend*(): Backend =
  Backend(
    windows: initTable[int, gtkWindow](),
    byWebView: initTable[pointer, gtkWindow](),
    webViews: initTable[int, gtkWindow](),
    schemes: initTable[string, bool](),
    trays: initTable[int, gtkTray]())

method name*(b: Backend): string = "linux/webkitgtk"

## windowManager reports an X11 window manager, which places windows
## once they show; Wayland compositors do not tell where windows are.
proc windowManager*(b: Backend, win: pointer): bool =
  b.onX11 and goStr(b.wmName(gtkWidgetGetScreen(win))) != "unknown"

method isMainThread*(b: Backend): bool =
  ## reports whether the caller runs on the thread the process started
  ## with, whose thread id is the process id. Package mynim locks the
  ## main thread to it, so this holds before init too.
  getTid() == getpid()

var
  callbacksOnce: bool
  readyCallback*, dispatchCallback*: pointer

proc initCallbacks() =
  if callbacksOnce: return
  callbacksOnce = true
  readyCallback = cast[pointer](proc(data: pointer): int32 {.cdecl.} =
    theBackend.h.ready()
    0) # G_SOURCE_REMOVE
  dispatchCallback = cast[pointer](proc(data: pointer): int32 {.cdecl.} =
    theBackend.signaled.store(false)
    theBackend.h.dispatch()
    0)
  initWindowCallbacks()
  initFlyoutCallbacks()
  initSurfaceCallbacks()
  initDownloadCallbacks()
  initMenuCallbacks()
  initSystemCallbacks()
  initClipboardCallbacks()

method init*(b: Backend, h: AppHandler, opts: AppOptions) =
  b.h = h
  b.name = opts.name
  theBackend = b
  let err = load()
  if not err.isNil:
    raise err
  if getEnv("WEBKIT_DISABLE_DMABUF_RENDERER") == "":
    # Avoid blank windows on setups where WebKitGTK's DMA-BUF renderer
    # fails (NVIDIA, VMs, containers).
    putEnv("WEBKIT_DISABLE_DMABUF_RENDERER", "1")
  if not gtkInitCheck(nil, nil):
    raise newException(CatchableError,
      "mynim: cannot open display (is DISPLAY or WAYLAND_DISPLAY set?)")
  var x11Type: proc(): uint {.cdecl.}
  b.onX11 = bindFunc(libGDK, cast[ptr pointer](addr x11Type),
    "gdk_x11_display_get_type") and
    gTypeCheckInstanceIsA(gdkDisplayGetDefault(), x11Type()) and
    bindFunc(libGDK, cast[ptr pointer](addr b.wmName),
      "gdk_x11_screen_get_window_manager_name")
  # GTK has the compositor's default decoration mode once the display
  # is open, and decides with it which windows it decorates.
  var waylandType: proc(): uint {.cdecl.}
  var prefersSSD: proc(display: pointer): bool {.cdecl.}
  let onWayland = bindFunc(libGDK,
    cast[ptr pointer](addr waylandType),
    "gdk_wayland_display_get_type") and
    gTypeCheckInstanceIsA(gdkDisplayGetDefault(), waylandType())
  b.compositorDecorates = onWayland and
    bindFunc(libGDK, cast[ptr pointer](addr prefersSSD),
      "gdk_wayland_display_prefers_ssd") and
    prefersSSD(gdkDisplayGetDefault())
  if onWayland:
    discard bindFunc(libGDK, cast[ptr pointer](addr b.announceCSD),
      "gdk_wayland_window_announce_csd")
  initCallbacks()

method run*(b: Backend) =
  b.running = true
  discard gIdleAddFull(0, readyCallback, nil, nil)
  gtkMain()
  b.running = false

method quit*(b: Backend) =
  # Dialogs and popups run nested main loops, which gtk_main_quit does
  # not end: dismiss them so gtk_main can return.
  for m in b.modals:
    if m.native:
      gtkNativeDialogHide(m.dialog)
    else:
      gtkWidgetHide(m.dialog)
  for l in b.quitLoops:
    gMainLoopQuit(l)
  if b.running:
    gtkMainQuit()

## runDialog runs a GtkDialog (native false) or a GtkNativeDialog until
## it is answered, or dismissed by quit.
proc runDialog*(b: Backend, dlg: pointer, native: bool): int32 =
  b.modals.add modal(dialog: dlg, native: native)
  defer: b.modals.setLen(b.modals.len - 1)
  if native:
    return gtkNativeDialogRun(dlg)
  gtkDialogRun(dlg)

method signal*(b: Backend) =
  var prev = false
  if gIdleAddFull.isNil or not b.signaled.compareExchange(prev, true):
    return
  discard gIdleAddFull(0, dispatchCallback, nil, nil)

method step*(b: Backend) = discard gMainContextIteration(nil, true)

method wake*(b: Backend) =
  if not gMainContextWakeup.isNil:
    gMainContextWakeup(nil)

method app*(b: Backend): AppController = appController(b: b)
method dialogs*(b: Backend): Dialogs = dialogsImpl(b: b)
method clipboard*(b: Backend): Clipboard = clipboardImpl()
method shell*(b: Backend): Shell = shellImpl()
method screen*(b: Backend): Screen = screenImpl()
method theme*(b: Backend): Theme = themeImpl(b: b)
method power*(b: Backend): Power = powerImpl(b: b)
method secrets*(b: Backend): Secrets = secretsImpl()

# --- appController ---

method setActivationPolicy*(a: appController, p: string) = discard

method activate*(a: appController) =
  for w in a.b.windows.values:
    if gtkWidgetGetVisible(w.win):
      gtkWindowPresent(w.win)
      return

method hide*(a: appController) =
  for w in a.b.windows.values:
    gtkWidgetHide(w.win)

method unhide*(a: appController) =
  for w in a.b.windows.values:
    gtkWidgetShow(w.win)

method isHidden*(a: appController): bool = false

method setBadge*(a: appController, label: string) =
  a.b.launcher.badge = label
  a.b.updateLauncherEntry()

method badge*(a: appController): string = a.b.launcher.badge

method bounce*(a: appController, critical: bool): int =
  for w in a.b.windows.values:
    gtkWindowSetUrgencyHint(w.win, true)
  1

method cancelBounce*(a: appController, id: int) =
  for w in a.b.windows.values:
    gtkWindowSetUrgencyHint(w.win, false)

## setDockMenu does nothing: there is no Dock.
method setDockMenu*(a: appController, m: Menu) = discard

method setDockIcon*(a: appController, png: seq[byte]) =
  let (pix, err) = pixbufFromPNG(png)
  if not err.isNil:
    raise err
  defer: gObjectUnref(pix)
  gtkWindowSetDefaultIcon(pix)

method showAboutPanel*(a: appController, o: AboutPanelOptions) =
  let d = gtkAboutDialogNew()
  gtkAboutDialogSetProgramName(d, cs(o.applicationName))
  var version = o.applicationVersion
  if o.version != "":
    version &= " (" & o.version & ")"
  gtkAboutDialogSetVersion(d, optCS(version))
  gtkAboutDialogSetCopyright(d, optCS(o.copyright))
  gtkAboutDialogSetComments(d, optCS(o.credits))
  discard a.b.runDialog(d, false)
  gtkWidgetDestroy(d)

method `package`*(a: appController):
    tuple[info: PackageInfo, ok: bool] =
  (PackageInfo(), false)

method clearBrowsingData*(a: appController,
    done: proc(err: ref CatchableError)) =
  # Web views of earlier runs kept their data on disk: WebKitGTK
  # clears it, loaded for that when no window has shown a web page
  # yet.
  if not webKit().isNil:
    done(nil) # no web view kept any data
    return
  const all = (1 shl 14) - 1 # WEBKIT_WEBSITE_DATA_ALL
  let manager = webkitWebContextGetWebsiteDataManager(
    webkitWebContextGetDefault())
  let id = pending.add(proc(source, res: pointer) =
    var gerr: pointer
    discard webkitWebsiteDataManagerClearFinish(source, res, addr gerr)
    done(gErr(gerr)))
  webkitWebsiteDataManagerClear(manager, uint32(all), 0, nil, cbAsyncReady, id)

method addRecentDocument*(a: appController, path: string) =
  let uri = fileURI(path)
  if uri == "":
    raise newException(CatchableError,
      "mynim: cannot record " & path & " as a recent document")
  # GTK records the item asynchronously, under the application name,
  # so a failure to write the list is not reported here.
  if not gtkRecentManagerAddItem(gtkRecentManagerGetDefault(), cs(uri)):
    raise newException(CatchableError,
      "mynim: the recent files list refused " & path)

## clearRecentDocuments removes the items of the shared list that this
## application registered, including those of earlier runs, and leaves
## the other applications' items alone.
method clearRecentDocuments*(a: appController) =
  let m = gtkRecentManagerGetDefault()
  let name = gGetApplicationName()
  if name.isNil:
    return
  var uris: seq[string]
  let list = gtkRecentManagerGetItems(m)
  var node = list
  while not node.isNil:
    let info = field[pointer](node, 0)
    if gtkRecentInfoHasApplication(info, name):
      uris.add goStr(gtkRecentInfoGetURI(info))
    gtkRecentInfoUnref(info)
    node = field[pointer](node, 8)
  gListFree(list)
  for uri in uris:
    discard gtkRecentManagerRemoveItem(m, cs(uri), nil)

method setJumpListTasks*(a: appController, tasks: seq[JumpListTask]) =
  discard
