## Maps dates onto a plot and chooses round calendar ticks.

import std/[algorithm, math, times as ntimes]
import mynim/ui/chart/scales

type
  TimeTickFormat* = proc(value: ntimes.DateTime): string {.closure.}

  TimeScale* = object
    ## Maps dates from the start to end of a plot.
    fromTime*, toTime*: ntimes.DateTime
    format*: TimeTickFormat

  TimeUnit = enum
    unitMillisecond
    unitSecond
    unitMinute
    unitHour
    unitDay
    unitWeek
    unitMonth
    unitYear

  TimeInterval = object
    unit: TimeUnit
    step: int

proc newTimeScale*(fromTime, toTime: ntimes.DateTime): TimeScale =
  ## Returns a scale from one date to another.
  TimeScale(fromTime: fromTime, toTime: toTime)

proc unixMillis(value: ntimes.DateTime): int64 =
  value.toTime.toUnix * 1000 + value.nanosecond.int64 div 1_000_000

proc elapsedNanoseconds(value, origin: ntimes.DateTime): float64 =
  (value.toTime.toUnix - origin.toTime.toUnix).float64 * 1_000_000_000 +
    value.nanosecond.float64 - origin.nanosecond.float64

proc at*(scale: TimeScale; value: ntimes.DateTime): float32 =
  let span = elapsedNanoseconds(scale.toTime, scale.fromTime)
  if span == 0:
    return 0.5'f32
  (elapsedNanoseconds(value, scale.fromTime) / span).float32

proc span*(scale: TimeScale; a, b: ntimes.DateTime): Span =
  Span(lo: scale.at(a), hi: scale.at(b))

proc invert*(scale: TimeScale; fraction: float32): ntimes.DateTime =
  let delta = round(fraction.float64 *
    elapsedNanoseconds(scale.toTime, scale.fromTime)).int64
  scale.fromTime + ntimes.initDuration(nanoseconds = delta)

const
  sqrt50 = sqrt(50.0)
  sqrt10 = sqrt(10.0)
  sqrt2 = sqrt(2.0)
  dayMillis = 24'i64 * 60 * 60 * 1000
  weekMillis = 7 * dayMillis
  monthMillis = 30 * dayMillis
  yearMillis = 365 * dayMillis
  intervals = [
    (unitSecond, 1, 1_000'i64), (unitSecond, 5, 5_000'i64),
    (unitSecond, 15, 15_000'i64), (unitSecond, 30, 30_000'i64),
    (unitMinute, 1, 60_000'i64), (unitMinute, 5, 300_000'i64),
    (unitMinute, 15, 900_000'i64), (unitMinute, 30, 1_800_000'i64),
    (unitHour, 1, 3_600_000'i64), (unitHour, 3, 10_800_000'i64),
    (unitHour, 6, 21_600_000'i64), (unitHour, 12, 43_200_000'i64),
    (unitDay, 1, dayMillis), (unitDay, 2, 2 * dayMillis),
    (unitWeek, 1, weekMillis), (unitMonth, 1, monthMillis),
    (unitMonth, 3, 3 * monthMillis), (unitYear, 1, yearMillis)
  ]

proc niceStep(target: float64): int =
  let value = max(1.0, target)
  let power = floor(log10(value))
  let normalized = value / pow(10.0, power)
  let factor = if normalized >= sqrt50: 10.0
    elif normalized >= sqrt10: 5.0
    elif normalized >= sqrt2: 2.0
    else: 1.0
  max(1, int(round(pow(10.0, power) * factor)))

proc chosenInterval(lo, hi: ntimes.DateTime; count: int): TimeInterval =
  let target = (hi - lo).inMilliseconds.float64 / max(1, count).float64
  if target < intervals[0][2].float64:
    return TimeInterval(unit: unitMillisecond,
      step: niceStep(target))
  var i = 0
  while i < intervals.len and intervals[i][2].float64 <= target:
    inc i
  if i == intervals.len:
    let years = (hi.year - lo.year).float64 +
      (hi.yearday.float64 - lo.yearday.float64) / 366.0
    return TimeInterval(unit: unitYear,
      step: niceStep(years / max(1, count).float64))
  if i == 0:
    return TimeInterval(unit: unitMillisecond, step: niceStep(target))
  let before = intervals[i - 1]
  let after = intervals[i]
  if target / before[2].float64 < after[2].float64 / target:
    TimeInterval(unit: before[0], step: before[1])
  else:
    TimeInterval(unit: after[0], step: after[1])

proc makeDate(year, month, day, hour, minute, second, nanosecond: int;
              zone: ntimes.Timezone): ntimes.DateTime =
  ntimes.dateTime(year, ntimes.Month(month), day, hour, minute, second,
    nanosecond, zone)

