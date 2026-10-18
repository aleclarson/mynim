## Finds URLs and opt-in file paths in a terminal row.

import std/unicode

type
  TerminalLink* = object
    target*: string
    isPath*: bool

func codepoint(runes: openArray[Rune]; index: int): uint32 {.inline.} =
  uint32(runes[index])

func startsAt(runes: openArray[Rune]; index: int; value: string): bool =
  if index < 0 or index + value.len > runes.len:
    return false
  for offset, character in value:
    if codepoint(runes, index + offset) != uint32(ord(character)):
      return false
  true

func linkEnd(runes: openArray[Rune]; start: int): int =
  result = start
  while result < runes.len:
    let value = codepoint(runes, result)
    if value <= 0x20'u32 or value == 0x7f'u32 or
        value in [uint32(ord('"')), uint32(ord('\'')), uint32(ord('<')),
          uint32(ord('>')), uint32(ord('`'))]:
      break
    inc result

func runeText(runes: openArray[Rune]; first, pastLast: int): string =
  for index in first ..< pastLast:
    result.add(toUTF8(runes[index]))

func trimmedUrlEnd(runes: openArray[Rune]; first, pastLast: int): int =
  result = pastLast
  while result > first:
    let last = codepoint(runes, result - 1)
    if last in [uint32(ord('.')), uint32(ord(',')), uint32(ord(';')),
        uint32(ord(':')), uint32(ord('!')), uint32(ord('?'))]:
      dec result
      continue
    var opening, closing: uint32
    case last
    of uint32(ord(')')):
      opening = uint32(ord('('))
      closing = last
    of uint32(ord(']')):
      opening = uint32(ord('['))
      closing = last
    of uint32(ord('}')):
      opening = uint32(ord('{'))
      closing = last
    else:
      return
    var opens, closes = 0
    for index in first ..< result:
      let value = codepoint(runes, index)
      if value == opening: inc opens
      if value == closing: inc closes
    if closes > opens:
      dec result
    else:
      return

func columnContains(columns: openArray[int]; first, pastLast, column: int):
    bool =
  first >= 0 and first < pastLast and pastLast <= columns.len and
    columns[first] <= column and column <= columns[pastLast - 1]

proc urlAt(runes: openArray[Rune]; columns: openArray[int]; column: int):
    string =
  const schemes = ["https://", "http://", "ftp://", "file://", "mailto:"]
  for index in 0 ..< runes.len:
    var scheme: string
    for candidate in schemes:
      if startsAt(runes, index, candidate):
        scheme = candidate
        break
    if scheme.len == 0:
      continue
    let pastLast = linkEnd(runes, index + scheme.len)
    if pastLast == index + scheme.len:
      continue
    let trimmedEnd = trimmedUrlEnd(runes, index, pastLast)
    if columnContains(columns, index, trimmedEnd, column):
      return runeText(runes, index, trimmedEnd)

func pathDelimiter(value: uint32): bool {.inline.} =
  value <= 0x20'u32 or value == 0x7f'u32 or
    value in [uint32(ord('"')), uint32(ord('\'')), uint32(ord('<')),
      uint32(ord('>')), uint32(ord('`'))]

func pathWord(value: uint32): bool {.inline.} =
  value in uint32(ord('a')) .. uint32(ord('z')) or
    value in uint32(ord('A')) .. uint32(ord('Z')) or
    value in uint32(ord('0')) .. uint32(ord('9')) or
    value in [uint32(ord('_')), uint32(ord('.')), uint32(ord('@')),
      uint32(ord('+')), uint32(ord('-'))]

func fileStart(value: uint32): bool {.inline.} =
  value in uint32(ord('a')) .. uint32(ord('z')) or
    value in uint32(ord('A')) .. uint32(ord('Z')) or
    value in uint32(ord('0')) .. uint32(ord('9')) or
    value in [uint32(ord('_')), uint32(ord('@')), uint32(ord('+')),
      uint32(ord('-'))]

func wordChar(value: uint32): bool {.inline.} =
  value in uint32(ord('a')) .. uint32(ord('z')) or
    value in uint32(ord('A')) .. uint32(ord('Z')) or
    value in uint32(ord('0')) .. uint32(ord('9')) or
    value == uint32(ord('_'))

