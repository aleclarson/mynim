## Localized calendar and date input controls.

proc sameCalendarDay(a, b: DateTime): bool =
  a.year == b.year and a.month == b.month and a.monthday == b.monthday

proc calendarDate(value: DateTime): DateTime =
  ## Keeps calendar arithmetic independent of daylight-saving transitions.
  dateTime(value.year, value.month, value.monthday, zone = utc())

proc selectedDate(base, day: DateTime): DateTime =
  ## Replaces only the calendar day, preserving the caller's wall time and zone.
  dateTime(day.year, day.month, day.monthday, base.hour, base.minute,
    base.second, base.nanosecond, base.timezone)

proc shiftCalendarMonth(value: DateTime; amount: int): DateTime =
  var year = value.year
  var month = int(value.month) + amount
  while month < 1:
    month += 12
    dec year
  while month > 12:
    month -= 12
    inc year
  let targetMonth = Month(month)
  dateTime(year, targetMonth, 1, zone = utc()) +
    initDuration(days = int(value.monthday) - 1)

proc firstCalendarDay(value: DateTime): DateTime =
  dateTime(value.year, value.month, 1, zone = utc())

proc lastCalendarDay(value: DateTime): DateTime =
  dateTime(value.year, value.month,
    getDaysInMonth(value.month, value.year), zone = utc())

proc calendarWeekdayIndex(day: WeekDay): int =
  case day
  of dSun: 0
  of dMon: 1
  of dTue: 2
  of dWed: 3
  of dThu: 4
  of dFri: 5
  of dSat: 6

proc syncDateControl(state: DateControlState; date: var DateTime;
                     changedElement: Element) =
  let before = date
  if state.hasPendingValue:
    date = state.pendingValue
    state.hasPendingValue = false
    if date != before:
      changedElement.markBoundValueChanged()
  if not state.initialized or not sameCalendarDay(state.lastValue, date):
    state.cursor = calendarDate(date)
  state.lastValue = date
  state.initialized = true

proc queueDateControlSelection(c: Context; state: DateControlState;
                               day: DateTime; moveChooses: bool) =
  state.cursor = calendarDate(day)
  state.pendingValue = selectedDate(state.lastValue, day)
  state.hasPendingValue = true
  if moveChooses:
    state.dayHandle.focus(c)
  else:
    state.open = false
    state.anchorHandle.focus(c)

proc dateButtonAction(c: Context; state: DateControlState; day: DateTime;
                      moveChooses: bool): proc() {.closure.} =
  result = proc() = queueDateControlSelection(c, state, day, moveChooses)

proc dateControlState(c: Context; identity: uint64): DateControlState =
  result = c.owner.dateControlStates.getOrDefault(identity)
  if result == nil:
    new(result)
    result.dayHandle = newHandle()
    result.anchorHandle = newHandle()
    c.owner.dateControlStates[identity] = result

