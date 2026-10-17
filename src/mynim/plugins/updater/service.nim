## Update checks, saved choices, and the session that drives native UI.

import std/[locks, options, os, times, tables]

import mynim as core
import mynim/plugins/updater/frontend as frontend
import mynim/plugins/updater/preferences as preferences
import mynim/plugins/updater/session as session
import mynim/plugins/updater/texts as texts

type
  Progress* = proc(downloaded, total: int64) {.closure.}
  InstallProc* = proc(progress: Progress): ref CatchableError {.closure.}

  Release* = ref object
    version*, notes*: string
    install*: InstallProc

  CheckResult* = object
    release*: Release
    error*: ref CatchableError

  Options* = object
    interval*: Duration
    disableAutomaticChecks*: bool
    icon*: seq[byte]
    language*: string
    strings*: Table[string, texts.Strings]

  Hooks* = object
    enabled*: proc(): bool {.closure.}
    check*: proc(): CheckResult {.closure.}
    appName*: proc(): string {.closure.}
    appVersion*: proc(): string {.closure.}
    isDevelopment*: proc(): bool {.closure.}
    locale*: proc(): string {.closure.}
    stateDirectory*: proc(): string {.closure.}
    relaunch*: proc() {.closure.}
    show*: proc(value: session.Session) {.closure.}
    postMain*: proc(fn: proc() {.closure.}) {.closure.}
    now*: proc(): Time {.closure.}

  ChangeListener = tuple[id: uint64, fn: proc() {.closure.}]

  Updater* = ref object
    guard: Lock
    options: Options
    hooks: Hooks
    textReady: bool
    windowText: texts.Text
    store: preferences.PreferencesStore
    changes: seq[ChangeListener]
    nextChangeID, scheduleGeneration: uint64
    currentSession: session.Session
    installed: Release
    failed: Option[Time]
    deadline: Option[Time]
    running, started, stopping, starting, manualRequested: bool
    workerThread: Thread[Updater]

const
  defaultInterval = 24 * 60 * 60 * 1_000_000_000'i64
  firstCheckWait = 10 * 1_000_000_000'i64
  retryHour = 60 * 60 * 1_000_000_000'i64
  stateFile = "updater.json"

var
  activeGuard: Lock
  activeUpdater: Updater

activeGuard.initLock()

proc schedule(value: Updater)
proc offerRelaunch(value: Updater; current: session.Session; release: Release)
proc stop*(value: Updater)

proc defaultHooks(): Hooks =
  result.appName = proc(): string = core.app.name()
  result.appVersion = proc(): string = core.app.version()
  result.isDevelopment = proc(): bool = core.isDev()
  result.locale = proc(): string = core.app.locale()
  result.stateDirectory = proc(): string = core.app.path(core.pathUserData)
  result.relaunch = proc() = core.app.relaunch()
  result.show = proc(value: session.Session) = value.show()
  result.postMain = proc(fn: proc() {.closure.}) =
    core.app.whenReady(proc() = discard core.postMain(fn))
  result.now = proc(): Time = getTime()
  when defined(emscripten):
    result.enabled = proc(): bool = false
    result.check = proc(): CheckResult = CheckResult(error:
      newException(ValueError, "mynim: automatic updates are unavailable on web"))
  else:
    result.enabled = proc(): bool = core.Updater.enabled()
    result.check = proc(): CheckResult =
      let checked = core.Updater.check()
      if checked.err != nil:
        return CheckResult(error: checked.err)
      if checked.update.isNone:
        return CheckResult()
      let update = checked.update.get()
      CheckResult(release: Release(version: update.version, notes: update.notes,
        install: proc(progress: Progress): ref CatchableError =
          update.install(proc(downloaded, total: int64) =
            if progress != nil:
              progress(downloaded, total))))

