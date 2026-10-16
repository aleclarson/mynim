import std/assertions

import mynim/i18n as i18n

block time_patterns:
  doAssert i18n.timePattern("en-US", 12) == "h:mm a"
  doAssert i18n.timePattern("en-GB", 24) == "HH:mm"
  doAssert i18n.timePattern("zh-Hans", 12) == "ah:mm"

block localized_integer_digits:
  doAssert i18n.formatInteger("en", 7, 2) == "07"
  doAssert i18n.formatInteger("fa", 7, 2) == "۰۷"

block localized_period_names:
  let (am, pm) = i18n.dayPeriods("zh-Hans", i18n.nameAbbreviated)
  doAssert am == "上午" and pm == "下午"