func parseLineSuffix(runes: openArray[Rune]; index, limit: int): int =
  ## Returns index unchanged unless a complete :line[:column] suffix follows.
  result = index
  if index >= limit or codepoint(runes, index) != uint32(ord(':')):
    return
  var cursor = index + 1
  let lineStart = cursor
  while cursor < limit and codepoint(runes, cursor) in
      uint32(ord('0')) .. uint32(ord('9')):
    inc cursor
  if cursor == lineStart:
    return
  if cursor < limit and codepoint(runes, cursor) == uint32(ord(':')):
    let columnStart = cursor + 1
    cursor = columnStart
    while cursor < limit and codepoint(runes, cursor) in
        uint32(ord('0')) .. uint32(ord('9')):
      inc cursor
    if cursor == columnStart:
      return
  return cursor

func rootedPrefix(runes: openArray[Rune]; index: int): int =
  if startsAt(runes, index, "../"):
    return 3
  if startsAt(runes, index, "~/") or startsAt(runes, index, "./") or
      startsAt(runes, index, "/"):
    return if codepoint(runes, index) == uint32(ord('/')): 1 else: 2

func rootedPathEnd(runes: openArray[Rune]; first, limit: int): int =
  let prefix = rootedPrefix(runes, first)
  if prefix == 0:
    return first
  var cursor = first + prefix
  let bodyStart = cursor
  while cursor < limit and not pathDelimiter(codepoint(runes, cursor)) and
      codepoint(runes, cursor) != uint32(ord(':')):
    inc cursor
  if cursor == bodyStart:
    return first
  let lineEnd = parseLineSuffix(runes, cursor, limit)
  if lineEnd > cursor: cursor = lineEnd
  cursor

func relativePathEnd(runes: openArray[Rune]; first, limit: int): int =
  var cursor = first
  var components = 0
  while cursor < limit:
    let componentStart = cursor
    while cursor < limit and pathWord(codepoint(runes, cursor)):
      inc cursor
    if cursor == componentStart:
      return first
    inc components
    if cursor >= limit or codepoint(runes, cursor) != uint32(ord('/')):
      break
    inc cursor
    if cursor >= limit or pathDelimiter(codepoint(runes, cursor)):
      break
  if components < 2:
    return first
  var pastLast = cursor
  if pastLast < limit and codepoint(runes, pastLast) == uint32(ord(':')):
    let lineEnd = parseLineSuffix(runes, pastLast, limit)
    if lineEnd > pastLast:
      pastLast = lineEnd
    else:
      return first
  return pastLast

func fileLineEnd(runes: openArray[Rune]; first, limit: int): int =
  if first >= limit or not fileStart(codepoint(runes, first)):
    return first
  var cursor = first + 1
  while cursor < limit and pathWord(codepoint(runes, cursor)):
    inc cursor
  if cursor >= limit or codepoint(runes, cursor) != uint32(ord(':')):
    return first
  var extensionStart = -1
  for index in first ..< cursor:
    if codepoint(runes, index) == uint32(ord('.')):
      extensionStart = index
  if extensionStart < 0 or extensionStart == cursor - 1:
    return first
  for index in extensionStart + 1 ..< cursor:
    if not wordChar(codepoint(runes, index)):
      return first
  parseLineSuffix(runes, cursor, limit)

proc pathAt(runes: openArray[Rune]; columns: openArray[int]; column: int):
    string =
  for index in 0 ..< runes.len:
    var pastLast = rootedPathEnd(runes, index, runes.len)
    if pastLast == index:
      pastLast = relativePathEnd(runes, index, runes.len)
    if pastLast == index:
      pastLast = fileLineEnd(runes, index, runes.len)
    if pastLast > index and
        columnContains(columns, index, pastLast, column):
      return runeText(runes, index, pastLast)

proc linkAt*(text: string; columns: openArray[int]; column: int;
             includePaths: bool): TerminalLink =
  ## Finds the URI or configured file path under a terminal cell.
  let runes = text.toRunes()
  result.target = urlAt(runes, columns, column)
  if result.target.len > 0:
    return
  if includePaths:
    result.target = pathAt(runes, columns, column)
    result.isPath = result.target.len > 0

func safeTerminalUrl*(url: string): bool =
  ## Allows the URL schemes MyGo recognizes while rejecting unsafe bytes.
  var colon = -1
  for index, character in url:
    let value = ord(character)
    if value < 0x20 or value == 0x7f or character == '\\':
      return false
    if character == ':' and colon < 0:
      colon = index
  if colon <= 0:
    return false
  url[0 ..< colon] in ["http", "https", "ftp", "file", "mailto"]
