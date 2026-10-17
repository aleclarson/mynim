## CLDR 48.2 plural rules ported from mygo/i18n/tables.go.

import std/[strutils, math]

type
  Plural* = enum
    pluralZero, pluralOne, pluralTwo, pluralFew, pluralMany, pluralOther

  PluralOperands* = object
    ## The CLDR operands of the absolute value as written.
    i*: uint64
      ## Integer digits.
    v*, w*: int
      ## Visible fraction digits with and without trailing zeros.
    f*, t*: uint64
      ## Fraction digits with and without trailing zeros.
    c*: int
      ## Compact exponent, as in `1.2c6`.

proc pluralName*(plural: Plural): string =
  case plural
  of pluralZero: "zero"
  of pluralOne: "one"
  of pluralTwo: "two"
  of pluralFew: "few"
  of pluralMany: "many"
  of pluralOther: "other"

proc parsePlural*(name: string): tuple[value: Plural, ok: bool] =
  for plural in Plural:
    if plural.pluralName() == name:
      return (plural, true)
  (pluralOther, false)

const bigOperand = 1_000_000_000_000_000_000'u64

proc decimalDigits(value: string): bool =
  for ch in value:
    if ch notin {'0'..'9'}: return false
  true

proc digitsValue(value: string): uint64 =
  var digits = value.strip(leading = true, trailing = false, chars = {'0'})
  let tooLarge = digits.len > 18
  if tooLarge: digits = digits[^18 .. ^1]
  for digit in digits:
    result = result * 10 + uint64(ord(digit) - ord('0'))
  if tooLarge: result += bigOperand

proc parsePluralOperands*(value: string):
    tuple[operands: PluralOperands, ok: bool] =
  ## Parses decimal notation and CLDR compact exponents.
  var decimal = value.strip()
  if decimal.len == 0: return
  if decimal[0] in {'-', '+'}:
    decimal = decimal[1 .. ^1]
  if decimal.len == 0: return

  var exponentAt = -1
  for i, ch in decimal:
    if ch in {'c', 'C', 'e', 'E'}:
      exponentAt = i
      break
  var exponent = 0
  if exponentAt >= 0:
    let exponentText = decimal[exponentAt + 1 .. ^1]
    if exponentText.len == 0 or not decimalDigits(exponentText): return
    try:
      exponent = parseInt(exponentText)
    except ValueError:
      return
    if exponent > 100: return
    decimal.setLen(exponentAt)

  let point = decimal.find('.')
  var integer = if point < 0: decimal else: decimal[0 ..< point]
  var fraction = if point < 0: "" else: decimal[point + 1 .. ^1]
  if (integer.len == 0 and point < 0) or
      (point >= 0 and fraction.len == 0) or
      not decimalDigits(integer) or not decimalDigits(fraction):
    return
  if exponent > 0:
    let shift = min(exponent, fraction.len)
    integer.add fraction[0 ..< shift]
    if shift == fraction.len: fraction.setLen(0)
    else: fraction = fraction[shift .. ^1]
    if exponent > shift:
      integer.add repeat('0', exponent - shift)
  result.operands.i = digitsValue(integer)
  result.operands.v = fraction.len
  result.operands.f = digitsValue(fraction)
  let trimmed = fraction.strip(chars = {'0'}, leading = false, trailing = true)
  result.operands.w = trimmed.len
  result.operands.t = digitsValue(trimmed)
  result.operands.c = exponent
  result.ok = true

proc requirePluralOperands(value: string): PluralOperands =
  let parsed = parsePluralOperands(value)
  if not parsed.ok:
    raise newException(ValueError, "i18n: " & value.escape() &
      " is not a decimal number")
  parsed.operands

proc newPluralOperands*(value: string): PluralOperands =
  ## Parses a decimal string or raises ValueError.
  requirePluralOperands(value)

proc newPluralOperands*[T: SomeInteger](value: T): PluralOperands =
  requirePluralOperands($value)

proc expandExponent(value: string): string =
  let exponentAt = value.find({'e', 'E'})
  if exponentAt < 0: return value
  let mantissa = value[0 ..< exponentAt]
  let exponent = parseInt(value[exponentAt + 1 .. ^1])
  let negative = mantissa.startsWith('-')
  let unsigned = if negative: mantissa[1 .. ^1] else: mantissa
  let point = unsigned.find('.')
  let integerDigits = if point < 0: unsigned.len else: point
  let digits = unsigned.replace(".", "")
  let destination = integerDigits + exponent
  let sign = if negative: "-" else: ""
  if destination <= 0:
    sign & "0." & repeat('0', -destination) & digits
  elif destination >= digits.len:
    sign & digits & repeat('0', destination - digits.len)
  else:
    sign & digits[0 ..< destination] & "." & digits[destination .. ^1]

proc newPluralOperands*[T: SomeFloat](value: T): PluralOperands =
  if classify(value) in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "i18n: a plural value must be finite")
  requirePluralOperands(expandExponent(formatFloat(value, ffDefault, -1)))

