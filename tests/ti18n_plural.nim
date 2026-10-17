import std/[assertions, json, math, strutils, tables]
import ../src/mynim/i18n as i18n

proc pluralOperands(input: string; i: uint64; v, w: int; f, t: uint64;
    c = 0) =
  let value = i18n.newPluralOperands(input)
  doAssert value.i == i and value.v == v and value.w == w and
    value.f == f and value.t == t and value.c == c,
    input & " parsed to " & $value

proc category(locale, value: string; ordinal = false): string =
  let operands = i18n.newPluralOperands(value)
  if ordinal:
    i18n.pluralName(i18n.ordinalCategory(locale, operands))
  else:
    i18n.pluralName(i18n.pluralCategory(locale, operands))

proc categoryNames(values: seq[i18n.Plural]): seq[string] =
  for value in values:
    result.add i18n.pluralName(value)

proc expandSamples(samples: string): seq[string] =
  for group in samples.split('@'):
    let start = group.find(' ')
    if start < 0: continue
    for rawItem in group[start + 1 .. ^1].split(','):
      let item = rawItem.strip()
      if item.len == 0 or item == "…": continue
      let range = item.find('~')
      if range < 0:
        result.add item
        continue
      let first = item[0 ..< range]
      let last = item[range + 1 .. ^1]
      let fractionDigits = first.count('.')
      let lower = parseBiggestInt(first.replace(".", ""))
      let upper = parseBiggestInt(last.replace(".", ""))
      for scaled in lower .. upper:
        var digits = $scaled
        if fractionDigits > 0:
          digits = repeat('0', max(fractionDigits + 1 - digits.len, 0)) & digits
          let point = digits.len - fractionDigits
          digits = digits[0 ..< point] & "." & digits[point .. ^1]
        result.add digits

block decimal_operands_preserve_visible_fraction_digits:
  pluralOperands("0", 0, 0, 0, 0, 0)
  pluralOperands("-5", 5, 0, 0, 0, 0)
  pluralOperands("1.0", 1, 1, 0, 0, 0)
  pluralOperands("1.50", 1, 2, 1, 50, 5)
  pluralOperands("1.03", 1, 2, 2, 3, 3)
  pluralOperands("1.230", 1, 3, 2, 230, 23)
  pluralOperands("0.001", 0, 3, 3, 1, 1)
  pluralOperands("1.2c6", 1_200_000, 0, 0, 0, 0, 6)
  pluralOperands("123c6", 123_000_000, 0, 0, 0, 0, 6)
  pluralOperands("1.234c2", 123, 1, 1, 4, 4, 2)
  pluralOperands("1c3", 1_000, 0, 0, 0, 0, 3)
  pluralOperands(".5", 0, 1, 1, 5, 5)
  doAssert i18n.newPluralOperands(1.5).f == 5,
    $i18n.newPluralOperands(1.5)
  doAssert i18n.newPluralOperands(0.25'f32).v == 2
  doAssert i18n.newPluralOperands(0.1'f32).f == 1
  doAssert i18n.newPluralOperands(1.0).v == 0
  doAssert i18n.newPluralOperands(int64.low).i ==
    1_223_372_036_854_775_808'u64
  doAssert i18n.newPluralOperands(uint64.high).i ==
    1_446_744_073_709_551_615'u64
  doAssert not i18n.parsePluralOperands("1.").ok
  doAssert not i18n.parsePluralOperands("1c-2").ok
  doAssert not i18n.parsePluralOperands("1.2.3").ok
  doAssert not i18n.parsePluralOperands($NaN).ok

block categories_follow_cldr_and_fallback_by_language:
  doAssert categoryNames(i18n.pluralCategories("en-GB")) == @["one", "other"]
  doAssert categoryNames(i18n.ordinalCategories("en")) ==
    @["one", "two", "few", "other"]
  doAssert categoryNames(i18n.pluralCategories("zh-Hant-TW")) == @["other"]
  doAssert categoryNames(i18n.pluralCategories("ar")) ==
    @["zero", "one", "two", "few", "many", "other"]
  doAssert categoryNames(i18n.pluralCategories("ru")) ==
    @["one", "few", "many", "other"]
  doAssert categoryNames(i18n.pluralCategories("pt-PT")) ==
    @["one", "many", "other"]
  doAssert categoryNames(i18n.pluralCategories("xx")) == @["other"]
  doAssert category("en", "1") == "one"
  doAssert category("en", "1.0") == "other"
  doAssert category("en", "22", ordinal = true) == "two"
  doAssert category("en", "103", ordinal = true) == "few"
  doAssert category("fr", "0") == "one"
  doAssert category("fr", "1000000") == "many"
  doAssert category("ru", "21") == "one"
  doAssert category("ru", "3") == "few"
  doAssert category("ar", "111") == "many"
  doAssert category("lv", "0.1") == "one"
  doAssert category("lv", "0.10") == "other"

block cldr_plural_samples_match_all_pinned_rules:
  let data = readFile("tests/fixtures/plural_samples.txt")
  var checked = 0
  for line in data.splitLines:
    if line.len == 0 or line.startsWith("#"): continue
    let kindEnd = line.find(' ')
    let languagesEnd = line.find(' ', kindEnd + 1)
    let categoryEnd = line.find(' ', languagesEnd + 1)
    doAssert kindEnd > 0 and languagesEnd > kindEnd and categoryEnd > languagesEnd
    let ordinal = line[0 ..< kindEnd] == "ordinal"
    let expected = line[languagesEnd + 1 ..< categoryEnd]
    let languages = line[kindEnd + 1 ..< languagesEnd].split(',')
    let samples = expandSamples(line[categoryEnd + 1 .. ^1])
    for sample in samples:
      for language in languages:
        doAssert category(language, sample, ordinal) == expected,
          language & " " & (if ordinal: "ordinal " else: "cardinal ") &
          sample & " did not select " & expected
        inc checked
  doAssert checked >= 10_000

block plural_categories_match_icu_golden:
  let golden = parseJson(readFile("tests/fixtures/plurals_icu.json"))
  let numbers = golden["numbers"].getElems
  let categoryByInitial = {
    'z': "zero", 'o': "one", 't': "two", 'f': "few", 'm': "many",
    'x': "other"}.toTable
  var languagesChecked = 0
  for (key, ordinal) in [("cardinal", false), ("ordinal", true)]:
    for locale, expected in golden[key].pairs:
      inc languagesChecked
      let codes = expected.getStr()
      doAssert codes.len == numbers.len
      for index, number in numbers:
        let want = categoryByInitial[codes[index]]
        doAssert category(locale, number.getStr(), ordinal) == want,
          locale & " " & number.getStr() & " (ordinal=" & $ordinal &
          ") did not select " & want
  doAssert languagesChecked >= 250
