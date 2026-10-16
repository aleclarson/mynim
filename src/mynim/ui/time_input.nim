## Localized segmented input for a time of day.

type TimePatternPart = object
  field: char
  before: string

proc timeLayout(pattern: string): tuple[separator: string,
                                       periodFirst: bool] =
  var parts: seq[TimePatternPart]
  var literal = ""
  var quoted = false
  var i = 0
  while i < pattern.len:
    let ch = pattern[i]
    if ch == '\'':
      if i + 1 < pattern.len and pattern[i + 1] == '\'':
        literal.add '\''
        i += 2
      else:
        quoted = not quoted
        inc i
    elif not quoted and ch in {'a'..'z', 'A'..'Z'}:
      parts.add TimePatternPart(field: ch, before: literal)
      literal = ""
      inc i
      while i < pattern.len and pattern[i] == ch:
        inc i
    else:
      literal.add ch
      inc i

  var hourAt, minuteAt, periodAt = -1
  for index, part in parts:
    if hourAt < 0 and part.field in {'h', 'H', 'k', 'K'}:
      hourAt = index
    elif minuteAt < 0 and part.field == 'm':
      minuteAt = index
    elif periodAt < 0 and part.field in {'a', 'b', 'B'}:
      periodAt = index
  if hourAt >= 0 and minuteAt >= 0:
    result.separator = parts[minuteAt].before.replace("\u202f", " ")
  result.periodFirst = periodAt >= 0 and hourAt >= 0 and periodAt < hourAt

proc localizedTime(date: DateTime; hour, minute: int): DateTime =
  dateTime(date.year, date.month, date.monthday, hour, minute, date.second,
    date.nanosecond, date.timezone)

proc changedTime(date: DateTime; segment, amount, hourCycle: int): DateTime =
  var hour = date.hour
  var minute = date.minute
  case segment
  of 0:
    if hourCycle == 12:
      let displayed = (hour + 11) mod 12 + 1
      let next = (displayed - 1 + amount + 12) mod 12 + 1
      hour = (hour div 12) * 12 + next mod 12
    else:
      hour = (hour + amount + 24) mod 24
  of 1:
    minute = (minute + amount + 60) mod 60
  of 2:
    hour = if hour < 12: hour + 12 else: hour - 12
  else:
    discard
  localizedTime(date, hour, minute)

proc timeControlState(c: Context; identity: uint64): TimeControlState =
  result = c.owner.timeControlStates.getOrDefault(identity)
  if result == nil:
    new(result)
    c.owner.timeControlStates[identity] = result

proc syncTimeControl(state: TimeControlState; date: var DateTime;
                     changedElement: Element) =
  let before = date
  if state.hasPendingValue:
    date = state.pendingValue
    state.hasPendingValue = false
    if date != before:
      changedElement.markBoundValueChanged()
  elif not state.initialized or state.lastValue != date:
    state.digitBuffers = ["", "", ""]
  state.lastValue = date
  state.initialized = true

proc pendingTime(state: TimeControlState): DateTime =
  if state.hasPendingValue: state.pendingValue else: state.lastValue

proc queueTimeValue(state: TimeControlState; value: DateTime) =
  if value != state.pendingTime():
    state.pendingValue = value
    state.hasPendingValue = true

proc queueTimeStep(state: TimeControlState; segment, amount,
                   hourCycle: int) =
  state.digitBuffers[segment] = ""
  state.queueTimeValue(changedTime(state.pendingTime(), segment, amount,
    hourCycle))

proc queueTimeDigit(c: Context; state: TimeControlState; segment, digit,
                    hourCycle: int) =
  let now = getMonoTime()
  var typed = state.digitBuffers[segment]
  if typed.len == 0 or now - state.digitAt[segment] > initDuration(seconds = 1):
    typed = $digit
  else:
    typed.add $digit
  state.digitAt[segment] = now

  let top = if segment == 0 and hourCycle == 12: 13
    elif segment == 0: 24
    else: 60
  var value = parseInt(typed)
  if typed.len > 2 or value >= top:
    typed = $digit
    value = digit
  state.digitBuffers[segment] = typed

  if not (segment == 0 and hourCycle == 12 and value == 0 and
      typed.len == 1):
    let base = state.pendingTime()
    let hour = if segment == 0:
        (if hourCycle == 12: (base.hour div 12) * 12 + value mod 12
         else: value)
      else: base.hour
    let minute = if segment == 1: value else: base.minute
    state.queueTimeValue(localizedTime(base, hour, minute))

  if typed.len >= 2 or value * 10 >= top:
    state.digitBuffers[segment] = ""
    if segment == 0:
      state.segmentHandles[1].focus(c)

proc timeDigitAction(c: Context; state: TimeControlState; segment, digit,
                     hourCycle: int): proc() {.closure.} =
  result = proc() = c.queueTimeDigit(state, segment, digit, hourCycle)

