import std/[json, os, strutils, times, unittest]
import ../src/mynim/i18n as mygoI18n

proc formatArg(name: string; value: JsonNode): mygoI18n.FormatArg =
  case value.kind
  of JString: mygoI18n.formatArg(name, value.getStr())
  of JBool: mygoI18n.formatArg(name, value.getBool())
  of JInt: mygoI18n.formatArg(name, value.getBiggestInt())
  of JFloat: mygoI18n.formatArg(name, value.getFloat())
  of JNull: mygoI18n.nullFormatArg(name)
  else: raise newException(ValueError, "unsupported fixture argument: " & $value.kind)

proc formatFixture(message: JsonNode): string =
  var args: seq[mygoI18n.FormatArg]
  if message.hasKey("args"):
    for name, value in message["args"]:
      args.add formatArg(name, value)
  let locale = if message.hasKey("locale"): message["locale"].getStr() else: "en"
  mygoI18n.format(mygoI18n.parseMessage(message["message"].getStr()), locale,
    args)

suite "ICU message formatting":
  test "matches upstream message and plural fixtures":
    let path = currentSourcePath().parentDir / "fixtures" / "i18n_messages.json"
    let fixture = parseFile(path)
    var failures: seq[string]
    for i in 0 ..< fixture["format"].len:
      let message = fixture["format"][i]
      let got = formatFixture(message)
      let want = message["want"].getStr()
      if got != want:
        failures.add $i & " " & $message["message"] &
          " got=" & got.escape() & " want=" & want.escape()
    check failures.len == 0
    if failures.len > 0:
      for failure in failures:
        echo failure

  test "matches upstream pseudo-locale fixtures":
    let path = currentSourcePath().parentDir / "fixtures" / "i18n_messages.json"
    let fixture = parseFile(path)
    for message in fixture["pseudo"]:
      check formatFixture(message) == message["want"].getStr()

  test "rejects upstream malformed message fixtures":
    let path = currentSourcePath().parentDir / "fixtures" / "i18n_messages.json"
    let fixture = parseFile(path)
    for message in fixture["errors"]:
      var rejected = false
      try:
        discard mygoI18n.parseMessage(message.getStr())
      except mygoI18n.MessageSyntaxError:
        rejected = true
      check rejected

  test "a select nested inside a plural treats pound as literal":
    let message = mygoI18n.parseMessage(
      "{n, plural, other {{g, select, a {#} other {#}}}}")
    check mygoI18n.format(message, "en",
      mygoI18n.formatArg("n", 4), mygoI18n.formatArg("g", "a")) == "#"

  test "a nested plural shadows and restores the outer pound value":
    let message = mygoI18n.parseMessage(
      "{n, plural, other {{m, plural, other {# of #}}}}")
    check mygoI18n.format(message, "en", mygoI18n.formatArg("n", 5),
      mygoI18n.formatArg("m", 2)) == "2 of 2"

  test "formats date and time arguments with ICU styles":
    let day = dateTime(2026, mJan, 2, 15, 4, 5, zone = utc())
    check mygoI18n.format(mygoI18n.parseMessage("{d, date}"), "en",
      mygoI18n.formatArg("d", day)) == "Jan 2, 2026"
    check mygoI18n.format(mygoI18n.parseMessage("{d, date, short}"), "en",
      mygoI18n.formatArg("d", day)) == "1/2/26"
    check mygoI18n.format(mygoI18n.parseMessage("{d, date, full}"), "en",
      mygoI18n.formatArg("d", day)) == "Friday, January 2, 2026"
    check mygoI18n.format(mygoI18n.parseMessage("{d, time, short}"), "en",
      mygoI18n.formatArg("d", day)) == "3:04 PM"
    check mygoI18n.format(mygoI18n.parseMessage("{d, time}"), "en",
      mygoI18n.formatArg("d", day)) == "3:04:05 PM"
    check mygoI18n.format(mygoI18n.parseMessage("{d}"), "en",
      mygoI18n.formatArg("d", day)) == "1/2/26, 3:04 PM"
    check mygoI18n.format(mygoI18n.parseMessage("{d, date, ::yMMMM}"), "en",
      mygoI18n.formatArg("d", day)) == "January 2026"