proc calendarGrid(c: Context; date: var DateTime; moveChooses: bool;
                  state: DateControlState = nil;
                  changedElement: Element = Element()): Element =
  let theme = c.theme
  let locale = i18n.formatLocale(c.region, c.localeTag)
  result = c.column().gap(theme.space(0.5)).shrink(0)
  let grid = result
  let gridNode = grid.node
  if gridNode == nil:
    return
  gridNode[].dateControl = true
  gridNode[].accessRole = platform.roleTable
  gridNode[].accessRoleSet = true
  var state = if state == nil:
      c.dateControlState(gridNode[].identity)
    else:
      state
  let changeTarget = if changedElement.node == nil: grid else: changedElement
  syncDateControl(state, date, changeTarget)
  let currentValue = date
  let monthStart = firstCalendarDay(state.cursor)
  let title = i18n.formatDate(locale, monthStart,
    i18n.DateOptions(skeleton: "yMMMM"))
  let weekNames = i18n.weekdays(locale, i18n.nameShort, true)
  let firstWeekday = c.region.firstWeekday
  let weekdayOffset = (ord(monthStart.weekday) - ord(firstWeekday) + 7) mod 7
  let gridStart = monthStart - initDuration(days = weekdayOffset)
  let cursorAtStart = state.cursor
  gridNode[].label = title

  let moveCursor = proc(target: DateTime) =
    let next = calendarDate(target)
    if sameCalendarDay(state.cursor, next):
      return
    state.cursor = next
    if moveChooses:
      state.pendingValue = selectedDate(state.lastValue, next)
      state.hasPendingValue = true
    state.dayHandle.focus(c)

  let backKey = if c.rightToLeft: platform.keyRight else: platform.keyLeft
  let forthKey = if c.rightToLeft: platform.keyLeft else: platform.keyRight
  discard grid.onShortcut(0, backKey, proc() =
    moveCursor(state.cursor - initDuration(days = 1)))
  discard grid.onShortcut(0, forthKey, proc() =
    moveCursor(state.cursor + initDuration(days = 1)))
  discard grid.onShortcut(0, platform.keyUp, proc() =
    moveCursor(state.cursor - initDuration(days = 7)))
  discard grid.onShortcut(0, platform.keyDown, proc() =
    moveCursor(state.cursor + initDuration(days = 7)))
  discard grid.onShortcut(0, platform.keyPageUp, proc() =
    moveCursor(shiftCalendarMonth(state.cursor, -1)))
  discard grid.onShortcut(0, platform.keyPageDown, proc() =
    moveCursor(shiftCalendarMonth(state.cursor, 1)))
  discard grid.onShortcut(0, platform.keyHome, proc() =
    moveCursor(firstCalendarDay(state.cursor)))
  discard grid.onShortcut(0, platform.keyEnd, proc() =
    moveCursor(lastCalendarDay(state.cursor)))
  discard grid.children(proc() =
    let monthHeading = c.row().gap(theme.space(1)).alignItems(Align.Center)
    discard monthHeading.children(proc() =
      let previous = c.buttonBase().padding(theme.space(0.5),
        theme.space(2)).label("Previous month")
      discard previous.onClick(proc() =
        moveCursor(shiftCalendarMonth(state.cursor, -1)))
      discard previous.children(proc() =
        discard c.text("‹").textColor(theme.text)
      )

      discard c.text(title).grow().textAlign(Align.Center)
        .textWeight(600).label(title)

      let next = c.buttonBase().padding(theme.space(0.5),
        theme.space(2)).label("Next month")
      discard next.onClick(proc() =
        moveCursor(shiftCalendarMonth(state.cursor, 1)))
      discard next.children(proc() =
        discard c.text("›").textColor(theme.text)
      )
    )

    let headings = c.row().gap(theme.space(1))
    let headingsNode = headings.node
    if headingsNode != nil:
      headingsNode[].accessRole = platform.roleRow
      headingsNode[].accessRoleSet = true
    discard headings.children(proc() =
      let firstIndex = calendarWeekdayIndex(firstWeekday)
      for column in 0..<7:
        let name = weekNames[(firstIndex + column) mod 7]
        let heading = c.box().size(theme.space(8), theme.space(3))
          .center().label(name)
        let node = heading.node
        if node != nil:
          node[].accessRole = platform.roleColumnHeader
          node[].accessRoleSet = true
        discard heading.children(proc() =
          discard c.text(name).textColor(theme.textMuted)
            .textSize(theme.fontSize - 2).textAlign(Align.Center)
        )
    )

    for week in 0..<6:
      let weekRow = c.row().gap(theme.space(1))
      let rowNode = weekRow.node
      if rowNode != nil:
        rowNode[].accessRole = platform.roleRow
        rowNode[].accessRoleSet = true
      discard weekRow.children(proc() =
        for column in 0..<7:
          let day = gridStart + initDuration(days = week * 7 + column)
          let dayLabel = i18n.formatDate(locale, day,
            i18n.DateOptions(skeleton: "yMMMMd"))
          let isSelected = sameCalendarDay(day, currentValue)

          let cell = c.box().size(theme.space(8), theme.space(7)).center()
          let cellNode = cell.node
          if cellNode != nil:
            cellNode[].accessRole = platform.roleCell
            cellNode[].accessRoleSet = true
          discard cell.children(proc() =
            discard c.key("calendar-day-" & $day.year & "-" & $int(day.month) &
              "-" & $int(day.monthday))
            let dayButton = c.buttonBase().size(theme.space(8),
              theme.space(7)).center().radius(theme.radius)
              .focusRing(false).label(dayLabel)
            discard dayButton.onClick(dateButtonAction(c, state, day,
              moveChooses))
            let isCursor = sameCalendarDay(day, cursorAtStart)
            discard dayButton.tabStop(isCursor)
            if isCursor:
              discard dayButton.bindHandle(state.dayHandle)
            let dayNode = dayButton.node
            if dayNode != nil:
              dayNode[].accessRole = platform.roleButton
              dayNode[].accessRoleSet = true
              if isSelected:
                dayNode[].accessExtraStates = platform.accessChecked
            var foreground = theme.text
            var background = theme.surface
            if day.month != monthStart.month:
              foreground = theme.textMuted
            if isSelected:
              foreground = theme.accentText
              background = theme.accent
            elif isCursor:
              background = theme.surfaceHover
            if dayButton.pressed():
              background = theme.surfacePressed
            elif dayButton.hovered() and not isSelected:
              background = theme.surfaceHover
            discard dayButton.background(background)
            discard dayButton.children(proc() =
              discard c.text(i18n.formatDate(locale, day,
                i18n.DateOptions(skeleton: "d"))).textColor(foreground)
                .textAlign(Align.Center)
            )
          )
      )
  )

