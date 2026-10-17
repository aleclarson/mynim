import std/[assertions, options, os, tables, times]

import mynim as core
import mynim/plugins/updater as updater
import mynim/plugins/updater/frontend as frontend
import mynim/plugins/updater/preferences as updaterPreferences
import mynim/plugins/updater/session as updaterSession

let now = fromUnix(1_797_277_200)
let interval = initDuration(hours = 24)

block public_import_surface:
  var strings = initTable[string, updater.Strings]()
  strings["en"] = updater.Strings(install: "Update now")
  let options = updater.Options(strings: strings)
  doAssert options.strings["en"].install == "Update now"
  let menu = core.newMenu([core.actionMenuItem("Check", proc() = discard)])
  doAssert menu.items().len == 1

block next_check_schedule:
  doAssert updater.nextCheck(none(Time), none(Time), interval, now) == now
  doAssert updater.nextCheck(some(now - initDuration(hours = 30)), none(Time),
    interval, now) == now - initDuration(hours = 6)
  doAssert updater.nextCheck(some(now + initDuration(hours = 2)), none(Time),
    interval, now) == now + interval
  doAssert updater.nextCheck(none(Time), some(now), interval, now) ==
    now + initDuration(hours = 1)

proc testDirectory(name: string): string =
  result = getTempDir() / ("mynim-updater-service-" & name & "-" &
    $getCurrentProcessId())
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc removeTestDirectory(directory: string) =
  if fileExists(directory / "updater.json"):
    removeFile(directory / "updater.json")
  if fileExists(directory / "updater.json.tmp"):
    removeFile(directory / "updater.json.tmp")
  if dirExists(directory):
    removeDir(directory)

block manual_up_to_date_check:
  let directory = testDirectory("current")
  defer: removeTestDirectory(directory)
  var checks = 0
  var changes = 0
  let hooks = updater.Hooks(
    enabled: proc(): bool = true,
    check: proc(cancelled: updater.Cancelled): updater.CheckResult =
      inc checks
      updater.CheckResult(),
    appName: proc(): string = "Mynim Test",
    appVersion: proc(): string = "1.0.0",
    isDevelopment: proc(): bool = false,
    locale: proc(): string = "en",
    stateDirectory: proc(): string = directory,
    show: proc(current: updaterSession.Session) =
      let view = current.current()
      for button in view.buttons:
        if button.action == frontend.Ok and not button.disabled:
          current.respond(view.prompt, button.action, false),
    postMain: proc(callback: proc() {.closure.}) = callback(),
    now: proc(): Time = now
  )
  let value = updater.newUpdater(updater.Options(), hooks)
  value.setAutomaticChecks(false)
  doAssert not value.automaticChecks()
  value.setAutomaticChecks(true)
  doAssert value.automaticChecks()
  let unsubscribe = value.onChange(proc() = inc changes)
  value.beginNow(true)
  unsubscribe()
  doAssert checks == 1
  doAssert changes == 1
  doAssert value.lastCheck().isSome

block skip_and_persist_preferences:
  let directory = testDirectory("skip")
  defer: removeTestDirectory(directory)
  var changed = 0
  let hooks = updater.Hooks(
    enabled: proc(): bool = true,
    check: proc(cancelled: updater.Cancelled): updater.CheckResult = updater.CheckResult(
      release: updater.Release(version: "2.0.0", notes: "- Change")),
    appName: proc(): string = "Mynim Test",
    appVersion: proc(): string = "1.0.0",
    isDevelopment: proc(): bool = false,
    locale: proc(): string = "en",
    stateDirectory: proc(): string = directory,
    show: proc(current: updaterSession.Session) =
      let view = current.current()
      for button in view.buttons:
        if button.action == frontend.Skip and not button.disabled:
          current.respond(view.prompt, button.action, true),
    postMain: proc(callback: proc() {.closure.}) = callback(),
    now: proc(): Time = now
  )
  let value = updater.newUpdater(updater.Options(), hooks)
  let unsubscribe = value.onChange(proc() = inc changed)
  value.beginNow(true)
  unsubscribe()
  doAssert changed == 2
  doAssert value.automaticDownloads()
  let saved = updaterPreferences.newPreferencesStore(
    directory / "updater.json").snapshot()
  doAssert saved.skippedVersion == "2.0.0"
  doAssert saved.automaticDownloads