proc addMonths(value: ntimes.DateTime; amount: int): ntimes.DateTime =
  let monthIndex = value.year * 12 + value.month.int - 1 + amount
  let year = floorDiv(monthIndex, 12)
  let month = floorMod(monthIndex, 12) + 1
  makeDate(year, month, 1, 0, 0, 0, 0, value.timezone)

proc addCalendarDays(value: ntimes.DateTime; amount: int): ntimes.DateTime =
  var year = value.year
  var month = value.month.int
  var day = value.monthday.int + amount
  while day < 1:
    dec month
    if month < 1:
      month = 12
      dec year
    day += ntimes.getDaysInMonth(ntimes.Month(month), year)
  while day > ntimes.getDaysInMonth(ntimes.Month(month), year):
    day -= ntimes.getDaysInMonth(ntimes.Month(month), year)
    inc month
    if month > 12:
      month = 1
      inc year
  makeDate(year, month, day, 0, 0, 0, 0, value.timezone)

proc addCalendarHours(value: ntimes.DateTime; amount: int): ntimes.DateTime =
  let total = value.hour.int + amount
  let day = addCalendarDays(value, floorDiv(total, 24))
  makeDate(day.year, day.month.int, day.monthday.int, floorMod(total, 24),
    0, 0, 0, value.timezone)

proc floorTo(interval: TimeInterval; value: ntimes.DateTime): ntimes.DateTime =
  let year = value.year
  let month = value.month.int
  let day = value.monthday.int
  let hour = value.hour.int
  let minute = value.minute.int
  let second = value.second.int
  let zone = value.timezone
  case interval.unit
  of unitMillisecond:
    let ms = value.nanosecond.int div 1_000_000
    makeDate(year, month, day, hour, minute, second,
      (ms - ms mod interval.step) * 1_000_000, zone)
  of unitSecond:
    makeDate(year, month, day, hour, minute,
      second - second mod interval.step, 0, zone)
  of unitMinute:
    makeDate(year, month, day, hour,
      minute - minute mod interval.step, 0, 0, zone)
  of unitHour:
    makeDate(year, month, day,
      hour - hour mod interval.step, 0, 0, 0, zone)
  of unitDay:
    makeDate(year, month, day - (day - 1) mod interval.step,
      0, 0, 0, 0, zone)
  of unitWeek:
    let sundayOffset = (value.weekday.ord + 1) mod 7
    addCalendarDays(makeDate(year, month, day, 0, 0, 0, 0, zone),
      -sundayOffset)
  of unitMonth:
    let zeroMonth = month - 1
    makeDate(year, zeroMonth - zeroMonth mod interval.step + 1,
      1, 0, 0, 0, 0, zone)
  of unitYear:
    makeDate(year - year mod interval.step, 1, 1, 0, 0, 0, 0, zone)

proc next(interval: TimeInterval; value: ntimes.DateTime): ntimes.DateTime =
  case interval.unit
  of unitMillisecond:
    value + ntimes.initDuration(milliseconds = interval.step.int64)
  of unitSecond:
    value + ntimes.initDuration(seconds = interval.step.int64)
  of unitMinute:
    value + ntimes.initDuration(minutes = interval.step.int64)
  of unitHour:
    addCalendarHours(value, interval.step)
  of unitDay:
    let nextDay = addCalendarDays(value, interval.step)
    if nextDay.month != value.month:
      makeDate(nextDay.year, nextDay.month.int, 1, 0, 0, 0, 0,
        value.timezone)
    else:
      nextDay
  of unitWeek:
    addCalendarDays(value, 7 * interval.step)
  of unitMonth:
    addMonths(value, interval.step)
  of unitYear:
    makeDate(value.year + interval.step, 1, 1, 0, 0, 0, 0, value.timezone)

proc timeLabel(value: ntimes.DateTime): string =
  if value.nanosecond != 0:
    return value.format(".fff")
  if value.second != 0:
    return value.format(":ss")
  if value.minute != 0:
    return value.format("HH:mm")
  if value.hour != 0:
    return value.format("HH:'00'")
  if value.monthday != 1:
    return value.format("MMM d")
  if value.month != ntimes.mJan:
    return value.format("MMM")
  value.format("yyyy")

proc ticks*(scale: TimeScale; count: int): seq[Tick] =
  ## Returns round calendar ticks within the time domain.
  if count <= 0 or scale.fromTime == scale.toTime:
    return
  var lo = scale.fromTime
  var hi = scale.toTime
  let isReversed = hi < lo
  if isReversed:
    swap(lo, hi)
  let interval = chosenInterval(lo, hi, count)
  var value = interval.floorTo(lo)
  let format = if scale.format == nil: timeLabel else: scale.format
  var produced = 0
  while value <= hi and produced < 1000:
    if value >= lo:
      result.add Tick(at: scale.at(value), value: unixMillis(value).float64,
        label: format(value))
    value = interval.next(value)
    inc produced
  if isReversed:
    result.reverse()
