## pending.nim — stubs for forward declarations whose Go counterparts
## live in files not yet ported. Each stub names the file that will own
## it; the stub goes away when that part lands. Stubs return empty
## values rather than raising so callers compile and keep semantics
## reasonable (a stub that "did nothing" is closer to right than one
## that crashes the app mid-port).

## --- menu internals used by fwd.nim ---

proc menuItemByID(id: int): MenuItem = lookupMenuItem(id)

## --- cookies.nim ---

proc stopCookieCalls() =
  ## pending: cookies.go
  discard

## --- login.go / updater.go / deeplink.go / tsgen.go / watch.go ---

proc packageInfo(): tuple[info: platform.PackageInfo, ok: bool] =
  ## pending: login.go — reads the platform's package metadata.
  (platform.PackageInfo(), false)

proc quitOnSignals() =
  ## pending: signals.go — quits the app on SIGINT/SIGTERM.
  discard

proc cleanUpdateLeftovers() {.gcsafe.} =
  ## pending: updater.go — removes files a previous update left.
  discard

proc relaunchNow() =
  ## pending: updater.go — relaunches the app after an update.
  discard

proc launchArgs() =
  ## pending: deeplink.go — delivers a deep link the OS launched with.
  discard

proc writeTypeScript*(outPath: string) =
  ## pending: tsgen.go — generates the TypeScript client for bound
  ## methods and events.
  raise errUnsupported()

proc randomText*(): string =
  ## pending: used by tsgen.go and window secrets in the Go source;
  ## here it generates unguessable tokens.
  var b: array[16, byte]
  for i in 0 ..< b.len:
    b[i] = byte(rand(256))
  const hex = "0123456789abcdef"
  result = newString(32)
  for i, v in b:
    result[2*i] = hex[v.int shr 4]
    result[2*i+1] = hex[v.int and 15]

proc stopFileWatches() =
  ## pending: watch.go — stops fsnotify watchers on quit.
  discard