const cardinalLangs = [
  "af", "ak", "am", "an", "ar", "ars", "as", "asa", "ast", "az",
  "bal", "be", "bem", "bez", "bg", "bho", "blo", "bm", "bn", "bo",
  "br", "brx", "bs", "ca", "ce", "ceb", "cgg", "chr", "ckb", "cs",
  "csw", "cv", "cy", "da", "de", "doi", "dsb", "dv", "dz", "ee",
  "el", "en", "eo", "es", "et", "eu", "fa", "ff", "fi", "fil",
  "fo", "fr", "fur", "fy", "ga", "gd", "gl", "gsw", "gu", "guw",
  "gv", "ha", "haw", "he", "hi", "hnj", "hr", "hsb", "hu", "hy",
  "ia", "id", "ie", "ig", "ii", "io", "is", "it", "iu", "ja",
  "jbo", "jgo", "jmc", "jv", "jw", "ka", "kab", "kaj", "kcg", "kde",
  "kea", "kk", "kkj", "kl", "km", "kn", "ko", "kok", "kok-Latn", "ks",
  "ksb", "ksh", "ku", "kw", "ky", "lag", "lb", "lg", "lij", "lkt",
  "lld", "ln", "lo", "lt", "lv", "mas", "mg", "mgo", "mk", "ml",
  "mn", "mo", "mr", "ms", "mt", "my", "nah", "naq", "nb", "nd",
  "ne", "nl", "nn", "nnh", "no", "nqo", "nr", "nso", "ny", "nyn",
  "om", "or", "os", "osa", "pa", "pap", "pcm", "pl", "prg", "ps",
  "pt", "pt-PT", "rm", "ro", "rof", "ru", "rwk", "sah", "saq", "sat",
  "sc", "scn", "sd", "sdh", "se", "seh", "ses", "sg", "sgs", "sh",
  "shi", "si", "sk", "sl", "sma", "smi", "smj", "smn", "sms", "sn",
  "so", "sq", "sr", "ss", "ssy", "st", "su", "sv", "sw", "syr",
  "ta", "te", "teo", "th", "ti", "tig", "tk", "tl", "tn", "to",
  "tpi", "tr", "ts", "tzm", "ug", "uk", "und", "ur", "uz", "ve",
  "vec", "vi", "vo", "vun", "wa", "wae", "wo", "xh", "xog", "yi",
  "yo", "yue", "zh", "zu"
]

const cardinalRules = [
  1, 2, 3, 1, 4, 4, 3, 1, 5, 1,
  1, 6, 1, 1, 1, 2, 7, 0, 3, 0,
  8, 1, 9, 10, 1, 11, 1, 1, 1, 12,
  2, 7, 13, 14, 5, 3, 15, 1, 0, 1,
  1, 5, 1, 16, 5, 1, 3, 17, 5, 11,
  1, 18, 1, 5, 19, 20, 5, 1, 3, 2,
  21, 1, 1, 22, 3, 0, 9, 15, 1, 17,
  5, 0, 5, 0, 0, 5, 23, 10, 24, 0,
  0, 1, 1, 0, 0, 1, 17, 1, 1, 0,
  0, 1, 1, 1, 0, 3, 0, 3, 3, 1,
  1, 7, 1, 25, 1, 26, 1, 1, 5, 0,
  10, 2, 0, 27, 28, 1, 2, 1, 29, 1,
  1, 30, 1, 0, 31, 0, 1, 24, 1, 1,
  1, 5, 1, 1, 1, 0, 1, 2, 1, 1,
  1, 1, 1, 0, 2, 1, 3, 32, 28, 1,
  33, 10, 1, 30, 1, 34, 1, 0, 1, 24,
  5, 10, 1, 1, 24, 1, 0, 0, 35, 9,
  36, 37, 12, 38, 24, 24, 24, 24, 24, 1,
  1, 1, 9, 1, 1, 1, 0, 5, 5, 1,
  1, 1, 1, 0, 2, 1, 1, 11, 1, 0,
  0, 1, 1, 39, 1, 34, 0, 5, 1, 1,
  10, 0, 1, 1, 2, 1, 0, 1, 1, 5,
  0, 0, 0, 3
]

const cardinalCategoryMasks = [
  32, 34, 34, 34, 63, 34, 58, 35, 62, 42,
  50, 34, 58, 63, 34, 46, 50, 34, 50, 62,
  46, 62, 38, 34, 38, 63, 35, 58, 35, 34,
  42, 62, 58, 50, 58, 62, 42, 34, 46, 34
]

const ordinalLangs = [
  "af", "am", "an", "ar", "as", "ast", "az", "bal", "be", "bg",
  "blo", "bn", "bs", "ca", "ce", "cs", "cv", "cy", "da", "de",
  "dsb", "el", "en", "es", "et", "eu", "fa", "fi", "fil", "fr",
  "fy", "ga", "gd", "gl", "gsw", "gu", "he", "hi", "hr", "hsb",
  "hu", "hy", "ia", "id", "ie", "is", "it", "ja", "ka", "kk",
  "km", "kn", "ko", "kok", "kok-Latn", "kw", "ky", "lij", "lld", "lo",
  "lt", "lv", "mk", "ml", "mn", "mo", "mr", "ms", "my", "nb",
  "ne", "nl", "no", "or", "pa", "pl", "prg", "ps", "pt", "ro",
  "ru", "sc", "scn", "sd", "sh", "si", "sk", "sl", "sq", "sr",
  "sv", "sw", "ta", "te", "th", "tk", "tl", "tpi", "tr", "uk",
  "und", "ur", "uz", "vec", "vi", "yue", "zh", "zu"
]

