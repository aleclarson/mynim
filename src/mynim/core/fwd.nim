## Forward declarations of procs defined in parts that come later in
## the include order — the Go package's single scope cycles, and Nim
## needs a declaration before a call. Implementations live in the part
## that owns them; a stub in pending.nim marks what is not yet ported.

proc needsApp*(call: string)
proc waitReady(a: Application)

## windows.nim
proc menuItemClicked(id: int; win: Window)
proc top(w: Window): Window
proc pageWindows(): seq[Window]
proc windowHandler(w: Window): platform.WindowHandler
proc loadWindowStates()
proc onDisplay(r: Rectangle; displays: seq[platform.Display]): bool
proc focusedWindow*(): Window
proc allWindows*(): seq[Window]
proc saveWindowStates()
proc updateBackgrounds()
proc sendTitleBar(w: Window)
proc placeFlyouts(w: Window)
proc destroy*(w: Window)
proc close*(w: Window)
proc stateChanged(w: Window)
proc handleMessage(w: Window; msg0: string)
proc attachContent*(w: Window)
proc detachContent(w: Window)
proc startDataDrag(w: Window; data: Data; local: RootRef;
    options: DragOptions; x, y: float64): ref CatchableError
proc cancelDataDrag*(w: Window)
proc escape(w: Window)
proc appRightToLeft(): bool
proc isTrusted(w: Window; rawURL: string): bool
proc evalRaw(w: Window; ctx: CancelCtx; code: string):
  tuple[v: JsonNode, err: ref CatchableError]
proc sendPreferences()
proc contentThemeChanged()
proc contentLocaleChanged()

## menu.nim
proc defaultMenu(): Menu
proc menuItemByID(id: int): MenuItem
proc popupMenuAt(m: Menu; w: Window; pos: ref platform.Point;
    rtl: bool)

## ipc.nim / channel.nim
proc stopCookieCalls()
proc enqueue(w: Window; msg: Message; event: bool)
proc channel(w: Window; id: int64; token: string): ref ChannelObj
proc pageClosedChannel(w: Window; id: int64; token: string)
proc channelAck(c: ref ChannelObj; sq: int64)
proc channelClose(c: ref ChannelObj; by: int)
proc handleCall(w: Window; ctx: CancelCtx; raw: string; trusted: bool)
proc goAsync(fn: proc() {.closure.})

## document.nim / document_menu.nim / content.nim — used by menu.nim
## pending: document_menu.go — stubs until it is ported.
proc hasDocuments(): bool = false
proc documentRole(role: MenuRole; win: Window) =
  discard role
  discard win
proc recentMenuItems(): seq[MenuItem] = @[]
proc contentCommand(w: Window; cmd: string)

## app.nim / protocol.nim / modules.nim / menu.nim used by window.nim
## (later parts)
proc name*(a: Application): string
proc isReady*(a: Application): bool
proc openExternal*(s: ShellModule; url: string): ref CatchableError
proc snapshot*(m: Menu): platform.Menu
proc path*(a: Application; name: PathName): string
proc schemes*(p: ProtocolModule): seq[string]
proc isHandled*(p: ProtocolModule; scheme: string): bool
proc serve(p: ProtocolModule; w: Window; req: platform.SchemeRequest)

## window.nim operations used by ipc.nim's window-controls service
proc minimize*(w: Window)
proc maximize*(w: Window)
proc unmaximize*(w: Window)
proc toggleMaximize*(w: Window)
proc isMaximized*(w: Window): bool
proc toggleFullScreen*(w: Window)
proc setTitle*(w: Window; title: string)

## locale.nim / deeplink.nim / login.nim / updater.nim / frontend.nim
proc startLocale(a: Application)
proc localeChangedFromSystem(a: Application)
proc packageInfo(): tuple[info: platform.PackageInfo, ok: bool]
proc quitOnSignals()
proc cleanUpdateLeftovers() {.gcsafe.}
proc relaunchNow()
proc launchArgs()
proc writeTypeScript*(outPath: string)
proc randomText*(): string

## watch.nim
proc stopFileWatches()

## clipboard.nim
proc write*(c: ClipboardModule; data: Data;
            options: openArray[ClipboardOptions]): ref CatchableError
proc read*(c: ClipboardModule; formats: varargs[Format]):
  tuple[data: Data, err: ref CatchableError]
proc flush*(c: ClipboardModule): ref CatchableError

## same-part ordering and module internals used before their parts
proc finish(a: Application)
proc handleReady(a: Application)
proc notificationClicked(id: string)
proc apply(t: ThemeModule)
proc changed(t: ThemeModule)
proc changed(s: ScreenModule)
proc changed(n: NetworkModule; status: NetworkStatus)
proc pressed(g: GlobalShortcutModule; id: int)
proc event*(p: var PowerModule; event: string)

## Dock internals used before their definition in app.nim
proc menu*(d: Dock): Menu
proc setMenu*(d: Dock; m: Menu)
proc setBadge*(d: Dock; text: string)
proc networkStatus(s: platform.NetworkStatus): NetworkStatus
proc flush(w: Window)
proc resolveDataDrag(d: platform.DataDragEvent)
proc newMenu*(items: openArray[MenuItem]): Menu
proc contentMenu(m: platform.Menu; chosen: proc(id: int)): seq[MenuItem]
proc startDataDrag*(w: Window; data: Data; options: DragOptions):
    ref CatchableError
proc dragImage(img: image.Image): tuple[pix: seq[byte], w, h: int]
proc startDataDragPrepared(w: Window; data: Data; local: RootRef;
    options: DragOptions; x, y: float64; pix: seq[byte];
    width, height: int): ref CatchableError
proc lastWindowClosed(a: Application)
proc shownLocale(a: Application): ShownLocale
proc appLanguages(set: seq[string]): seq[string]
proc serveScheme(win: Window; h: HttpHandler; req: platform.SchemeRequest)
proc frontendHandler(): HttpHandler
proc validScheme(s: string): bool
proc appOrigin(origin: string): string
proc preferences*(t: ThemeModule): ThemePreferences
proc preferencesScript(): string
proc resolveLocale(override: string; preferred, supported: seq[string]): string
proc normalizeTags(tags: seq[string]): seq[string]
proc regionOf(r: platform.Region; preferred: seq[string]): i18n.Region
proc saveLocale(tag: string)
proc loadLocale()
proc missingTranslations(langs, translations,
    linked: seq[string]): seq[tuple[a, b: string]]
proc webLanguages(s: ShownLocale): seq[string]
proc savedLocale(): string
proc regionCode(tag: string): string
proc regionLocale(locale: string): string
proc readLocaleFile(): string
proc writeLocaleFile(tag: string)
proc defaultPath(name: PathName): tuple[path: string, create: bool]
proc platformTexts(locale: string): platform.Texts
proc relabelMenus()
