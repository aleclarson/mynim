## Parses ICU MessageFormat messages and exposes their argument structure.

import std/[strutils, unicode, times, math]

type
  MessageNodeKind* = enum
    messageText
    messageArgument
    messagePound
    messageNumber
    messageDate
    messageTime
    messagePlural
    messageSelectOrdinal
    messageSelect

  MessageNode* = object
    kind*: MessageNodeKind
    text*: string
    style*: string
    offset*: int64
    cases*: seq[MessageCase]

  MessageCase* = object
    key*: string
    exact*: string
    nodes*: seq[MessageNode]

  MessageArg* = object
    name*: string
    kind*: string

  Message* = ref object
    source*: string
    nodes*: seq[MessageNode]

  FormatArgKind* = enum
    formatStringArg
    formatNumberArg
    formatBooleanArg
    formatDateTimeArg
    formatNullArg

  FormatArg* = object
    ## A named value supplied to `i18n.format`.
    name*: string
    kind*: FormatArgKind
    text*: string
    exact*: bool
    boolean*: bool
    dateTime*: DateTime

  MessageSyntaxError* = object of ValueError
    offset*: int

  MessageParser = object
    source: string
    position: int

proc syntaxError(parser: MessageParser; detail: string): ref MessageSyntaxError =
  result = newException(MessageSyntaxError,
    "i18n: " & detail & " at offset " & $parser.position &
    " of " & parser.source.escape())
  result.offset = parser.position

proc expandFloatExponent(value: string): string =
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

proc formatArg*(name, value: string): FormatArg =
  FormatArg(name: name, kind: formatStringArg, text: value)

proc formatArg*[T: SomeInteger](name: string; value: T): FormatArg =
  FormatArg(name: name, kind: formatNumberArg, text: $value)

proc formatArg*[T: SomeFloat](name: string; value: T): FormatArg =
  if classify(value) in {fcNan, fcInf, fcNegInf}:
    return FormatArg(name: name, kind: formatStringArg, text: $value)
  FormatArg(name: name, kind: formatNumberArg,
    text: expandFloatExponent(formatFloat(value, ffDefault, -1)))

proc formatArg*(name: string; value: bool): FormatArg =
  FormatArg(name: name, kind: formatBooleanArg, boolean: value)

proc formatArg*(name: string; value: DateTime): FormatArg =
  FormatArg(name: name, kind: formatDateTimeArg, dateTime: value)

proc nullFormatArg*(name: string): FormatArg =
  FormatArg(name: name, kind: formatNullArg)

proc patternSpace(rune: Rune): bool =
  int(rune) in [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x200E,
    0x200F, 0x2028, 0x2029]

proc patternSyntax(rune: Rune): bool =
  let c = int(rune)
  if c < 0x80:
    return c in 0x21..0x2F or c in 0x3A..0x40 or c in 0x5B..0x5E or
      c == 0x60 or c in 0x7B..0x7E
  c in 0x00A1..0x00A7 or c in [0x00A9, 0x00AB, 0x00AC, 0x00AE,
    0x00B0, 0x00B1, 0x00B6, 0x00BB, 0x00BF, 0x00D7, 0x00F7] or
    c in 0x2010..0x2027 or c in 0x2030..0x203E or
    c in 0x2041..0x2053 or c in 0x2055..0x205E or
    c in 0x2190..0x245F or c in 0x2500..0x2775 or
    c in 0x2794..0x2BFF or c in 0x2E00..0x2E7F or
    c in 0x3001..0x3003 or c in 0x3008..0x3020 or c == 0x3030 or
    c in [0xFD3E, 0xFD3F, 0xFE45, 0xFE46]

proc skipSpace(parser: var MessageParser) =
  while parser.position < parser.source.len:
    let rune = parser.source.runeAt(parser.position)
    if not patternSpace(rune):
      break
    parser.position += parser.source.runeLenAt(parser.position)

proc readWord(parser: var MessageParser): string =
  let start = parser.position
  while parser.position < parser.source.len:
    let rune = parser.source.runeAt(parser.position)
    if patternSpace(rune) or patternSyntax(rune):
      break
    parser.position += parser.source.runeLenAt(parser.position)
  parser.source[start ..< parser.position]

proc validArgumentName(name: string): bool =
  if name.len == 0:
    return false
  let first = name.runeAt(0)
  if int(first) in ord('0')..ord('9'):
    if name.len > 1 and name[0] == '0':
      return false
    for ch in name:
      if ch notin {'0'..'9'}:
        return false
    return true
  first == Rune(ord('_')) or first.isAlpha()

proc validExactNumber(value: string): bool =
  if value.len == 0 or value[0] == '.' or value[^1] == '.':
    return false
  var digits = 0
  var hasPoint = false
  for ch in value:
    if ch in {'0'..'9'}:
      inc digits
    elif ch == '.' and not hasPoint:
      hasPoint = true
    else:
      return false
  digits > 0