const ordinalRules = [
  0, 0, 0, 0, 1, 0, 2, 3, 4, 0,
  5, 1, 0, 6, 0, 0, 0, 7, 0, 0,
  0, 0, 8, 0, 0, 0, 0, 0, 3, 3,
  0, 3, 9, 0, 0, 10, 0, 10, 0, 0,
  11, 3, 0, 0, 0, 0, 12, 0, 13, 14,
  0, 0, 0, 15, 15, 16, 0, 17, 12, 3,
  0, 0, 18, 0, 0, 3, 15, 3, 0, 0,
  19, 0, 0, 20, 0, 0, 0, 0, 0, 3,
  0, 12, 17, 0, 0, 0, 0, 0, 21, 0,
  22, 0, 0, 0, 0, 23, 3, 0, 0, 24,
  0, 0, 0, 12, 3, 0, 0, 0
]

const ordinalCategoryMasks = [
  32, 62, 58, 34, 40, 43, 46, 63, 46, 46,
  62, 34, 48, 50, 48, 46, 50, 48, 54, 34,
  62, 50, 34, 40, 40
]

proc cardinalRule(rule: int; o: PluralOperands): Plural =
  case rule
  of 1:
    ## n = 1
    if o.f == 0  and  o.i == 1 :
      return pluralOne
  of 2:
    ## n = 0..1
    if o.f == 0  and  o.i <= 1 :
      return pluralOne
  of 3:
    ## i = 0 or n = 1
    if o.i == 0  or  (o.f == 0  and  o.i == 1) :
      return pluralOne
  of 4:
    ## n = 0
    if o.f == 0  and  o.i == 0 :
      return pluralZero
    ## n = 1
    if o.f == 0  and  o.i == 1 :
      return pluralOne
    ## n = 2
    if o.f == 0  and  o.i == 2 :
      return pluralTwo
    ## n % 100 = 3..10
    if o.f == 0  and  (o.i mod 100 >= 3  and  o.i mod 100 <= 10) :
      return pluralFew
    ## n % 100 = 11..99
    if o.f == 0  and  (o.i mod 100 >= 11  and  o.i mod 100 <= 99) :
      return pluralMany
  of 5:
    ## i = 1 and v = 0
    if o.i == 1  and  o.v == 0 :
      return pluralOne
  of 6:
    ## n % 10 = 1 and n % 100 != 11
    if o.f == 0  and  o.i mod 10 == 1  and  not (o.i mod 100 == 11) :
      return pluralOne
    ## n % 10 = 2..4 and n % 100 != 12..14
    if o.f == 0  and  (o.i mod 10 >= 2  and  o.i mod 10 <= 4)  and  not (o.i mod 100 >= 12  and  o.i mod 100 <= 14) :
      return pluralFew
    ## n % 10 = 0 or n % 10 = 5..9 or n % 100 = 11..14
    if (o.f == 0  and  o.i mod 10 == 0)  or  (o.f == 0  and  (o.i mod 10 >= 5  and  o.i mod 10 <= 9))  or  (o.f == 0  and  (o.i mod 100 >= 11  and  o.i mod 100 <= 14)) :
      return pluralMany
  of 7:
    ## n = 0
    if o.f == 0  and  o.i == 0 :
      return pluralZero
    ## n = 1
    if o.f == 0  and  o.i == 1 :
      return pluralOne
  of 8:
    ## n % 10 = 1 and n % 100 != 11,71,91
    if o.f == 0  and  o.i mod 10 == 1  and  not (o.i mod 100 == 11  or  o.i mod 100 == 71  or  o.i mod 100 == 91) :
      return pluralOne
    ## n % 10 = 2 and n % 100 != 12,72,92
    if o.f == 0  and  o.i mod 10 == 2  and  not (o.i mod 100 == 12  or  o.i mod 100 == 72  or  o.i mod 100 == 92) :
      return pluralTwo
    ## n % 10 = 3..4,9 and n % 100 != 10..19,70..79,90..99
    if o.f == 0  and  (o.i mod 10 >= 3  and  o.i mod 10 <= 4  or  o.i mod 10 == 9)  and  not (o.i mod 100 >= 10  and  o.i mod 100 <= 19  or  o.i mod 100 >= 70  and  o.i mod 100 <= 79  or  o.i mod 100 >= 90  and  o.i mod 100 <= 99) :
      return pluralFew
    ## n != 0 and n % 1000000 = 0
    if o.f == 0  and  not (o.i == 0)  and  o.i mod 1000000 == 0 :
      return pluralMany
  of 9:
    ## v = 0 and i % 10 = 1 and i % 100 != 11 or f % 10 = 1 and f % 100 != 11
    if (o.v == 0  and  o.i mod 10 == 1  and  not (o.i mod 100 == 11))  or  (o.f mod 10 == 1  and  not (o.f mod 100 == 11)) :
      return pluralOne
    ## v = 0 and i % 10 = 2..4 and i % 100 != 12..14 or f % 10 = 2..4 and f % 100 != 12..14
    if (o.v == 0  and  (o.i mod 10 >= 2  and  o.i mod 10 <= 4)  and  not (o.i mod 100 >= 12  and  o.i mod 100 <= 14))  or  ((o.f mod 10 >= 2  and  o.f mod 10 <= 4)  and  not (o.f mod 100 >= 12  and  o.f mod 100 <= 14)) :
      return pluralFew
  of 10:
    ## i = 1 and v = 0
    if o.i == 1  and  o.v == 0 :
      return pluralOne
    ## e = 0 and i != 0 and i % 1000000 = 0 and v = 0 or e != 0..5
    if (o.c == 0  and  not (o.i == 0)  and  o.i mod 1000000 == 0  and  o.v == 0)  or  not (o.c <= 5) :
      return pluralMany
  of 11:
    ## v = 0 and i = 1,2,3 or v = 0 and i % 10 != 4,6,9 or v != 0 and f % 10 != 4,6,9
    if (o.v == 0  and  (o.i == 1  or  o.i == 2  or  o.i == 3))  or  (o.v == 0  and  not (o.i mod 10 == 4  or  o.i mod 10 == 6  or  o.i mod 10 == 9))  or  (not (o.v == 0)  and  not (o.f mod 10 == 4  or  o.f mod 10 == 6  or  o.f mod 10 == 9)) :
      return pluralOne
  of 12:
    ## i = 1 and v = 0
    if o.i == 1  and  o.v == 0 :
      return pluralOne
    ## i = 2..4 and v = 0
    if (o.i >= 2  and  o.i <= 4)  and  o.v == 0 :
      return pluralFew
    ## v != 0
    if not (o.v == 0) :
      return pluralMany
  of 13:
    ## n = 0
    if o.f == 0  and  o.i == 0 :
      return pluralZero
    ## n = 1
    if o.f == 0  and  o.i == 1 :
      return pluralOne
    ## n = 2
    if o.f == 0  and  o.i == 2 :
      return pluralTwo
    ## n = 3
    if o.f == 0  and  o.i == 3 :
      return pluralFew
    ## n = 6
    if o.f == 0  and  o.i == 6 :
      return pluralMany
  of 14:
    ## n = 1 or t != 0 and i = 0,1
    if (o.f == 0  and  o.i == 1)  or  (not (o.t == 0)  and  (o.i == 0  or  o.i == 1)) :
      return pluralOne
  of 15:
    ## v = 0 and i % 100 = 1 or f % 100 = 1
    if (o.v == 0  and  o.i mod 100 == 1)  or  o.f mod 100 == 1 :
      return pluralOne
    ## v = 0 and i % 100 = 2 or f % 100 = 2
    if (o.v == 0  and  o.i mod 100 == 2)  or  o.f mod 100 == 2 :
      return pluralTwo
    ## v = 0 and i % 100 = 3..4 or f % 100 = 3..4
    if (o.v == 0  and  (o.i mod 100 >= 3  and  o.i mod 100 <= 4))  or  (o.f mod 100 >= 3  and  o.f mod 100 <= 4) :
      return pluralFew
  of 16:
    ## n = 1
    if o.f == 0  and  o.i == 1 :
      return pluralOne
    ## e = 0 and i != 0 and i % 1000000 = 0 and v = 0 or e != 0..5
    if (o.c == 0  and  not (o.i == 0)  and  o.i mod 1000000 == 0  and  o.v == 0)  or  not (o.c <= 5) :
      return pluralMany
  of 17:
    ## i = 0,1
    if o.i == 0  or  o.i == 1 :
      return pluralOne
  of 18:
    ## i = 0,1
    if o.i == 0  or  o.i == 1 :
      return pluralOne
    ## e = 0 and i != 0 and i % 1000000 = 0 and v = 0 or e != 0..5
    if (o.c == 0  and  not (o.i == 0)  and  o.i mod 1000000 == 0  and  o.v == 0)  or  not (o.c <= 5) :
      return pluralMany
  of 19:
    ## n = 1
    if o.f == 0  and  o.i == 1 :
      return pluralOne
    ## n = 2
    if o.f == 0  and  o.i == 2 :
      return pluralTwo
    ## n = 3..6
    if o.f == 0  and  (o.i >= 3  and  o.i <= 6) :
      return pluralFew
    ## n = 7..10
    if o.f == 0  and  (o.i >= 7  and  o.i <= 10) :
      return pluralMany
  of 20:
    ## n = 1,11
    if o.f == 0  and  (o.i == 1  or  o.i == 11) :
      return pluralOne
    ## n = 2,12
    if o.f == 0  and  (o.i == 2  or  o.i == 12) :
      return pluralTwo
    ## n = 3..10,13..19
    if o.f == 0  and  (o.i >= 3  and  o.i <= 10  or  o.i >= 13  and  o.i <= 19) :
      return pluralFew
  of 21:
    ## v = 0 and i % 10 = 1
    if o.v == 0  and  o.i mod 10 == 1 :
      return pluralOne
    ## v = 0 and i % 10 = 2
    if o.v == 0  and  o.i mod 10 == 2 :
      return pluralTwo
    ## v = 0 and i % 100 = 0,20,40,60,80
    if o.v == 0  and  (o.i mod 100 == 0  or  o.i mod 100 == 20  or  o.i mod 100 == 40  or  o.i mod 100 == 60  or  o.i mod 100 == 80) :
      return pluralFew
    ## v != 0
    if not (o.v == 0) :
      return pluralMany
  of 22:
    ## i = 1 and v = 0 or i = 0 and v != 0
    if (o.i == 1  and  o.v == 0)  or  (o.i == 0  and  not (o.v == 0)) :
      return pluralOne
    ## i = 2 and v = 0
    if o.i == 2  and  o.v == 0 :
      return pluralTwo
  of 23:
    ## t = 0 and i % 10 = 1 and i % 100 != 11 or t % 10 = 1 and t % 100 != 11
    if (o.t == 0  and  o.i mod 10 == 1  and  not (o.i mod 100 == 11))  or  (o.t mod 10 == 1  and  not (o.t mod 100 == 11)) :
      return pluralOne
  of 24:
    ## n = 1
    if o.f == 0  and  o.i == 1 :
      return pluralOne
    ## n = 2
    if o.f == 0  and  o.i == 2 :
      return pluralTwo
  of 25:
    ## n = 0
    if o.f == 0  and  o.i == 0 :
      return pluralZero
    ## n = 1
    if o.f == 0  and  o.i == 1 :
      return pluralOne
    ## n % 100 = 2,22,42,62,82 or n % 1000 = 0 and n % 100000 = 1000..20000,40000,60000,80000 or n != 0 and n % 1000000 = 100000
    if (o.f == 0  and  (o.i mod 100 == 2  or  o.i mod 100 == 22  or  o.i mod 100 == 42  or  o.i mod 100 == 62  or  o.i mod 100 == 82))  or  (o.f == 0  and  o.i mod 1000 == 0  and  (o.i mod 100000 >= 1000  and  o.i mod 100000 <= 20000  or  o.i mod 100000 == 40000  or  o.i mod 100000 == 60000  or  o.i mod 100000 == 80000))  or  (o.f == 0  and  not (o.i == 0)  and  o.i mod 1000000 == 100000) :
      return pluralTwo
    ## n % 100 = 3,23,43,63,83
    if o.f == 0  and  (o.i mod 100 == 3  or  o.i mod 100 == 23  or  o.i mod 100 == 43  or  o.i mod 100 == 63  or  o.i mod 100 == 83) :
      return pluralFew
    ## n != 1 and n % 100 = 1,21,41,61,81
    if o.f == 0  and  not (o.i == 1)  and  (o.i mod 100 == 1  or  o.i mod 100 == 21  or  o.i mod 100 == 41  or  o.i mod 100 == 61  or  o.i mod 100 == 81) :
      return pluralMany
  of 26:
    ## n = 0
    if o.f == 0  and  o.i == 0 :
      return pluralZero
    ## i = 0,1 and n != 0
    if (o.i == 0  or  o.i == 1)  and  not (o.f == 0  and  (o.i == 0)) :
      return pluralOne
  of 27:
    ## n % 10 = 1 and n % 100 != 11..19
    if o.f == 0  and  o.i mod 10 == 1  and  not (o.i mod 100 >= 11  and  o.i mod 100 <= 19) :
      return pluralOne
    ## n % 10 = 2..9 and n % 100 != 11..19
    if o.f == 0  and  (o.i mod 10 >= 2  and  o.i mod 10 <= 9)  and  not (o.i mod 100 >= 11  and  o.i mod 100 <= 19) :
      return pluralFew
    ## f != 0
    if not (o.f == 0) :
      return pluralMany
  of 28:
    ## n % 10 = 0 or n % 100 = 11..19 or v = 2 and f % 100 = 11..19
    if (o.f == 0  and  o.i mod 10 == 0)  or  (o.f == 0  and  (o.i mod 100 >= 11  and  o.i mod 100 <= 19))  or  (o.v == 2  and  (o.f mod 100 >= 11  and  o.f mod 100 <= 19)) :
      return pluralZero
    ## n % 10 = 1 and n % 100 != 11 or v = 2 and f % 10 = 1 and f % 100 != 11 or v != 2 and f % 10 = 1
    if (o.f == 0  and  o.i mod 10 == 1  and  not (o.i mod 100 == 11))  or  (o.v == 2  and  o.f mod 10 == 1  and  not (o.f mod 100 == 11))  or  (not (o.v == 2)  and  o.f mod 10 == 1) :
      return pluralOne
  of 29:
    ## v = 0 and i % 10 = 1 and i % 100 != 11 or f % 10 = 1 and f % 100 != 11
    if (o.v == 0  and  o.i mod 10 == 1  and  not (o.i mod 100 == 11))  or  (o.f mod 10 == 1  and  not (o.f mod 100 == 11)) :
      return pluralOne
  of 30:
    ## i = 1 and v = 0
    if o.i == 1  and  o.v == 0 :
      return pluralOne
    ## v != 0 or n = 0 or n != 1 and n % 100 = 1..19
    if not (o.v == 0)  or  (o.f == 0  and  o.i == 0)  or  (o.f == 0  and  not (o.i == 1)  and  (o.i mod 100 >= 1  and  o.i mod 100 <= 19)) :
      return pluralFew
  of 31:
    ## n = 1
    if o.f == 0  and  o.i == 1 :
      return pluralOne
    ## n = 2
    if o.f == 0  and  o.i == 2 :
      return pluralTwo
    ## n = 0 or n % 100 = 3..10
    if (o.f == 0  and  o.i == 0)  or  (o.f == 0  and  (o.i mod 100 >= 3  and  o.i mod 100 <= 10)) :
      return pluralFew
    ## n % 100 = 11..19
    if o.f == 0  and  (o.i mod 100 >= 11  and  o.i mod 100 <= 19) :
      return pluralMany
  of 32:
    ## i = 1 and v = 0
    if o.i == 1  and  o.v == 0 :
      return pluralOne
    ## v = 0 and i % 10 = 2..4 and i % 100 != 12..14
    if o.v == 0  and  (o.i mod 10 >= 2  and  o.i mod 10 <= 4)  and  not (o.i mod 100 >= 12  and  o.i mod 100 <= 14) :
      return pluralFew
    ## v = 0 and i != 1 and i % 10 = 0..1 or v = 0 and i % 10 = 5..9 or v = 0 and i % 100 = 12..14
    if (o.v == 0  and  not (o.i == 1)  and  o.i mod 10 <= 1)  or  (o.v == 0  and  (o.i mod 10 >= 5  and  o.i mod 10 <= 9))  or  (o.v == 0  and  (o.i mod 100 >= 12  and  o.i mod 100 <= 14)) :
      return pluralMany
  of 33:
    ## i = 0..1
    if o.i <= 1 :
      return pluralOne
    ## e = 0 and i != 0 and i % 1000000 = 0 and v = 0 or e != 0..5
    if (o.c == 0  and  not (o.i == 0)  and  o.i mod 1000000 == 0  and  o.v == 0)  or  not (o.c <= 5) :
      return pluralMany
  of 34:
    ## v = 0 and i % 10 = 1 and i % 100 != 11
    if o.v == 0  and  o.i mod 10 == 1  and  not (o.i mod 100 == 11) :
      return pluralOne
    ## v = 0 and i % 10 = 2..4 and i % 100 != 12..14
    if o.v == 0  and  (o.i mod 10 >= 2  and  o.i mod 10 <= 4)  and  not (o.i mod 100 >= 12  and  o.i mod 100 <= 14) :
      return pluralFew
    ## v = 0 and i % 10 = 0 or v = 0 and i % 10 = 5..9 or v = 0 and i % 100 = 11..14
    if (o.v == 0  and  o.i mod 10 == 0)  or  (o.v == 0  and  (o.i mod 10 >= 5  and  o.i mod 10 <= 9))  or  (o.v == 0  and  (o.i mod 100 >= 11  and  o.i mod 100 <= 14)) :
      return pluralMany
  of 35:
    ## n % 10 = 1 and n % 100 != 11
    if o.f == 0  and  o.i mod 10 == 1  and  not (o.i mod 100 == 11) :
      return pluralOne
    ## n = 2
    if o.f == 0  and  o.i == 2 :
      return pluralTwo
    ## n != 2 and n % 10 = 2..9 and n % 100 != 11..19
    if o.f == 0  and  not (o.i == 2)  and  (o.i mod 10 >= 2  and  o.i mod 10 <= 9)  and  not (o.i mod 100 >= 11  and  o.i mod 100 <= 19) :
      return pluralFew
    ## f != 0
    if not (o.f == 0) :
      return pluralMany
  of 36:
    ## i = 0 or n = 1
    if o.i == 0  or  (o.f == 0  and  o.i == 1) :
      return pluralOne
    ## n = 2..10
    if o.f == 0  and  (o.i >= 2  and  o.i <= 10) :
      return pluralFew
  of 37:
    ## n = 0,1 or i = 0 and f = 1
    if (o.f == 0  and  (o.i == 0  or  o.i == 1))  or  (o.i == 0  and  o.f == 1) :
      return pluralOne
  of 38:
    ## v = 0 and i % 100 = 1
    if o.v == 0  and  o.i mod 100 == 1 :
      return pluralOne
    ## v = 0 and i % 100 = 2
    if o.v == 0  and  o.i mod 100 == 2 :
      return pluralTwo
    ## v = 0 and i % 100 = 3..4 or v != 0
    if (o.v == 0  and  (o.i mod 100 >= 3  and  o.i mod 100 <= 4))  or  not (o.v == 0) :
      return pluralFew
  of 39:
    ## n = 0..1 or n = 11..99
    if (o.f == 0  and  o.i <= 1)  or  (o.f == 0  and  (o.i >= 11  and  o.i <= 99)) :
      return pluralOne
  else: discard
  pluralOther

