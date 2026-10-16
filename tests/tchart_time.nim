import std/[assertions, strutils, times as ntimes]
import mynim/ui/chart

proc dt(year, month, day: int; hour = 0; minute = 0; second = 0;
        nanosecond = 0): ntimes.DateTime =
  ntimes.dateTime(year, ntimes.Month(month), day, hour, minute, second,
    nanosecond, ntimes.utc())

proc epochMillis(value: ntimes.DateTime): float64 =
  (value.toTime.toUnix * 1000 + value.nanosecond.int64 div 1_000_000).float64

proc verifyTicks(fromTime, toTime: ntimes.DateTime; count: int;
                 expected: openArray[ntimes.DateTime]; labels: string) =
  let ticks = newTimeScale(fromTime, toTime).ticks(count)
  doAssert ticks.len == expected.len
  var gotLabels: seq[string]
  for i, tick in ticks:
    doAssert abs(tick.value - epochMillis(expected[i])) < 1e-6
    gotLabels.add tick.label
  doAssert gotLabels.join(" ") == labels

verifyTicks(dt(2026, 1, 1), dt(2026, 12, 31), 6,
  [dt(2026, 1, 1), dt(2026, 4, 1), dt(2026, 7, 1), dt(2026, 10, 1)],
  "2026 Apr Jul Oct")
verifyTicks(dt(2026, 3, 1), dt(2026, 3, 8), 7,
  [dt(2026, 3, 1), dt(2026, 3, 2), dt(2026, 3, 3), dt(2026, 3, 4),
   dt(2026, 3, 5), dt(2026, 3, 6), dt(2026, 3, 7), dt(2026, 3, 8)],
  "Mar Mar 2 Mar 3 Mar 4 Mar 5 Mar 6 Mar 7 Mar 8")
verifyTicks(dt(2026, 3, 5, 9, 13), dt(2026, 3, 5, 17, 40), 5,
  [dt(2026, 3, 5, 10), dt(2026, 3, 5, 11), dt(2026, 3, 5, 12),
   dt(2026, 3, 5, 13), dt(2026, 3, 5, 14), dt(2026, 3, 5, 15),
   dt(2026, 3, 5, 16), dt(2026, 3, 5, 17)],
  "10:00 11:00 12:00 13:00 14:00 15:00 16:00 17:00")
verifyTicks(dt(2026, 3, 5, 9, 13, 7), dt(2026, 3, 5, 9, 14, 51), 6,
  [dt(2026, 3, 5, 9, 13, 15), dt(2026, 3, 5, 9, 13, 30),
   dt(2026, 3, 5, 9, 13, 45), dt(2026, 3, 5, 9, 14),
   dt(2026, 3, 5, 9, 14, 15), dt(2026, 3, 5, 9, 14, 30),
   dt(2026, 3, 5, 9, 14, 45)],
  ":15 :30 :45 09:14 :15 :30 :45")
verifyTicks(dt(2010, 6, 1), dt(2026, 6, 1), 5,
  [dt(2015, 1, 1), dt(2020, 1, 1), dt(2025, 1, 1)], "2015 2020 2025")
verifyTicks(dt(2026, 1, 29), dt(2026, 2, 12), 8,
  [dt(2026, 1, 29), dt(2026, 1, 31), dt(2026, 2, 1), dt(2026, 2, 3),
   dt(2026, 2, 5), dt(2026, 2, 7), dt(2026, 2, 9), dt(2026, 2, 11)],
  "Jan 29 Jan 31 Feb Feb 3 Feb 5 Feb 7 Feb 9 Feb 11")
verifyTicks(dt(2026, 3, 1), dt(2026, 3, 29), 4,
  [dt(2026, 3, 1), dt(2026, 3, 8), dt(2026, 3, 15), dt(2026, 3, 22),
   dt(2026, 3, 29)], "Mar Mar 8 Mar 15 Mar 22 Mar 29")
verifyTicks(dt(2026, 1, 1, nanosecond = 120_000_000),
  dt(2026, 1, 1, nanosecond = 870_000_000), 5,
  [dt(2026, 1, 1, nanosecond = 200_000_000),
   dt(2026, 1, 1, nanosecond = 400_000_000),
   dt(2026, 1, 1, nanosecond = 600_000_000),
   dt(2026, 1, 1, nanosecond = 800_000_000)],
  ".200 .400 .600 .800")

let fromTime = dt(2026, 3, 1)
let toTime = dt(2026, 3, 8)
let timeScale = newTimeScale(fromTime, toTime)
doAssert timeScale.at(dt(2026, 3, 4, 12)) == 0.5'f32
doAssert timeScale.invert(0.5'f32) == dt(2026, 3, 4, 12)
doAssert timeScale.span(fromTime, toTime) == Span(lo: 0, hi: 1)
doAssert newTimeScale(fromTime, fromTime).at(fromTime) == 0.5'f32
doAssert newTimeScale(toTime, fromTime).ticks(7)[0].value == epochMillis(toTime)
let subMillisecond = newTimeScale(dt(2026, 1, 1),
  dt(2026, 1, 1, nanosecond = 1000))
doAssert subMillisecond.at(dt(2026, 1, 1, nanosecond = 500)) == 0.5'f32
doAssert subMillisecond.invert(0.5'f32) == dt(2026, 1, 1, nanosecond = 500)

echo "chart time tests passed"
