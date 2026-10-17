import std/[assertions, strutils]
import ../src/mynim/i18n as i18n

block message_arguments_keep_first_use_order_and_kind:
  let message = i18n.mustParseMessage(
    "{host} and {n, plural, offset:1 one {# " &
    "{g, select, a {{host}} other {{when, date, short}}}} " &
    "other {{n, number}}} {x, selectordinal, other {#}} " &
    "{t, time} {p, number, percent}")
  let args = message.args()
  doAssert args.len == 7
  doAssert args[0].name == "host" and args[0].kind == ""
  doAssert args[1].name == "n" and args[1].kind == "plural"
  doAssert args[2].name == "g" and args[2].kind == "select"
  doAssert args[3].name == "when" and args[3].kind == "date"
  doAssert args[4].name == "x" and args[4].kind == "selectordinal"
  doAssert args[5].name == "t" and args[5].kind == "time"
  doAssert args[6].name == "p" and args[6].kind == "number"
  doAssert message.cases("n") == @[
    "one", "other"]
  doAssert message.source.startsWith("{host} and")

block nested_cases_with_the_same_name_are_returned_once:
  let message = i18n.mustParseMessage(
    "{n, plural, =0 {none} one {#} other " &
    "{{n, plural, few {#} other {#}}}}")
  doAssert message.cases("n") == @["=0", "one", "other", "few"]

block unicode_names_and_icu_quotes_parse:
  let source = "'{name}' {état} {字} {n, plural, one {'#'} other {#}}"
  let message = i18n.parseMessage(source)
  doAssert message.source == source
  let args = message.args()
  doAssert args.len == 3
  doAssert args[0].name == "état"
  doAssert args[1].name == "字"
  doAssert args[2].name == "n" and args[2].kind == "plural"

block malformed_messages_report_syntax_errors:
  for source in ["{", "}", "{n, unknown}",
      "{n, plural, one {#}}", "{n, plural, other {#} other {#}}",
      "{01}", "{n, plural, =.1 {x} other {y}}"]:
    var failed = false
    try:
      discard i18n.parseMessage(source)
    except i18n.MessageSyntaxError as error:
      failed = true
      doAssert error.offset >= 0
    doAssert failed, "expected a syntax error for " & source

block deeply_nested_arguments_are_rejected:
  var source = ""
  for _ in 0 ..< 40:
    source = "{a, select, other {" & source & "}}"
  var failed = false
  try:
    discard i18n.parseMessage(source)
  except i18n.MessageSyntaxError:
    failed = true
  doAssert failed
