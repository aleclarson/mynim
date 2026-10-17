import std/[assertions, json, options, os, strutils, times]

import mynim/plugins/updater/preferences as updaterPreferences

let checkedAt = fromUnix(1_797_277_200) + initDuration(nanoseconds = 123_456_789)

block json_round_trip:
  let value = updaterPreferences.Preferences(
    automaticChecks: some(false), automaticDownloads: true,
    skippedVersion: "2.0.0", lastCheck: some(checkedAt))
  let encoded = updaterPreferences.encode(value)
  doAssert "\"automaticChecks\":false" in encoded
  doAssert "\"automaticDownloads\":true" in encoded
  doAssert "\"skippedVersion\":\"2.0.0\"" in encoded
  doAssert "\"lastCheck\":\"" in encoded
  doAssert updaterPreferences.decode(encoded).same(value)

  doAssert updaterPreferences.encode(updaterPreferences.Preferences()) == "{}"
  let disabled = updaterPreferences.Preferences(automaticChecks: some(false))
  doAssert updaterPreferences.encode(disabled) == "{\"automaticChecks\":false}"
  let millisecond = updaterPreferences.Preferences(
    lastCheck: some(fromUnix(100) + initDuration(milliseconds = 123)))
  doAssert "1970-01-01T00:01:40.123Z" in updaterPreferences.encode(millisecond)

block read_go_timestamps:
  let fromGo = updaterPreferences.decode(
    """{"lastCheck":"2026-10-17T18:00:00.123456789-04:00"}""")
  doAssert fromGo.lastCheck.isSome
  doAssert fromGo.lastCheck.get().utc.format(
    "yyyy-MM-dd'T'HH:mm:ss'.'fffffffff'Z'") == "2026-10-17T22:00:00.123456789Z"
  let wholeSecond = updaterPreferences.decode(
    """{"lastCheck":"2026-10-17T22:00:00Z"}""")
  doAssert wholeSecond.lastCheck.isSome
  doAssert updaterPreferences.decode("not json").same(
    updaterPreferences.Preferences())

block store_persistence:
  let directory = getTempDir() / ("mynim-updater-preferences-" &
    $getCurrentProcessId())
  if dirExists(directory):
    removeDir(directory)
  createDir(directory)
  let file = directory / "updater.json"
  defer:
    if fileExists(file): removeFile(file)
    if fileExists(file & ".tmp"): removeFile(file & ".tmp")
    removeDir(directory)
  let store = updaterPreferences.newPreferencesStore(file)
  doAssert store.snapshot().automaticChecks.isNone
  doAssert store.update(proc(value: var updaterPreferences.Preferences) =
    value.automaticChecks = some(true)
    value.automaticDownloads = true
    value.skippedVersion = "2.1.0"
    value.lastCheck = some(checkedAt)
  )
  doAssert fileExists(file)
  doAssert not fileExists(file & ".tmp")
  doAssert parseJson(readFile(file)).kind == JObject
  doAssert not store.update(proc(value: var updaterPreferences.Preferences) =
    value.automaticChecks = some(true)
  )

  let reloaded = updaterPreferences.newPreferencesStore(file).snapshot()
  doAssert reloaded.same(store.snapshot())
  doAssert reloaded.automaticChecks(true)

block damaged_file:
  let directory = getTempDir() / ("mynim-updater-preferences-bad-" &
    $getCurrentProcessId())
  if dirExists(directory):
    removeDir(directory)
  createDir(directory)
  let file = directory / "updater.json"
  defer:
    if fileExists(file): removeFile(file)
    removeDir(directory)
  writeFile(file, "{ damaged")
  let store = updaterPreferences.newPreferencesStore(file)
  doAssert store.snapshot().same(updaterPreferences.Preferences())
  doAssert store.update(proc(value: var updaterPreferences.Preferences) =
    value.skippedVersion = "2.0.0"
  )
