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

block additional_date_fields:
  let yearEnd = dateTime(2021, mDec, 31, zone = utc())
  let yearStart = dateTime(2021, mJan, 1, zone = utc())
  doAssert i18n.formatDate("en-US", yearEnd,
    i18n.DateOptions(skeleton: "D")) == "365"
  doAssert i18n.formatDate("en-US", dateTime(2020, mDec, 31, zone = utc()),
    i18n.DateOptions(skeleton: "D")) == "366"
  doAssert i18n.formatDate("en-US", yearStart,
    i18n.DateOptions(skeleton: "Y")) == "2021"
  doAssert i18n.formatDate("de-DE", yearStart,
    i18n.DateOptions(skeleton: "Y")) == "2020"
  let firstSunday = dateTime(2021, mJan, 3, zone = utc())
  doAssert i18n.formatDate("de-DE", firstSunday,
    i18n.DateOptions(skeleton: "Y")) == "2020"
  doAssert i18n.formatDate("de-DE-u-fw-sun", firstSunday,
    i18n.DateOptions(skeleton: "Y")) == "2021"
  doAssert i18n.formatDate("en-US", dateTime(0, mJan, 1, zone = utc()),
    i18n.DateOptions(skeleton: "y")) == "1"
  doAssert i18n.formatDate("en-US", dateTime(0, mJan, 1, zone = utc()),
    i18n.DateOptions(skeleton: "u")) == "1"

  let fractional = dateTime(2026, mOct, 5, 7, 4, 9, 123_456_789, utc())
  doAssert i18n.formatDate("en-US", fractional,
    i18n.DateOptions(skeleton: "S")) == "1"
  doAssert i18n.formatDate("en-US", fractional,
    i18n.DateOptions(skeleton: "SSS")) == "123"
  doAssert i18n.formatDate("en-US", fractional,
    i18n.DateOptions(skeleton: "SSSSSSSSSS")) == "1234567890"
  doAssert i18n.formatDate("fa", fractional,
    i18n.DateOptions(skeleton: "S")) == "۱"

  let chineseDawn = dateTime(2026, mOct, 5, 5, zone = utc())
  let chineseNight = dateTime(2026, mOct, 5, 2, zone = utc())
  let englishMorning = dateTime(2026, mOct, 5, 7, zone = utc())
  doAssert i18n.formatDate("en-US", englishMorning,
    i18n.DateOptions(skeleton: "B")) == "AM"
  doAssert i18n.formatDate("zh-Hant", chineseDawn,
    i18n.DateOptions(skeleton: "B")) == "清晨"
  doAssert i18n.formatDate("zh-Hant", chineseNight,
    i18n.DateOptions(skeleton: "B")) == "凌晨"

  let easternZone = newTimezone("Test/EastFive", eastFiveFromTime,
    eastFiveFromAdjTime)
  let eastern = dateTime(2026, mOct, 5, 7, 4, zone = easternZone)
  for field in ["O", "Z", "X", "x"]:
    doAssert i18n.formatDate("en-US", eastern,
      i18n.DateOptions(skeleton: field)) == "GMT+5"
  for field in ["OOOO", "ZZZZ", "XXXX", "xxxx", "V"]:
    doAssert i18n.formatDate("en-US", eastern,
      i18n.DateOptions(skeleton: field)) == "GMT+05:00"