proc calendar*(c: Context; date: var DateTime): Element =
  ## Shows a localized month calendar. Arrow keys choose the day as they move.
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    raise newException(ValueError, "ui: calendar must be built in a frame")
  result = c.calendarGrid(date, moveChooses = true)

proc dateInput*(c: Context; date: var DateTime): Element =
  ## Shows a localized date field with an anchored calendar popover.
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    raise newException(ValueError, "ui: date input must be built in a frame")
  let theme = c.theme
  result = c.buttonBase().minWidth(theme.space(32.5))
    .justify(Align.SpaceBetween).padding(theme.space(2), theme.space(3))
    .radius(theme.radius).border(1, theme.border)
  let anchor = result
  let node = anchor.node
  if node == nil:
    return
  node[].dateControl = true
  let state = c.dateControlState(node[].identity)
  syncDateControl(state, date, anchor)
  let locale = i18n.formatLocale(c.region, c.localeTag)
  let valueText = i18n.formatDate(locale, date,
    i18n.DateOptions(skeleton: "yMd"))
  discard anchor.bindHandle(state.anchorHandle)
  node[].accessRole = platform.rolePopUpButton
  node[].accessRoleSet = true
  node[].label = "Date"
  node[].accessValue = valueText
  if state.open:
    node[].accessExtraStates = node[].accessExtraStates or
      platform.accessExpanded

  if anchor.clicked():
    state.open = not state.open
    state.cursor = calendarDate(date)
    if state.open:
      state.dayHandle.focus(c)

  discard anchor.children(proc() =
    discard c.text(valueText).textColor(theme.text).grow()
    let glyph = c.text("▦").textColor(theme.textMuted)
    let glyphNode = glyph.node
    if glyphNode != nil:
      glyphNode[].accessHidden = true
  )

  var frameOpen = state.open
  # popoverBase runs this builder inline during the current frame.
  let valuePtr = addr date
  discard c.popoverBase(anchor, frameOpen, proc(panel: Element) =
    discard panel.padding(theme.space(2)).radius(theme.radius)
      .background(theme.background).border(1, theme.border)
      .shadow(0, 4, 14, 0, rgba(0, 0, 0, 0.22'f32))
    discard c.calendarGrid(valuePtr[], moveChooses = false, state = state,
      changedElement = anchor)
  )
  state.open = frameOpen and state.open