proc newUpdater*(options: Options; hooks = Hooks()): Updater =
  ## Creates the updater state; setup and background checks start separately.
  var options = options
  if options.interval.inNanoseconds <= 0:
    options.interval = initDuration(nanoseconds = defaultInterval)
  var hooks = hooks
  let defaults = defaultHooks()
  if hooks.enabled == nil: hooks.enabled = defaults.enabled
  if hooks.check == nil: hooks.check = defaults.check
  if hooks.appName == nil: hooks.appName = defaults.appName
  if hooks.appVersion == nil: hooks.appVersion = defaults.appVersion
  if hooks.isDevelopment == nil: hooks.isDevelopment = defaults.isDevelopment
  if hooks.locale == nil: hooks.locale = defaults.locale
  if hooks.stateDirectory == nil: hooks.stateDirectory = defaults.stateDirectory
  if hooks.relaunch == nil: hooks.relaunch = defaults.relaunch
  if hooks.show == nil: hooks.show = defaults.show
  if hooks.postMain == nil: hooks.postMain = defaults.postMain
  if hooks.now == nil: hooks.now = defaults.now
  result = Updater(options: options, hooks: hooks)
  initLock(result.guard)

proc stateStore(value: Updater): preferences.PreferencesStore =
  acquire(value.guard)
  if value.store == nil:
    let directory = value.hooks.stateDirectory()
    value.store = preferences.newPreferencesStore(directory / stateFile)
  result = value.store
  release(value.guard)
  result.load()

proc text(value: Updater): texts.Text =
  acquire(value.guard)
  if not value.textReady:
    let locale = if value.options.language.len > 0:
        value.options.language
      else:
        value.hooks.locale()
    value.windowText = texts.newText(locale, value.options.strings)
    value.textReady = true
  result = value.windowText
  release(value.guard)

proc notifyChanged(value: Updater) =
  acquire(value.guard)
  var callbacks = newSeqOfCap[proc() {.closure.}](value.changes.len)
  for listener in value.changes:
    callbacks.add(listener.fn)
  release(value.guard)
  if callbacks.len > 0:
    value.hooks.postMain(proc() =
      for callback in callbacks:
        callback()
    )

proc updatePreferences(value: Updater;
    change: proc(state: var preferences.Preferences) {.closure.}): bool =
  result = value.stateStore().update(change)
  if result:
    value.notifyChanged()

proc automaticChecks*(value: Updater): bool =
  value.stateStore().snapshot().automaticChecks(
    value.options.disableAutomaticChecks)

proc automaticDownloads*(value: Updater): bool =
  value.stateStore().snapshot().automaticDownloads

proc lastCheck*(value: Updater): Option[Time] =
  value.stateStore().snapshot().lastCheck

proc setAutomaticChecks*(value: Updater; enabled: bool) =
  discard value.updatePreferences(proc(state: var preferences.Preferences) =
    state.automaticChecks = some(enabled)
  )
  value.schedule()

proc setAutomaticDownloads*(value: Updater; enabled: bool) =
  discard value.updatePreferences(proc(state: var preferences.Preferences) =
    state.automaticDownloads = enabled
  )

proc onChange*(value: Updater; callback: proc() {.closure.}): proc() {.closure.} =
  if value == nil or callback == nil:
    return proc() = discard
  acquire(value.guard)
  inc value.nextChangeID
  let id = value.nextChangeID
  value.changes.add((id, callback))
  release(value.guard)
  result = proc() =
    acquire(value.guard)
    for i in countdown(value.changes.high, 0):
      if value.changes[i].id == id:
        value.changes.delete(i)
        break
    release(value.guard)

proc nextCheck*(last, failed: Option[Time]; interval: Duration;
                now: Time): Time =
  ## Computes the next background check, including the capped failure retry.
  var due = now
  if last.isSome:
    let checkedAt = last.get()
    due = (if checkedAt > now: now else: checkedAt) + interval
  if failed.isSome:
    let retryInterval = min(interval.inNanoseconds, retryHour)
    let retryAt = failed.get() + initDuration(nanoseconds = retryInterval)
    if retryAt > due:
      due = retryAt
  due

proc schedule(value: Updater) =
  acquire(value.guard)
  inc value.scheduleGeneration
  let generation = value.scheduleGeneration
  release(value.guard)

  let state = value.stateStore().snapshot()
  let enabled = value.hooks.enabled() and
    state.automaticChecks(value.options.disableAutomaticChecks)
  acquire(value.guard)
  if generation != value.scheduleGeneration:
    release(value.guard)
    return
  if not value.running or value.stopping or value.starting or
      value.currentSession != nil or value.installed != nil or not enabled:
    value.deadline = none(Time)
  else:
    let now = value.hooks.now()
    let due = nextCheck(state.lastCheck, value.failed, value.options.interval, now)
    var delay = (due - now).inNanoseconds
    if delay < firstCheckWait:
      delay = firstCheckWait
    value.deadline = some(now + initDuration(nanoseconds = delay))
  release(value.guard)

