import std/[assertions, times]

import mynim/i18n as i18n

let date = dateTime(2026, mOct, 5, zone = utc())

proc eastFiveFromTime(time: Time): ZonedTime =
  ZonedTime(time: time, utcOffset: -5 * 60 * 60, isDst: false)

proc eastFiveFromAdjTime(time: Time): ZonedTime =
  ZonedTime(time: time + initDuration(hours = -5),
    utcOffset: -5 * 60 * 60, isDst: false)

proc eastFiveThirtyFromTime(time: Time): ZonedTime =
  ZonedTime(time: time, utcOffset: -(5 * 60 + 30) * 60, isDst: false)

proc eastFiveThirtyFromAdjTime(time: Time): ZonedTime =
  ZonedTime(time: time + initDuration(minutes = -(5 * 60 + 30)),
    utcOffset: -(5 * 60 + 30) * 60, isDst: false)

proc westFourFromTime(time: Time): ZonedTime =
  ZonedTime(time: time, utcOffset: 4 * 60 * 60, isDst: false)

proc westFourFromAdjTime(time: Time): ZonedTime =
  ZonedTime(time: time + initDuration(hours = 4),
    utcOffset: 4 * 60 * 60, isDst: false)

block date_skeletons:
  let usShort = i18n.formatDate("en-US", date,
    i18n.DateOptions(skeleton: "yMd"))
  doAssert usShort == "10/5/2026", "en-US yMd: " & usShort
  doAssert i18n.formatDate("en-GB", date,
    i18n.DateOptions(skeleton: "yMd")) == "05/10/2026"
  doAssert i18n.formatDate("en", date,
    i18n.DateOptions(skeleton: "yMMMM")) == "October 2026"
  doAssert i18n.formatDate("en", date,
    i18n.DateOptions(skeleton: "yMMMMd")) == "October 5, 2026"
  doAssert i18n.formatDate("de-DE", date,
    i18n.DateOptions(skeleton: "yMMMMd")) == "5. Oktober 2026"
  doAssert i18n.formatDate("zh-Hans", date,
    i18n.DateOptions(skeleton: "yMMMMd")) == "2026年10月5日"
  doAssert i18n.formatDate("fa", date,
    i18n.DateOptions(skeleton: "yMd")) == "۲۰۲۶/۱۰/۵"

block best_fit_skeletons:
  doAssert i18n.formatDate("en-US", date,
    i18n.DateOptions(skeleton: "yyMMd")) == "10/5/26"
  let morning = dateTime(2026, mOct, 5, 7, 4, zone = utc())
  doAssert i18n.formatDate("en-US", morning,
    i18n.DateOptions(skeleton: "yMMMdHm")) == "Oct 5, 2026, 07:04"

block date_time_styles:
  let morning = dateTime(2026, mOct, 5, 7, 4, 9, zone = utc())
  let easternZone = newTimezone("Test/EastFive", eastFiveFromTime,
    eastFiveFromAdjTime)
  let eastern = dateTime(2026, mOct, 5, 7, 4, 9, zone = easternZone)
  let halfHourZone = newTimezone("Test/EastFiveThirty",
    eastFiveThirtyFromTime, eastFiveThirtyFromAdjTime)
  let westZone = newTimezone("Test/WestFour", westFourFromTime,
    westFourFromAdjTime)
  doAssert i18n.formatDate("en-US", morning,
    i18n.DateOptions(dateStyle: i18n.dateStyleShort)) == "10/5/26"
  doAssert i18n.formatDate("en-US", morning,
    i18n.DateOptions(dateStyle: i18n.dateStyleShort,
      skeleton: "yMMMMd")) == "10/5/26"
  doAssert i18n.formatDate("en-US", morning,
    i18n.DateOptions(dateStyle: i18n.dateStyleFull)) ==
    "Monday, October 5, 2026"
  doAssert i18n.formatDate("en-US", morning,
    i18n.DateOptions(timeStyle: i18n.dateStyleMedium)) == "7:04:09 AM"
  doAssert i18n.formatDate("en-US", morning,
    i18n.DateOptions(timeStyle: i18n.dateStyleShort,
      hourCycle: 24)) == "07:04"
  doAssert i18n.formatDate("en-US", morning,
    i18n.DateOptions(timeStyle: i18n.dateStyleLong)) == "7:04:09 AM UTC"
  doAssert i18n.formatDate("en-US", morning,
    i18n.DateOptions(timeStyle: i18n.dateStyleFull)) ==
    "7:04:09 AM Coordinated Universal Time"
  doAssert i18n.formatDate("en-US", eastern,
    i18n.DateOptions(timeStyle: i18n.dateStyleLong)) == "7:04:09 AM GMT+5"
  doAssert i18n.formatDate("en-US", eastern,
    i18n.DateOptions(timeStyle: i18n.dateStyleFull)) == "7:04:09 AM GMT+05:00"
  doAssert i18n.formatDate("en-US", dateTime(2026, mOct, 5, 7, 4, 9,
      zone = halfHourZone),
    i18n.DateOptions(timeStyle: i18n.dateStyleFull)) ==
    "7:04:09 AM GMT+05:30"
  doAssert i18n.formatDate("en-US", dateTime(2026, mOct, 5, 7, 4, 9,
      zone = westZone),
    i18n.DateOptions(timeStyle: i18n.dateStyleFull)) == "7:04:09 AM GMT-04:00"
  doAssert i18n.formatDate("en-US", morning,
    i18n.DateOptions(dateStyle: i18n.dateStyleFull,
      timeStyle: i18n.dateStyleShort)) ==
    "Monday, October 5, 2026 at 7:04 AM"
  doAssert i18n.formatDate("en-US", morning,
    i18n.DateOptions(dateStyle: i18n.dateStyleFull,
      timeStyle: i18n.dateStyleShort, hourCycle: 24)) ==
    "Monday, October 5, 2026 at 07:04"

block localized_names:
  doAssert i18n.months("en", i18n.nameAbbreviated)[0] == "Jan"
  doAssert i18n.months("de", i18n.nameWide, true)[0] == "Januar"
  doAssert i18n.weekdays("en", i18n.nameShort, true) ==
    ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
  doAssert i18n.dayPeriods("zh-Hans") == (am: "上午", pm: "下午")

block hour_skeletons:
  let morning = dateTime(2026, mOct, 5, 7, 4, zone = utc())
  doAssert i18n.formatDate("en-US", morning,
    i18n.DateOptions(skeleton: "jm")) == "7:04 AM"
  doAssert i18n.formatDate("en-US-u-hc-h23", morning,
    i18n.DateOptions(skeleton: "jm")) == "07:04"
  doAssert i18n.formatDate("en-US", morning,
    i18n.DateOptions(skeleton: "jm", hourCycle: 24)) == "07:04"
