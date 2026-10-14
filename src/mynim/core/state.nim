## state.nim — the package-level mutable state the parts share, mirroring
## the Go package's globals. Declared here so every part sees them
## regardless of include order (Nim has no forward declarations for
## vars).

var
  ## The singleton modules.
  shell* {.global.}: ShellModule
  clipboard* {.global.}: ClipboardModule
  secrets* {.global.}: SecretsModule
  screen* {.global.}: ScreenModule
  theme* {.global.}: ThemeModule
  globalShortcut* {.global.}: GlobalShortcutModule
  network* {.global.}: NetworkModule
  power* {.global.}: PowerModule
  protocol* {.global.}: ProtocolModule
  app* {.global.}: Application

## errLoopStopped is what calls after the event loop stopped get.
var errLoopStopped* = newException(ValueError,
  "mynim: the event loop has stopped")

# Clipboard state is main-thread only. User release hooks are deferred
# until native callbacks unwind, including callbacks made during write
# itself.
var
  clipboardProviding*, clipboardStopped*: bool
  clipboardOperations*: int
  clipboardReleases*: seq[proc() {.closure.}]

## The registry of windows (Go: var windows struct{...}).
var windows* = block:
  var w: tuple[mu: Lock, nextID: int, list: seq[Window], focused: Window]
  w.mu.initLock()
  w

## closingParents tracks the windows closing because a parent is
## (window.nim's var closingParents).
var closingParents*: int

## locales is the locale state of the app (locale.nim's var locales).
var locales* = block:
  var l: LocaleState
  l.mu.initLock()
  l

## The registry of live notifications by ID.
var notifications* = block:
  var n: tuple[mu: Lock, byID: Table[string, Notification]]
  n.mu.initLock()
  n

## production is "1" when `mynim build` sets -d:production.
const isProduction* = defined(production) or defined(release)

## devLaunched tells that `mynim dev` launched the app, which it does
## with MYNIM_DEV=1: app.relaunch then has mynim dev start it again.
var devLaunched* = block:
  let set = getEnv("MYNIM_DEV", getEnv("MYGO_DEV")) == "1"
  delEnv("MYNIM_DEV")
  delEnv("MYGO_DEV")
  set and not isProduction

## openedAtLogin reports whether the arguments had the login arg
## (login.nim).
var openedAtLogin* = "--mygo-opened-at-login" in commandLineParams()

## startDir is the working directory the app started in.
var startDir* = getCurrentDir()

## The clipboard singleton is a pure marker object (methods on
## ClipboardModule); the singletons that carry state are refs.
screen = ScreenModule()
theme = ThemeModule()
globalShortcut = GlobalShortcutModule()
network = NetworkModule()
protocol = ProtocolModule()
protocol.mu.initLock()
app = Application()
app.dock = Dock()
app.readyCh.open()