proc checked(value: Updater; error: ref CatchableError) =
  if error != nil:
    acquire(value.guard)
    value.failed = some(value.hooks.now())
    release(value.guard)
    return
  acquire(value.guard)
  value.failed = none(Time)
  release(value.guard)
  let checkedAt = value.hooks.now()
  discard value.updatePreferences(proc(state: var preferences.Preferences) =
    state.lastCheck = some(checkedAt)
  )

proc install(value: Updater; current: session.Session; release: Release) =
  let windowText = value.text()
  current.setView(windowText.downloadingView(0, 0))
  let error = if release.install == nil:
      newException(ValueError, "updater: release has no install operation")
    else:
      release.install(proc(downloaded, total: int64) =
        if current.isEnded():
          return
        if downloaded < total:
          current.setView(windowText.downloadingView(downloaded, total))
        else:
          current.setView(windowText.installingView())
      )
  if current.isEnded():
    return
  if error != nil:
    if current.user() or current.isShown():
      current.setView(windowText.errorView(windowText.strings.installError, error))
      value.hooks.show(current)
      discard current.wait()
    return
  acquire(value.guard)
  value.installed = release
  release(value.guard)
  if current.user() or current.isShown():
    value.offerRelaunch(current, release)

proc offerRelaunch(value: Updater; current: session.Session; release: Release) =
  let windowText = value.text()
  current.setView(windowText.readyView(value.hooks.appName(), release.version))
  value.hooks.show(current)
  if current.wait().action == frontend.Relaunch:
    value.hooks.relaunch()

proc run(value: Updater; current: session.Session) =
  let windowText = value.text()
  if not value.hooks.enabled():
    current.setView(windowText.unavailableView(value.hooks.appName(),
      value.hooks.isDevelopment()))
    value.hooks.show(current)
    discard current.wait()
    return

  acquire(value.guard)
  let installed = value.installed
  release(value.guard)
  if installed != nil:
    value.offerRelaunch(current, installed)
    return

  current.setView(windowText.checkingView())
  if current.user():
    value.hooks.show(current)
  let checked = value.hooks.check()
  if current.isEnded():
    return
  value.checked(checked.error)
  if checked.error != nil:
    if current.user():
      current.setView(windowText.errorView(windowText.strings.checkError,
        checked.error))
      value.hooks.show(current)
      discard current.wait()
    return
  if checked.release == nil:
    if current.user():
      current.setView(windowText.upToDateView(value.hooks.appName(),
        value.hooks.appVersion()))
      value.hooks.show(current)
      discard current.wait()
    return

  let saved = value.stateStore().snapshot()
  if not current.user():
    if saved.skippedVersion == checked.release.version:
      return
    if saved.automaticDownloads:
      value.install(current, checked.release)
      return
  current.setView(windowText.availableView(value.hooks.appName(),
    checked.release.version, value.hooks.appVersion(), checked.release.notes,
    saved.automaticDownloads))
  value.hooks.show(current)
  let answer = current.wait()
  if answer.action == frontend.Close:
    return
  discard value.updatePreferences(proc(state: var preferences.Preferences) =
    state.automaticDownloads = answer.automaticDownloads
    if answer.action == frontend.Skip:
      state.skippedVersion = checked.release.version
  )
  if answer.action == frontend.Install:
    value.install(current, checked.release)

proc endSession(value: Updater; current: session.Session) =
  acquire(value.guard)
  if value.currentSession == current:
    value.currentSession = nil
  release(value.guard)
  current.close()
  value.schedule()