proc ordinalRule(rule: int; o: PluralOperands): Plural =
  case rule
  of 1:
    ## n = 1,5,7,8,9,10
    if o.f == 0  and  (o.i == 1  or  o.i == 5  or  o.i == 7  or  o.i == 8  or  o.i == 9  or  o.i == 10) :
      return pluralOne
    ## n = 2,3
    if o.f == 0  and  (o.i == 2  or  o.i == 3) :
      return pluralTwo
    ## n = 4
    if o.f == 0  and  o.i == 4 :
      return pluralFew
    ## n = 6
    if o.f == 0  and  o.i == 6 :
      return pluralMany
  of 2:
    ## i % 10 = 1,2,5,7,8 or i % 100 = 20,50,70,80
    if (o.i mod 10 == 1  or  o.i mod 10 == 2  or  o.i mod 10 == 5  or  o.i mod 10 == 7  or  o.i mod 10 == 8)  or  (o.i mod 100 == 20  or  o.i mod 100 == 50  or  o.i mod 100 == 70  or  o.i mod 100 == 80) :
      return pluralOne
    ## i % 10 = 3,4 or i % 1000 = 100,200,300,400,500,600,700,800,900
    if (o.i mod 10 == 3  or  o.i mod 10 == 4)  or  (o.i mod 1000 == 100  or  o.i mod 1000 == 200  or  o.i mod 1000 == 300  or  o.i mod 1000 == 400  or  o.i mod 1000 == 500  or  o.i mod 1000 == 600  or  o.i mod 1000 == 700  or  o.i mod 1000 == 800  or  o.i mod 1000 == 900) :
      return pluralFew
    ## i = 0 or i % 10 = 6 or i % 100 = 40,60,90
    if o.i == 0  or  o.i mod 10 == 6  or  (o.i mod 100 == 40  or  o.i mod 100 == 60  or  o.i mod 100 == 90) :
      return pluralMany
  of 3:
    ## n = 1
    if o.f == 0  and  o.i == 1 :
      return pluralOne
  of 4:
    ## n % 10 = 2,3 and n % 100 != 12,13
    if o.f == 0  and  (o.i mod 10 == 2  or  o.i mod 10 == 3)  and  not (o.i mod 100 == 12  or  o.i mod 100 == 13) :
      return pluralFew
  of 5:
    ## i = 0
    if o.i == 0 :
      return pluralZero
    ## i = 1
    if o.i == 1 :
      return pluralOne
    ## i = 2,3,4,5,6
    if o.i == 2  or  o.i == 3  or  o.i == 4  or  o.i == 5  or  o.i == 6 :
      return pluralFew
  of 6:
    ## n = 1,3
    if o.f == 0  and  (o.i == 1  or  o.i == 3) :
      return pluralOne
    ## n = 2
    if o.f == 0  and  o.i == 2 :
      return pluralTwo
    ## n = 4
    if o.f == 0  and  o.i == 4 :
      return pluralFew
  of 7:
    ## n = 0,7,8,9
    if o.f == 0  and  (o.i == 0  or  o.i == 7  or  o.i == 8  or  o.i == 9) :
      return pluralZero
    ## n = 1
    if o.f == 0  and  o.i == 1 :
      return pluralOne
    ## n = 2
    if o.f == 0  and  o.i == 2 :
      return pluralTwo
    ## n = 3,4
    if o.f == 0  and  (o.i == 3  or  o.i == 4) :
      return pluralFew
    ## n = 5,6
    if o.f == 0  and  (o.i == 5  or  o.i == 6) :
      return pluralMany
  of 8:
    ## n % 10 = 1 and n % 100 != 11
    if o.f == 0  and  o.i mod 10 == 1  and  not (o.i mod 100 == 11) :
      return pluralOne
    ## n % 10 = 2 and n % 100 != 12
    if o.f == 0  and  o.i mod 10 == 2  and  not (o.i mod 100 == 12) :
      return pluralTwo
    ## n % 10 = 3 and n % 100 != 13
    if o.f == 0  and  o.i mod 10 == 3  and  not (o.i mod 100 == 13) :
      return pluralFew
  of 9:
    ## n = 1,11
    if o.f == 0  and  (o.i == 1  or  o.i == 11) :
      return pluralOne
    ## n = 2,12
    if o.f == 0  and  (o.i == 2  or  o.i == 12) :
      return pluralTwo
    ## n = 3,13
    if o.f == 0  and  (o.i == 3  or  o.i == 13) :
      return pluralFew
  of 10:
    ## n = 1
    if o.f == 0  and  o.i == 1 :
      return pluralOne
    ## n = 2,3
    if o.f == 0  and  (o.i == 2  or  o.i == 3) :
      return pluralTwo
    ## n = 4
    if o.f == 0  and  o.i == 4 :
      return pluralFew
    ## n = 6
    if o.f == 0  and  o.i == 6 :
      return pluralMany
  of 11:
    ## n = 1,5
    if o.f == 0  and  (o.i == 1  or  o.i == 5) :
      return pluralOne
  of 12:
    ## n = 11,8,80,800
    if o.f == 0  and  (o.i == 11  or  o.i == 8  or  o.i == 80  or  o.i == 800) :
      return pluralMany
  of 13:
    ## i = 1
    if o.i == 1 :
      return pluralOne
    ## i = 0 or i % 100 = 2..20,40,60,80
    if o.i == 0  or  (o.i mod 100 >= 2  and  o.i mod 100 <= 20  or  o.i mod 100 == 40  or  o.i mod 100 == 60  or  o.i mod 100 == 80) :
      return pluralMany
  of 14:
    ## n % 10 = 6 or n % 10 = 9 or n % 10 = 0 and n != 0
    if (o.f == 0  and  o.i mod 10 == 6)  or  (o.f == 0  and  o.i mod 10 == 9)  or  (o.f == 0  and  o.i mod 10 == 0  and  not (o.i == 0)) :
      return pluralMany
  of 15:
    ## n = 1
    if o.f == 0  and  o.i == 1 :
      return pluralOne
    ## n = 2,3
    if o.f == 0  and  (o.i == 2  or  o.i == 3) :
      return pluralTwo
    ## n = 4
    if o.f == 0  and  o.i == 4 :
      return pluralFew
  of 16:
    ## n = 1..4 or n % 100 = 1..4,21..24,41..44,61..64,81..84
    if (o.f == 0  and  (o.i >= 1  and  o.i <= 4))  or  (o.f == 0  and  (o.i mod 100 >= 1  and  o.i mod 100 <= 4  or  o.i mod 100 >= 21  and  o.i mod 100 <= 24  or  o.i mod 100 >= 41  and  o.i mod 100 <= 44  or  o.i mod 100 >= 61  and  o.i mod 100 <= 64  or  o.i mod 100 >= 81  and  o.i mod 100 <= 84)) :
      return pluralOne
    ## n = 5 or n % 100 = 5
    if (o.f == 0  and  o.i == 5)  or  (o.f == 0  and  o.i mod 100 == 5) :
      return pluralMany
  of 17:
    ## n = 11,8,80..89,800..899
    if o.f == 0  and  (o.i == 11  or  o.i == 8  or  o.i >= 80  and  o.i <= 89  or  o.i >= 800  and  o.i <= 899) :
      return pluralMany
  of 18:
    ## i % 10 = 1 and i % 100 != 11
    if o.i mod 10 == 1  and  not (o.i mod 100 == 11) :
      return pluralOne
    ## i % 10 = 2 and i % 100 != 12
    if o.i mod 10 == 2  and  not (o.i mod 100 == 12) :
      return pluralTwo
    ## i % 10 = 7,8 and i % 100 != 17,18
    if (o.i mod 10 == 7  or  o.i mod 10 == 8)  and  not (o.i mod 100 == 17  or  o.i mod 100 == 18) :
      return pluralMany
  of 19:
    ## n = 1..4
    if o.f == 0  and  (o.i >= 1  and  o.i <= 4) :
      return pluralOne
  of 20:
    ## n = 1,5,7..9
    if o.f == 0  and  (o.i == 1  or  o.i == 5  or  o.i >= 7  and  o.i <= 9) :
      return pluralOne
    ## n = 2,3
    if o.f == 0  and  (o.i == 2  or  o.i == 3) :
      return pluralTwo
    ## n = 4
    if o.f == 0  and  o.i == 4 :
      return pluralFew
    ## n = 6
    if o.f == 0  and  o.i == 6 :
      return pluralMany
  of 21:
    ## n = 1
    if o.f == 0  and  o.i == 1 :
      return pluralOne
    ## n % 10 = 4 and n % 100 != 14
    if o.f == 0  and  o.i mod 10 == 4  and  not (o.i mod 100 == 14) :
      return pluralMany
  of 22:
    ## n % 10 = 1,2 and n % 100 != 11,12
    if o.f == 0  and  (o.i mod 10 == 1  or  o.i mod 10 == 2)  and  not (o.i mod 100 == 11  or  o.i mod 100 == 12) :
      return pluralOne
  of 23:
    ## n % 10 = 6,9 or n = 10
    if (o.f == 0  and  (o.i mod 10 == 6  or  o.i mod 10 == 9))  or  (o.f == 0  and  o.i == 10) :
      return pluralFew
  of 24:
    ## n % 10 = 3 and n % 100 != 13
    if o.f == 0  and  o.i mod 10 == 3  and  not (o.i mod 100 == 13) :
      return pluralFew
  else: discard
  pluralOther