proc timeSegment(c: Context; state: TimeControlState;
                 segment, position: int; order: seq[int]; hourCycle: int;
                 locale: string; am, pm: string; value: DateTime): Element =
  let theme = c.theme
  let texts = l10n.`in`(c.localeTag)
  result = c.box().padding(0, theme.space(0.5)).radius(theme.space(1))
    .focusable().focusRing(false)
  let element = result
  discard element.bindHandle(state.segmentHandles[segment])
  let node = element.node
  if node == nil:
    return
  node[].accessRole = platform.roleStepper
  node[].accessRoleSet = true
  node[].accessLabelFromParent = true
  let hourValue = if hourCycle == 12: (value.hour + 11) mod 12 + 1
    else: value.hour
  var text, label: string
  case segment
  of 0:
    label = texts.hours()
    text = i18n.formatInteger(locale, hourValue,
      if hourCycle == 24: 2 else: 1)
    node[].hasAccessRange = true
    node[].accessMin = if hourCycle == 12: 1 else: 0
    node[].accessMax = if hourCycle == 12: 12 else: 23
    node[].accessNow = hourValue.float64
  of 1:
    label = texts.minutes()
    text = i18n.formatInteger(locale, value.minute.int, 2)
    node[].hasAccessRange = true
    node[].accessMin = 0
    node[].accessMax = 59
    node[].accessNow = value.minute.int.float64
  else:
    label = texts.dayPeriod()
    text = if value.hour < 12: am else: pm
    node[].accessValue = text
  node[].label = label
  node[].accessValue = text
  node[].accessStep = 1
  node[].accessStepHandler = proc(delta: float64) =
    state.queueTimeStep(segment, if delta > 0: 1 else: -1, hourCycle)
  if element.focused():
    discard element.background(theme.accent).textColor(theme.accentText)
  discard element.children(proc() =
    discard c.text(text)
  )

  discard element.onShortcut(0, platform.keyUp, proc() =
    state.queueTimeStep(segment, 1, hourCycle)
  )
  discard element.onShortcut(0, platform.keyDown, proc() =
    state.queueTimeStep(segment, -1, hourCycle)
  )
  if position > 0:
    let previous = order[position - 1]
    discard element.onShortcut(0, platform.keyLeft, proc() =
      state.digitBuffers[segment] = ""
      state.segmentHandles[previous].focus(c)
    )
  if position + 1 < order.len:
    let next = order[position + 1]
    discard element.onShortcut(0, platform.keyRight, proc() =
      state.digitBuffers[segment] = ""
      state.segmentHandles[next].focus(c)
    )

  if segment < 2:
    const digitKeys = [platform.key0, platform.key1, platform.key2,
      platform.key3, platform.key4, platform.key5, platform.key6,
      platform.key7, platform.key8, platform.key9]
    for digit, key in digitKeys:
      discard element.onShortcut(0, key,
        timeDigitAction(c, state, segment, digit, hourCycle))
  elif segment == 2:
    discard element.onShortcut(0, platform.keyA, proc() =
      let current = state.pendingTime()
      if current.hour >= 12:
        state.queueTimeValue(changedTime(current, 2, 0, hourCycle))
    )
    discard element.onShortcut(0, platform.keyP, proc() =
      let current = state.pendingTime()
      if current.hour < 12:
        state.queueTimeValue(changedTime(current, 2, 0, hourCycle))
    )

proc timeInput*(c: Context; date: var DateTime): Element =
  ## Edits the time of day in the user's preferred hour cycle and locale.
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    raise newException(ValueError, "ui: time input must be built in a frame")
  let theme = c.theme
  let valuePtr = addr date
  result = c.row().alignItems(Align.Center).padding(theme.space(1.5))
    .radius(theme.radius).background(theme.surface).border(1, theme.border)
    .shrink(0).direction(LeftToRight)
  let root = result
  let node = root.node
  if node == nil:
    return
  node[].timeControlRoot = true
  node[].accessRole = platform.roleGroup
  node[].accessRoleSet = true
  let state = c.timeControlState(node[].identity)
  state.syncTimeControl(valuePtr[], root)

  let locale = i18n.formatLocale(c.region, c.localeTag)
  let hourCycle = if c.region.hourCycle == 12: 12 else: 24
  let pattern = i18n.timePattern(locale, hourCycle)
  let layout = timeLayout(pattern)
  let (am, pm) = i18n.dayPeriods(locale, i18n.nameAbbreviated)
  let order = if hourCycle == 12 and layout.periodFirst:
      @[2, 0, 1]
    elif hourCycle == 12:
      @[0, 1, 2]
    else:
      @[0, 1]
  let currentValue = valuePtr[]
  var segments: array[3, Element]
  discard root.children(proc() =
    for position, segment in order:
      if segment == 1:
        let separator = c.text(layout.separator).textColor(theme.textMuted)
          .padding(0, theme.space(1))
        if separator.node != nil:
          separator.node[].accessHidden = true
      elif position > 0:
        discard c.box().width(theme.space(1))
      segments[segment] = c.timeSegment(state, segment, position,
        order, hourCycle, locale, am, pm, currentValue)
    if segments[0].focused() or segments[1].focused() or
        (hourCycle == 12 and segments[2].focused()):
      discard root.border(1, theme.accent)
  )