proc parseMessageBody(parser: var MessageParser; depth: int;
    inPlural: bool): seq[MessageNode]

proc parseStyle(parser: var MessageParser): string =
  let start = parser.position
  var nested = 0
  while parser.position < parser.source.len:
    case parser.source[parser.position]
    of '\'':
      inc parser.position
      var closed = false
      while parser.position < parser.source.len:
        if parser.source[parser.position] == '\'':
          if parser.position + 1 < parser.source.len and
              parser.source[parser.position + 1] == '\'':
            parser.position += 2
          else:
            inc parser.position
            closed = true
            break
        else:
          inc parser.position
      if not closed:
        raise parser.syntaxError("unclosed quote in a style")
    of '{':
      inc nested
      inc parser.position
    of '}':
      if nested == 0:
        return parser.source[start ..< parser.position].strip()
      dec nested
      inc parser.position
    else:
      inc parser.position
  raise parser.syntaxError("unclosed style")

proc parseArgument(parser: var MessageParser; depth: int;
    inPlural: bool): MessageNode =
  inc parser.position # {
  parser.skipSpace()
  let name = parser.readWord()
  if name.len == 0:
    raise parser.syntaxError("an argument has no name")
  if not validArgumentName(name):
    raise parser.syntaxError("\"" & name & "\" is not an argument name")
  parser.skipSpace()
  if parser.position >= parser.source.len:
    raise parser.syntaxError("unclosed argument {" & name)
  if parser.source[parser.position] == '}':
    inc parser.position
    return MessageNode(kind: messageArgument, text: name)
  if parser.source[parser.position] != ',':
    raise parser.syntaxError("expected , or } after the argument name \"" &
      name & "\"")
  inc parser.position
  parser.skipSpace()
  let argumentType = parser.readWord()
  parser.skipSpace()

  case argumentType
  of "number", "date", "time":
    result.text = name
    result.kind = case argumentType
      of "number": messageNumber
      of "date": messageDate
      else: messageTime
    if parser.position < parser.source.len and
        parser.source[parser.position] == ',':
      inc parser.position
      result.style = parser.parseStyle()
      if result.style.len == 0:
        raise parser.syntaxError("the " & argumentType & " argument \"" &
          name & "\" has an empty style")
    if parser.position >= parser.source.len or
        parser.source[parser.position] != '}':
      raise parser.syntaxError("unclosed argument {" & name & ", " &
        argumentType)
    inc parser.position
    return
  of "plural", "selectordinal", "select":
    discard
  of "":
    raise parser.syntaxError("the argument \"" & name & "\" has no type")
  else:
    raise parser.syntaxError("unknown argument type \"" & argumentType &
      "\" (want number, date, time, plural, selectordinal or select)")

  if parser.position >= parser.source.len or
      parser.source[parser.position] != ',':
    raise parser.syntaxError("expected , after " & argumentType)
  inc parser.position
  result.text = name
  result.kind = case argumentType
    of "plural": messagePlural
    of "selectordinal": messageSelectOrdinal
    else: messageSelect
  let plural = result.kind != messageSelect
  parser.skipSpace()
  if plural and parser.position + "offset:".len <= parser.source.len and
      parser.source[parser.position ..< parser.position + "offset:".len] ==
        "offset:":
    parser.position += "offset:".len
    parser.skipSpace()
    let start = parser.position
    while parser.position < parser.source.len and
        parser.source[parser.position] in {'0'..'9'}:
      inc parser.position
    if start == parser.position or parser.position - start > 15:
      raise parser.syntaxError("offset: needs a number")
    for digit in parser.source[start ..< parser.position]:
      result.offset = result.offset * 10 + int64(ord(digit) - ord('0'))

  while true:
    parser.skipSpace()
    if parser.position >= parser.source.len:
      raise parser.syntaxError("unclosed " & argumentType & " argument \"" &
        name & "\"")
    if parser.source[parser.position] == '}':
      inc parser.position
      break

    var messageCase: MessageCase
    if plural and parser.source[parser.position] == '=':
      inc parser.position
      let start = parser.position
      while parser.position < parser.source.len and
          parser.source[parser.position] in {'0'..'9', '.'}:
        inc parser.position
      messageCase.exact = parser.source[start ..< parser.position]
      if not validExactNumber(messageCase.exact):
        raise parser.syntaxError("=" & messageCase.exact & " is not a number")
      messageCase.key = "=" & messageCase.exact
    else:
      messageCase.key = parser.readWord()
      if messageCase.key.len == 0:
        raise parser.syntaxError("expected a case of the " & argumentType &
          " argument \"" & name & "\"")
      if plural and messageCase.key notin ["zero", "one", "two", "few",
          "many", "other"]:
        raise parser.syntaxError("\"" & messageCase.key &
          "\" is not a plural category (zero, one, two, few, many, other)")

    for previous in result.cases:
      if previous.key == messageCase.key:
        raise parser.syntaxError("the " & argumentType & " argument \"" &
          name & "\" has the case " & messageCase.key & " twice")
    parser.skipSpace()
    if parser.position >= parser.source.len or
        parser.source[parser.position] != '{':
      raise parser.syntaxError("expected { after the case " & messageCase.key)
    inc parser.position
    messageCase.nodes = parser.parseMessageBody(depth + 1, plural)
    if parser.position >= parser.source.len:
      raise parser.syntaxError("unclosed case " & messageCase.key)
    inc parser.position # }
    result.cases.add messageCase

  var hasOther = false
  for messageCase in result.cases:
    hasOther = hasOther or messageCase.key == "other"
  if not hasOther:
    raise parser.syntaxError("the " & argumentType & " argument \"" & name &
      "\" has no other case")

