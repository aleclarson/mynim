import std/[assertions, math]
import ../src/mynim/i18n as i18n

block decimal_formats_follow_locale_symbols:
  for (locale, value, options, want) in [
      ("en", "1234567.891", i18n.NumberOptions(), "1,234,567.891"),
      ("en", "-42", i18n.NumberOptions(), "-42"),
      ("en", "12345678901234567890.25", i18n.NumberOptions(),
        "12,345,678,901,234,567,890.25"),
      ("de", "1234.5", i18n.NumberOptions(), "1.234,5"),
      ("de-CH", "1234.5", i18n.NumberOptions(), "1'234.5"),
      ("fr", "1234.5", i18n.NumberOptions(), "1 234,5"),
      ("es", "1234", i18n.NumberOptions(), "1234"),
      ("es", "12345", i18n.NumberOptions(), "12.345"),
      ("hi", "12345678", i18n.NumberOptions(), "1,23,45,678"),
      ("en-IN", "12345678", i18n.NumberOptions(), "1,23,45,678"),
      ("fa", "-1234.5", i18n.NumberOptions(), "‎−۱٬۲۳۴٫۵"),
      ("fa-u-nu-latn", "1234.5", i18n.NumberOptions(), "1,234.5"),
      ("ar-EG", "12", i18n.NumberOptions(), "١٢"),
      ("bn", "0.5", i18n.NumberOptions(percent: true), "৫০%")]:
    doAssert i18n.formatNumber(locale, value, options) == want,
      locale & " " & value & " formatted as " &
      i18n.formatNumber(locale, value, options) & ", expected " & want

block precision_and_rounding_options:
  doAssert i18n.formatNumber("en", "1.5",
    i18n.NumberOptions(minFractionDigits: 2)) == "1.50"
  doAssert i18n.formatNumber("en", 1.005,
    i18n.NumberOptions(maxFractionDigits: 2)) == "1.01"
  doAssert i18n.formatNumber("en", "2.5",
    i18n.NumberOptions(integer: true)) == "3"
  doAssert i18n.formatNumber("en", "2.5",
    i18n.NumberOptions(integer: true, halfEven: true)) == "2"
  doAssert i18n.formatNumber("en", "3.5",
    i18n.NumberOptions(integer: true, halfEven: true)) == "4"
  doAssert i18n.formatNumber("en", "0.125",
    i18n.NumberOptions(maxFractionDigits: 2, halfEven: true)) == "0.12"
  doAssert i18n.formatNumber("en", "0.256",
    i18n.NumberOptions(percent: true)) == "26%"
  doAssert i18n.formatNumber("de", "0.25",
    i18n.NumberOptions(percent: true)) == "25 %"
  doAssert i18n.formatNumber("en", "12345",
    i18n.NumberOptions(noGrouping: true)) == "12345"
  doAssert i18n.formatNumber("en", 7,
    i18n.NumberOptions(minIntegerDigits: 2)) == "07"
  doAssert i18n.formatNumber("fa", 7,
    i18n.NumberOptions(minIntegerDigits: 2)) == "۰۷"

block invalid_values_and_special_floats_are_preserved:
  doAssert i18n.formatNumber("en", "lots") == "lots"
  doAssert i18n.formatNumber("en", " 1234.50 ") == "1,234.50"
  doAssert i18n.formatNumber("en", " lots ") == " lots "
  doAssert i18n.formatNumber("en", NaN) == "NaN"
  doAssert i18n.formatNumber("en", NegInf) == "-∞"
