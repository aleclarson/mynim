import std/[assertions, strutils, tables]

import mynim/plugins/updater/texts as updaterTexts

block locale_matching:
  doAssert updaterTexts.translations.len == 14
  let available = ["de", "en", "pt-BR", "sv", "zh-Hans", "zh-Hant"]
  let cases = [
    ("de-DE", "de"), ("de_AT.UTF-8", "de"), ("en-GB", "en"),
    ("pt-BR", "pt-BR"), ("pt-PT", "pt-BR"),
    ("zh-Hans-CN", "zh-Hans"), ("zh-CN", "zh-Hans"),
    ("zh_SG", "zh-Hans"), ("zh", "zh-Hans"),
    ("zh-Hant-HK", "zh-Hant"), ("zh-TW", "zh-Hant"),
    ("zh_HK.UTF-8", "zh-Hant"), ("zh-MO", "zh-Hant"),
    ("SV_se", "sv"), ("es-419", "en"), ("sr-Latn-RS", "en"),
    ("", "en"), ("C", "en")
  ]
  for (locale, expected) in cases:
    doAssert updaterTexts.matchLanguage(locale, available) == expected,
      locale
  doAssert updaterTexts.matchLanguage("zh-TW", ["en", "zh-Hans"]) == "en"

block overrides_and_fallback:
  var extra = initTable[string, updaterTexts.Strings]()
  extra["fr"] = updaterTexts.Strings(releaseNotes: "Notes de version custom")
  let french = updaterTexts.newText("fr-FR", extra)
  doAssert french.language == "fr"
  doAssert french.strings.title == "Mise à jour de logiciels"
  doAssert french.strings.releaseNotes == "Notes de version custom"
  doAssert french.frontendTexts().lang == "fr"
  doAssert not french.rtl
  doAssert french.decimalComma
  doAssert french.megabytes(5_000_000) == "5,0 Mo"

  extra["ar"] = updaterTexts.Strings(title: "تحديث البرنامج")
  let arabic = updaterTexts.newText("ar_EG", extra)
  doAssert arabic.language == "ar"
  doAssert arabic.rtl
  doAssert arabic.frontendTexts().rtl
  doAssert arabic.strings.ok == "OK"

  extra["en-GB"] = updaterTexts.Strings(title: "Software Update GB")
  let englishVariant = updaterTexts.newText("en-AU", extra)
  doAssert englishVariant.language == "en-GB"
  doAssert englishVariant.strings.title == "Software Update GB"

block formats:
  doAssert updaterTexts.formatStrings("%[2]s / %[1]s", ["first", "second"]) ==
    "second / first"
  doAssert updaterTexts.formatStrings("100%% ready", []) == "100% ready"
  doAssert updaterTexts.checkStrings(updaterTexts.Strings(
    availableMessage: "%[2]s — %[1]s — %[3]s")).len == 0
  doAssert updaterTexts.checkStrings(updaterTexts.Strings(
    availableMessage: "%[2]s — %[1]s")).len > 0

block complete_catalog:
  doAssert updaterTexts.checkStrings(updaterTexts.english).len == 0
  let formatFields = [
    "upToDateMessage", "unavailableMessage", "available",
    "availableMessage", "progress", "megabytes", "readyMessage"
  ]
  for name, value in fieldPairs(updaterTexts.english):
    doAssert value.len > 0, "English is missing " & name
    if name notin formatFields:
      doAssert '%' notin value, "English has a stray format in " & name
  for language, strings in updaterTexts.translations:
    doAssert updaterTexts.checkStrings(strings).len == 0, language
    for name, value in fieldPairs(strings):
      doAssert value.len > 0, language & " is missing " & name
      if name notin formatFields:
        doAssert '%' notin value, language & " has a stray format in " & name

block custom_format_validation:
  var invalid = initTable[string, updaterTexts.Strings]()
  invalid["en"] = updaterTexts.Strings(available: "A new version of %d")
  let problem = updaterTexts.validateStrings(invalid)
  doAssert "strings of" in problem
  doAssert "Available" in problem