block cancellation_reaches_active_check:
  let directory = testDirectory("cancel-check")
  defer: removeTestDirectory(directory)
  var active: updaterSession.Session
  var checkCancelled = false
  let hooks = updater.Hooks(
    enabled: proc(): bool = true,
    check: proc(cancelled: updater.Cancelled): updater.CheckResult =
      active.cancel()
      checkCancelled = cancelled()
      updater.CheckResult(error: newException(IOError, "cancelled")),
    appName: proc(): string = "Mynim Test",
    appVersion: proc(): string = "1.0.0",
    isDevelopment: proc(): bool = false,
    locale: proc(): string = "en",
    stateDirectory: proc(): string = directory,
    show: proc(current: updaterSession.Session) = active = current,
    now: proc(): Time = now
  )
  let value = updater.newUpdater(updater.Options(), hooks)
  value.beginNow(true)
  doAssert checkCancelled
  doAssert value.lastCheck().isNone

block cancellation_reaches_active_install:
  let directory = testDirectory("cancel-install")
  defer: removeTestDirectory(directory)
  var active: updaterSession.Session
  var installCancelled = false
  let hooks = updater.Hooks(
    enabled: proc(): bool = true,
    check: proc(cancelled: updater.Cancelled): updater.CheckResult =
      updater.CheckResult(release: updater.Release(version: "2.2.0",
        install: proc(progress: updater.Progress;
            cancelled: updater.Cancelled): ref CatchableError =
          active.cancel()
          installCancelled = cancelled()
          newException(IOError, "cancelled"))),
    appName: proc(): string = "Mynim Test",
    appVersion: proc(): string = "1.0.0",
    isDevelopment: proc(): bool = false,
    locale: proc(): string = "en",
    stateDirectory: proc(): string = directory,
    show: proc(current: updaterSession.Session) =
      active = current
      let view = current.current()
      for button in view.buttons:
        if button.action == frontend.Install:
          current.respond(view.prompt, button.action, false),
    now: proc(): Time = now
  )
  let value = updater.newUpdater(updater.Options(), hooks)
  value.beginNow(true)
  doAssert installCancelled

block background_auto_install_then_relaunch:
  let directory = testDirectory("install")
  defer: removeTestDirectory(directory)
  let store = updaterPreferences.newPreferencesStore(directory / "updater.json")
  doAssert store.update(proc(state: var updaterPreferences.Preferences) =
    state.automaticDownloads = true
  )
  var installs = 0
  var relaunched = false
  let hooks = updater.Hooks(
    enabled: proc(): bool = true,
    check: proc(cancelled: updater.Cancelled): updater.CheckResult = updater.CheckResult(
      release: updater.Release(version: "2.1.0", install:
        proc(progress: updater.Progress; cancelled: updater.Cancelled):
            ref CatchableError =
          inc installs
          if progress != nil:
            progress(100, 100)
          nil)),
    appName: proc(): string = "Mynim Test",
    appVersion: proc(): string = "1.0.0",
    isDevelopment: proc(): bool = false,
    locale: proc(): string = "en",
    stateDirectory: proc(): string = directory,
    show: proc(current: updaterSession.Session) =
      let view = current.current()
      for button in view.buttons:
        if button.action == frontend.Relaunch and not button.disabled:
          current.respond(view.prompt, button.action, true),
    relaunch: proc() = relaunched = true,
    postMain: proc(callback: proc() {.closure.}) = callback(),
    now: proc(): Time = now
  )
  let value = updater.newUpdater(updater.Options(), hooks)
  value.beginNow(false)
  doAssert installs == 1
  value.beginNow(true)
  doAssert relaunched
