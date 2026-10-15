## deeplink.go — URL schemes and files passed to the application.

const
  ## Set by the app build from mynim.config.ts for schemes and file
  ## associations that are part of the package.
  packageURLSchemes {.strdefine.} = ""
  packageFileExtensions {.strdefine.} = ""

var registeredSchemes = block:
  var s: tuple[mu: Lock, values: HashSet[string]]
  s.mu.initLock()
  s.values = initHashSet[string]()
  s

var launchState = block:
  var s: tuple[mu: Lock, done: bool, fns: seq[proc() {.closure.}]]
  s.mu.initLock()
  s

proc packageSchemes(): seq[string] =
  for scheme in packageURLSchemes.split(','):
    let normalized = scheme.strip().toLowerAscii()
    if normalized != "":
      result.add normalized

proc packageExtensions(): seq[string] =
  for extension in packageFileExtensions.split(','):
    let normalized = extension.strip().strip(chars = {'.'}).toLowerAscii()
    if normalized != "":
      result.add normalized

proc schemeSnapshot(): seq[string] =
  result = packageSchemes()
  registeredSchemes.mu.acquire()
  for scheme in registeredSchemes.values:
    result.add scheme
  registeredSchemes.mu.release()

proc deliverArgs(args: openArray[string]; workingDir: string) =
  for url in launchargs.urlArgs(args, schemeSnapshot()):
    fire1(app.onOpenURL, url)
  for path in launchargs.fileArgs(args, workingDir, packageExtensions()):
    fire1(app.onOpenFile, path)

proc launchArgs() =
  ## Delivers startup arguments after app readiness, then releases any
  ## work waiting for that delivery to finish.
  when defined(emscripten):
    let args: seq[string] = @[]
  else:
    let args = commandLineParams()
  deliverArgs(args, startDir)

  launchState.mu.acquire()
  launchState.done = true
  let fns = launchState.fns
  launchState.fns = @[]
  launchState.mu.release()
  for fn in fns:
    fn()

proc whenLaunched(fn: proc() {.closure.}) =
  ## Runs fn on the main thread once startup arguments were delivered.
  launchState.mu.acquire()
  if not launchState.done:
    launchState.fns.add fn
    launchState.mu.release()
    return
  launchState.mu.release()
  discard postMain(fn)

proc registerURLScheme*(a: Application; scheme: string): ref CatchableError =
  ## Registers this app to receive URLs using scheme. Call before app.run.
  if not launchargs.isURLScheme(scheme):
    return newException(ValueError,
      "mynim: invalid URL scheme " & scheme.escape())

  let scheme = scheme.toLowerAscii()
  registeredSchemes.mu.acquire()
  registeredSchemes.values.incl scheme
  registeredSchemes.mu.release()

  let id = appID()
  let name = a.name()
  onMainValue(proc(): ref CatchableError =
    try:
      backend().app().registerURLScheme(scheme, id, name)
      nil
    except CatchableError as e:
      e)

proc unregisterURLScheme*(a: Application; scheme: string): ref CatchableError =
  ## Undoes registerURLScheme where the operating system allows it.
  if not launchargs.isURLScheme(scheme):
    return newException(ValueError,
      "mynim: invalid URL scheme " & scheme.escape())

  let scheme = scheme.toLowerAscii()
  registeredSchemes.mu.acquire()
  registeredSchemes.values.excl scheme
  registeredSchemes.mu.release()

  let id = appID()
  let name = a.name()
  onMainValue(proc(): ref CatchableError =
    try:
      backend().app().unregisterURLScheme(scheme, id, name)
      nil
    except CatchableError as e:
      e)

proc isURLSchemeRegistered*(a: Application; scheme: string): bool =
  ## Reports whether this app is the system handler for scheme.
  if not launchargs.isURLScheme(scheme):
    return false
  let scheme = scheme.toLowerAscii()
  let id = appID()
  let name = a.name()
  onMainValue(proc(): bool =
    backend().app().isURLSchemeRegistered(scheme, id, name))