proc beginSession(value: Updater; user: bool) =
  var current: session.Session
  let frontendTexts = value.text().frontendTexts()
  acquire(value.guard)
  if value.stopping:
    value.starting = false
    release(value.guard)
    return
  if value.currentSession != nil:
    current = value.currentSession
    value.starting = false
    release(value.guard)
    if user:
      current.promote()
    return
  current = session.newSession(frontendTexts, user)
  value.currentSession = current
  value.starting = false
  value.deadline = none(Time)
  release(value.guard)
  try:
    value.run(current)
  finally:
    value.endSession(current)

proc worker(value: Updater) {.thread.} =
  {.cast(gcsafe).}:
    while true:
      var stop, startRun, promote: bool
      var current: session.Session
      var user = false
      acquire(value.guard)
      stop = value.stopping
      if not stop and value.manualRequested:
        value.manualRequested = false
        if value.currentSession != nil:
          current = value.currentSession
          promote = true
        elif not value.starting:
          value.starting = true
          startRun = true
          user = true
        else:
          value.manualRequested = true
      elif not stop and value.deadline.isSome and
          value.hooks.now() >= value.deadline.get() and not value.starting:
        value.deadline = none(Time)
        value.starting = true
        startRun = true
      release(value.guard)
      if stop:
        break
      if promote:
        current.promote()
      elif startRun:
        value.beginSession(user)
      else:
        sleep(100)

proc start*(value: Updater) =
  ## Starts the serialized updater worker after the app is ready.
  if value == nil:
    return
  discard value.stateStore()
  acquire(value.guard)
  if value.started or value.stopping:
    release(value.guard)
    return
  value.started = true
  value.running = true
  release(value.guard)
  createThread(value.workerThread, worker, value)
  value.schedule()
  discard core.power.onResume(proc() = value.schedule())
  discard core.app.onWillQuit(proc(event: var core.QuitEvent) = value.stop())

proc stop*(value: Updater) =
  ## Stops future checks and cancels the session during app shutdown.
  if value == nil:
    return
  acquire(value.guard)
  value.stopping = true
  value.deadline = none(Time)
  let current = value.currentSession
  release(value.guard)
  if current != nil:
    current.cancel()

proc requestCheck*(value: Updater) =
  ## Starts a user-requested check or promotes the check already in progress.
  if value == nil:
    return
  acquire(value.guard)
  let current = value.currentSession
  if current == nil:
    value.manualRequested = true
  release(value.guard)
  if current != nil:
    current.promote()

proc beginNow*(value: Updater; user: bool) =
  ## Runs one check synchronously; exposed for deterministic service tests.
  value.beginSession(user)

proc makePlugin*(options: Options): core.Plugin =
  ## Creates the native updater plugin with custom options.
  let value = newUpdater(options)
  result = core.Plugin(name: "updater", setup: proc(): ref CatchableError =
    let invalid = texts.validateStrings(value.options.strings)
    if invalid.len > 0:
      return newException(ValueError, invalid)
    activeGuard.acquire()
    if activeUpdater != nil:
      activeGuard.release()
      return newException(ValueError, "another updater plugin is used")
    activeUpdater = value
    activeGuard.release()
    core.app.whenReady(proc() = value.start())
    nil
  )

proc `new`*(options: Options): core.Plugin = makePlugin(options)

let Plugin* = makePlugin(Options())

proc used(): Updater =
  activeGuard.acquire()
  result = activeUpdater
  activeGuard.release()
  if result == nil:
    raise newException(ValueError,
      "updater: the plugin is not used: call use(Plugin) before app.run")

proc checkForUpdates*() =
  ## Checks for updates as the user asked, showing the native window.
  used().requestCheck()

proc menuItem*(): core.MenuItem =
  ## Returns a menu item that starts or promotes a user-requested check.
  let value = used()
  core.actionMenuItem(value.text().strings.menuItem,
    proc() = value.requestCheck())

proc automaticChecks*(): bool = used().automaticChecks()
proc setAutomaticChecks*(enabled: bool) = used().setAutomaticChecks(enabled)
proc automaticDownloads*(): bool = used().automaticDownloads()
proc setAutomaticDownloads*(enabled: bool) =
  used().setAutomaticDownloads(enabled)
proc lastCheck*(): Option[Time] = used().lastCheck()
proc onChange*(callback: proc() {.closure.}): proc() {.closure.} =
  used().onChange(callback)