proc appendText(nodes: var seq[MessageNode]; text: var string) =
  if text.len > 0:
    nodes.add MessageNode(kind: messageText, text: text)
    text.setLen(0)

proc parseQuoted(parser: var MessageParser; text: var string;
    inPlural: bool) =
  inc parser.position
  if parser.position < parser.source.len and
      parser.source[parser.position] == '\'':
    text.add '\''
    inc parser.position
    return
  if parser.position >= parser.source.len or
      not (parser.source[parser.position] in ['{', '}'] or
        (inPlural and parser.source[parser.position] == '#')):
    text.add '\''
    return
  while parser.position < parser.source.len:
    if parser.source[parser.position] == '\'':
      if parser.position + 1 < parser.source.len and
          parser.source[parser.position + 1] == '\'':
        text.add '\''
        parser.position += 2
      else:
        inc parser.position
        return
    else:
      text.add parser.source[parser.position]
      inc parser.position

proc parseMessageBody(parser: var MessageParser; depth: int;
    inPlural: bool): seq[MessageNode] =
  if depth > 32:
    raise parser.syntaxError("arguments nest too deep")
  var text = ""
  while parser.position < parser.source.len:
    case parser.source[parser.position]
    of '\'':
      parser.parseQuoted(text, inPlural)
    of '{':
      result.appendText(text)
      result.add parser.parseArgument(depth, inPlural)
    of '}':
      result.appendText(text)
      return
    of '#':
      if inPlural:
        result.appendText(text)
        result.add MessageNode(kind: messagePound)
      else:
        text.add '#'
      inc parser.position
    else:
      text.add parser.source[parser.position]
      inc parser.position
  result.appendText(text)

proc parseMessage*(source: string): Message =
  ## Parses one ICU MessageFormat message or raises MessageSyntaxError.
  var parser = MessageParser(source: source)
  let nodes = parser.parseMessageBody(0, false)
  if parser.position < source.len:
    raise parser.syntaxError("unmatched }")
  Message(source: source, nodes: nodes)

proc mustParseMessage*(source: string): Message =
  ## Parses a message, raising MessageSyntaxError when it is malformed.
  parseMessage(source)

proc argumentKind(kind: MessageNodeKind): string =
  case kind
  of messageArgument, messageText, messagePound: ""
  of messageNumber: "number"
  of messageDate: "date"
  of messageTime: "time"
  of messagePlural: "plural"
  of messageSelectOrdinal: "selectordinal"
  of messageSelect: "select"

proc args*(message: Message): seq[MessageArg] =
  ## Returns distinct arguments, including nested ones, in first-use order.
  var foundArgs: seq[MessageArg]
  proc visit(nodes: seq[MessageNode]) =
    for node in nodes:
      if node.kind notin {messageText, messagePound}:
        let kind = argumentKind(node.kind)
        var found = -1
        for i, arg in foundArgs:
          if arg.name == node.text:
            found = i
            break
        if found < 0:
          foundArgs.add MessageArg(name: node.text, kind: kind)
        elif foundArgs[found].kind.len == 0 and kind.len > 0:
          foundArgs[found].kind = kind
      for messageCase in node.cases:
        visit(messageCase.nodes)
  visit(message.nodes)
  result = foundArgs

proc cases*(message: Message; name: string): seq[string] =
  ## Returns distinct case labels for the named choice argument.
  var foundCases: seq[string]
  proc visit(nodes: seq[MessageNode]) =
    for node in nodes:
      for messageCase in node.cases:
        if node.text == name and messageCase.key notin foundCases:
          foundCases.add messageCase.key
        visit(messageCase.nodes)
  visit(message.nodes)
  result = foundCases
