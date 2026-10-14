## Package unsupported is the backend for platforms without a native
## implementation. init fails, everything else is inert (the base methods
## of the platform interfaces already provide the inert behavior).

import platform
import ../transfer

type
  UnsupportedBackend* = ref object of Backend
    ## Reports that the platform is not supported.

  UnsupportedApp* = ref object of AppController
  UnsupportedDialogs* = ref object of Dialogs
  UnsupportedClipboard* = ref object of Clipboard
  UnsupportedShell* = ref object of Shell
  UnsupportedScreen* = ref object of Screen
  UnsupportedTheme* = ref object of Theme
  UnsupportedPower* = ref object of Power
  UnsupportedNetwork* = ref object of Network
  UnsupportedSecrets* = ref object of Secrets

proc platformUnsupported*(): ref PlatformError =
  ## "mynim: <os>/<arch> is not supported yet".
  newException(PlatformError,
               "mynim: " & hostOS & "/" & hostCPU & " is not supported yet")

proc newUnsupportedBackend*(): UnsupportedBackend = UnsupportedBackend()

method name*(b: UnsupportedBackend): string = "unsupported"
method init*(b: UnsupportedBackend, h: AppHandler, opts: AppOptions) =
  raise platformUnsupported()
method run*(b: UnsupportedBackend) =
  raise platformUnsupported()
method quit*(b: UnsupportedBackend) = discard
method isMainThread*(b: UnsupportedBackend): bool = true
method signal*(b: UnsupportedBackend) = discard
method step*(b: UnsupportedBackend) = discard
method wake*(b: UnsupportedBackend) = discard
method newWindow*(b: UnsupportedBackend, opts: WindowOptions,
                  h: WindowHandler): tuple[w: Window, err: ref CatchableError] =
  (nil, platformUnsupported())
method app*(b: UnsupportedBackend): AppController = UnsupportedApp()
method dialogs*(b: UnsupportedBackend): Dialogs = UnsupportedDialogs()
method clipboard*(b: UnsupportedBackend): Clipboard = UnsupportedClipboard()
method shell*(b: UnsupportedBackend): Shell = UnsupportedShell()
method screen*(b: UnsupportedBackend): Screen = UnsupportedScreen()
method theme*(b: UnsupportedBackend): Theme = UnsupportedTheme()
method power*(b: UnsupportedBackend): Power = UnsupportedPower()
method network*(b: UnsupportedBackend): Network = UnsupportedNetwork()
method secrets*(b: UnsupportedBackend): Secrets = UnsupportedSecrets()
method newTray*(b: UnsupportedBackend,
                h: TrayHandler): tuple[t: Tray, err: ref CatchableError] =
  (nil, platformUnsupported())
method notificationsSupported*(b: UnsupportedBackend): bool = false
method webViewSupported*(b: UnsupportedBackend): bool = false
method showNotification*(b: UnsupportedBackend, n: Notification,
                         done: proc(err: ref CatchableError)) =
  done(platformUnsupported())
method applications*(b: UnsupportedBackend):
    tuple[apps: seq[Application], err: ref CatchableError] =
  (@[], platformUnsupported())
method newFileWatch*(b: UnsupportedBackend, notify: proc(n: FileWatchNotice)):
    tuple[w: FileWatch, err: ref CatchableError] =
  (nil, errUnsupported())
method replaceFile*(b: UnsupportedBackend, target, replacement: string) =
  raise errUnsupported()

method preferredLanguages*(a: UnsupportedApp): seq[string] = @["en-US"]
method region*(a: UnsupportedApp): Region = Region(firstWeekday: -1)
method setDockIcon*(a: UnsupportedApp, png: seq[byte]) =
  raise platformUnsupported()
method clearBrowsingData*(a: UnsupportedApp,
                          done: proc(err: ref CatchableError)) =
  done(errUnsupported())
method addRecentDocument*(a: UnsupportedApp, path: string) =
  raise errUnsupported()
method clearRecentDocuments*(a: UnsupportedApp) =
  raise errUnsupported()
method listCookies*(a: UnsupportedApp,
    done: proc(c: seq[Cookie], err: ref CatchableError)) =
  done(@[], errUnsupported())
method setCookie*(a: UnsupportedApp, cookie: Cookie,
                  done: proc(err: ref CatchableError)) =
  done(errUnsupported())
method deleteCookie*(a: UnsupportedApp, key: CookieKey,
                     done: proc(err: ref CatchableError)) =
  done(errUnsupported())
method registerURLScheme*(a: UnsupportedApp, scheme, id, name: string) =
  raise platformUnsupported()
method unregisterURLScheme*(a: UnsupportedApp, scheme, id, name: string) =
  raise platformUnsupported()
method setOpenAtLogin*(a: UnsupportedApp, open: bool, id, name, arg: string) =
  raise platformUnsupported()
method setJumpListTasks*(a: UnsupportedApp, tasks: seq[JumpListTask]) =
  raise errUnsupported()

method showOpenDialog*(d: UnsupportedDialogs, parent: Window,
    opts: OpenDialogOptions, cb: proc(paths: seq[string], err: ref CatchableError)) =
  cb(@[], platformUnsupported())
method showSaveDialog*(d: UnsupportedDialogs, parent: Window,
    opts: SaveDialogOptions, cb: proc(path: string, err: ref CatchableError)) =
  cb("", platformUnsupported())
method showMessageBox*(d: UnsupportedDialogs, parent: Window,
    opts: MessageBoxOptions, cb: proc(res: MessageBoxResult, err: ref CatchableError)) =
  cb(MessageBoxResult(), platformUnsupported())

method readData*(c: UnsupportedClipboard, formats: seq[Format]):
    tuple[d: Data, err: ref CatchableError] =
  (Data(), platformUnsupported())
method writeData*(c: UnsupportedClipboard, data: Data, released: proc()) =
  released(); raise platformUnsupported()
method flush*(c: UnsupportedClipboard) =
  raise platformUnsupported()
method writeImage*(c: UnsupportedClipboard, png: seq[byte]) =
  raise platformUnsupported()

method openExternal*(s: UnsupportedShell, url: string): ref CatchableError =
  platformUnsupported()
method openPath*(s: UnsupportedShell, path: string) =
  raise platformUnsupported()
method trashItem*(s: UnsupportedShell, path: string) =
  raise platformUnsupported()
method fileIcon*(s: UnsupportedShell, path: string, size: int):
    tuple[png: seq[byte], err: ref CatchableError] =
  (@[], platformUnsupported())
method openApplication*(s: UnsupportedShell, path: string) =
  raise platformUnsupported()

method keepAwake*(p: UnsupportedPower, display: bool, reason: string): ReleaseProc =
  proc() = discard

method setSecret*(s: UnsupportedSecrets, service, account: string, secret: seq[byte]) =
  raise errUnsupported()
method secret*(s: UnsupportedSecrets, service, account: string):
    tuple[secret: seq[byte], err: ref CatchableError] =
  (@[], errUnsupported())
method deleteSecret*(s: UnsupportedSecrets, service, account: string) =
  raise errUnsupported()