proc pluralRuleOf(locale: string; langs: openArray[string];
    rules: openArray[int]): int =
  var tag = locale
  while tag.len > 0:
    var low = 0
    var high = langs.len
    while low < high:
      let middle = low + (high - low) div 2
      if langs[middle] < tag: low = middle + 1
      else: high = middle
    if low < langs.len and langs[low] == tag:
      return rules[low]
    let dash = tag.rfind('-')
    if dash < 0: break
    tag.setLen(dash)

proc categories(mask: int): seq[Plural] =
  for plural in Plural:
    if (mask and (1 shl ord(plural))) != 0:
      result.add plural

proc cardinalCategory*(locale: string; operands: PluralOperands): Plural =
  cardinalRule(pluralRuleOf(locale, cardinalLangs, cardinalRules), operands)

proc ordinalCategory*(locale: string; operands: PluralOperands): Plural =
  ordinalRule(pluralRuleOf(locale, ordinalLangs, ordinalRules), operands)

proc pluralCategories*(locale: string): seq[Plural] =
  categories(cardinalCategoryMasks[pluralRuleOf(locale, cardinalLangs, cardinalRules)])

proc ordinalCategories*(locale: string): seq[Plural] =
  categories(ordinalCategoryMasks[pluralRuleOf(locale, ordinalLangs, ordinalRules)])
