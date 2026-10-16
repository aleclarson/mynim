import std/[assertions, times]

import mynim/i18n as i18n
import mynim/i18n/cldr_regions as cldr

block locale_normalization:
  doAssert i18n.normalize("EN-us") == "en-US"
  doAssert i18n.normalize("en-US-u-fw-mon-hc-h23") == "en-US"
  doAssert i18n.normalize("sr_RS@latin") == "sr-Latn-RS"
  doAssert i18n.normalize("C.UTF-8") == ""
  doAssert i18n.direction("ar_SA") == "rtl"

block regional_weekdays:
  doAssert i18n.firstWeekday("en-US") == dSun
  doAssert i18n.firstWeekday("en-GB") == dMon
  doAssert i18n.firstWeekday("de") == dMon
  doAssert i18n.firstWeekday("fa-IR") == dSat
  doAssert i18n.firstWeekday("en-US-u-fw-mon") == dMon
  doAssert i18n.firstWeekday("fr-FR-u-fw-sat") == dSat
  doAssert i18n.firstWeekday("unrecognized") == dMon

  let weekdays = [dSun, dMon, dTue, dWed, dThu, dFri, dSat]
  for row in cldr.weekData:
    let expected = weekdays[int(row.value and 0x0f'u8)]
    doAssert i18n.firstWeekday("und-" & row.key) == expected, row.key

block regional_hour_cycles:
  doAssert i18n.hourCycle("en-US") == 12
  doAssert i18n.hourCycle("en-GB") == 24
  doAssert i18n.hourCycle("fr-CA") == 24
  doAssert i18n.hourCycle("ja-JP") == 24
  doAssert i18n.hourCycle("en-u-hc-h11") == 12
  doAssert i18n.hourCycle("en-u-hc-h12") == 12
  doAssert i18n.hourCycle("en-u-hc-h23") == 24
  doAssert i18n.hourCycle("en-u-hc-h24") == 24

  for row in cldr.hourData:
    let tag = if row.key.contains('-'): row.key else: "und-" & row.key
    let expected = if row.value in {'h', 'K'}: 12 else: 24
    doAssert i18n.hourCycle(tag) == expected, row.key

block regional_format_locale:
  let germanFormats = i18n.Region(locale: "de-DE", firstWeekday: dMon,
    hourCycle: 24)
  doAssert germanFormats.formatLocale("en") == "en-DE-u-fw-mon-hc-h23"
  doAssert germanFormats.formatLocale("zh-TW") ==
    "zh-Hant-DE-u-fw-mon-hc-h23"

  let taiwanFormats = i18n.Region(locale: "zh-TW", firstWeekday: dMon,
    hourCycle: 24)
  doAssert taiwanFormats.formatLocale("zh") ==
    "zh-Hans-TW-u-fw-mon-hc-h23"
  doAssert germanFormats.formatLocale("en-XA") ==
    "en-DE-u-fw-mon-hc-h23"
