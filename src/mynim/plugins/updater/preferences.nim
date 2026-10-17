## Persistent updater choices stored in updater.json.

import std/[json, locks, options, os, strutils, times]

type
  Preferences* = object
    automaticChecks*: Option[bool]
    automaticDownloads*: bool
    skippedVersion*: string
    lastCheck*: Option[Time]

  PreferencesStore* = ref object
    guard: Lock
    file: string
    loaded: bool
    value: Preferences

proc isZero(time: Time): bool =
  let date = time.utc
  date.year == 1 and date.month == mJan and date.monthday == 1 and
    date.hour == 0 and date.minute == 0 and date.second == 0 and
    date.nanosecond == 0

proc timestamp(value: Time): string =
  result = value.utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fffffffff'Z'")
  var fractionEnd = result.len - 1
  while fractionEnd > 0 and result[fractionEnd - 1] == '0':
    dec fractionEnd
  if fractionEnd > 0 and result[fractionEnd - 1] == '.':
    dec fractionEnd
  result.setLen(fractionEnd)
  result.add('Z')

proc parseTimestamp(value: string): Option[Time] =
  try:
    let dot = value.find('.')
    if dot < 0:
      let date = parse(value, "yyyy-MM-dd'T'HH:mm:sszzz")
      let parsed = date.toTime
      if isZero(parsed): return none(Time)
      return some(parsed)

    var zone = value.find('Z')
    if zone < 0:
      for i in 19..<value.len:
        if value[i] in {'+', '-'}:
          zone = i
          break
    if zone <= dot + 1:
      return none(Time)
    let fraction = value[dot + 1..<zone]
    if fraction.len == 0 or fraction.len > 9:
      return none(Time)
    for ch in fraction:
      if ch notin {'0'..'9'}:
        return none(Time)
    let padded = value[0..<dot + 1] & fraction & repeat('0', 9 - fraction.len) &
      value[zone..^1]
    let date = parse(padded, "yyyy-MM-dd'T'HH:mm:ss'.'fffffffffzzz")
    let parsed = date.toTime
    if isZero(parsed): return none(Time)
    some(parsed)
  except CatchableError:
    none(Time)

proc encode*(value: Preferences): string =
  ## Encodes preferences with MyGo's JSON keys and omitempty behavior.
  var node = newJObject()
  if value.automaticChecks.isSome:
    node["automaticChecks"] = %value.automaticChecks.get()
  if value.automaticDownloads:
    node["automaticDownloads"] = %true
  if value.skippedVersion.len > 0:
    node["skippedVersion"] = %value.skippedVersion
  if value.lastCheck.isSome:
    let checkedAt = value.lastCheck.get()
    if not isZero(checkedAt):
      node["lastCheck"] = %timestamp(checkedAt)
  $node

proc decode*(data: string): Preferences =
  ## Decodes saved preferences; damaged or incompatible fields are ignored.
  try:
    let node = parseJson(data)
    if node.kind != JObject:
      return
    if node.hasKey("automaticChecks") and
        node["automaticChecks"].kind in {JBool, JNull}:
      if node["automaticChecks"].kind == JBool:
        result.automaticChecks = some(node["automaticChecks"].getBool())
    if node.hasKey("automaticDownloads") and
        node["automaticDownloads"].kind == JBool:
      result.automaticDownloads = node["automaticDownloads"].getBool()
    if node.hasKey("skippedVersion") and node["skippedVersion"].kind == JString:
      result.skippedVersion = node["skippedVersion"].getStr()
    if node.hasKey("lastCheck") and node["lastCheck"].kind == JString:
      result.lastCheck = parseTimestamp(node["lastCheck"].getStr())
  except CatchableError:
    discard

proc same*(left, right: Preferences): bool =
  ## Reports whether two preference values are equal.
  left.automaticChecks == right.automaticChecks and
    left.automaticDownloads == right.automaticDownloads and
    left.skippedVersion == right.skippedVersion and
    left.lastCheck == right.lastCheck

proc automaticChecks*(value: Preferences; disabledByDefault: bool): bool =
  ## Returns the saved choice or the configured default.
  if value.automaticChecks.isSome:
    value.automaticChecks.get()
  else:
    not disabledByDefault

proc newPreferencesStore*(file: string): PreferencesStore =
  ## Creates a lazy store for a preferences file path.
  result = PreferencesStore(file: file)
  initLock(result.guard)

proc load*(store: PreferencesStore) =
  ## Loads preferences once; malformed JSON leaves default choices in place.
  if store == nil:
    return
  acquire(store.guard)
  defer: release(store.guard)
  if store.loaded:
    return
  if store.file.len > 0:
    try:
      store.value = decode(readFile(store.file))
    except CatchableError:
      discard
  store.loaded = true

proc snapshot*(store: PreferencesStore): Preferences =
  ## Returns a lock-protected copy of the current choices.
  if store == nil:
    return
  store.load()
  acquire(store.guard)
  result = store.value
  release(store.guard)

proc saveLocked(store: PreferencesStore) =
  if store.file.len == 0:
    return
  let temporary = store.file & ".tmp"
  try:
    let directory = parentDir(store.file)
    if directory.len > 0:
      createDir(directory)
    writeFile(temporary, encode(store.value))
    moveFile(temporary, store.file)
  except CatchableError:
    try:
      if fileExists(temporary):
        removeFile(temporary)
    except CatchableError:
      discard

proc update*(store: PreferencesStore;
             change: proc(value: var Preferences) {.closure.}): bool =
  ## Applies a choice, saves it atomically, and reports whether it changed.
  if store == nil or change == nil:
    return false
  store.load()
  acquire(store.guard)
  defer: release(store.guard)
  let previous = store.value
  change(store.value)
  result = not store.value.same(previous)
  store.saveLocked()
