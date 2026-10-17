## Parses release notes for the native updater window. It recognizes the
## Markdown commonly used in changelogs while keeping raw HTML as text and
## allowing links only to HTTP, HTTPS, or mailto URLs.

import std/[strutils, unicode]

type
  BlockKind* = enum ## A block of release notes.
    Paragraph, Heading, List, Quote, Code, Rule

  Block* = object
    ## Content parsed for one block.
    kind*: BlockKind ## Paragraph, heading, list, quote, fenced code, or rule.
    level*: int ## Heading level from 1 through 6.
    inlines*: seq[Inline] ## Paragraph or heading content.
    text*: string ## Fenced code content.
    ordered*: bool ## Whether a list is ordered.
    items*: seq[seq[Block]] ## List item blocks.
    blocks*: seq[Block] ## Quoted blocks.

  InlineKind* = enum ## An inline run in a paragraph or heading.
    Text, CodeSpan, Emphasis, Strong, Link

  Inline* = object
    ## Text or the children of an inline formatting run.
    kind*: InlineKind ## Plain text, code, emphasis, strong, or link.
    text*: string ## Text content of Text or CodeSpan.
    children*: seq[Inline] ## Content of emphasis, strong, or link.
    url*: string ## Target of a safe link.

proc safeUrl*(url: string): bool =
  ## Reports whether a release note link may open in the system browser.
  let normalized = url.toLowerAscii()
  normalized.startsWith("https://") or normalized.startsWith("http://") or
    normalized.startsWith("mailto:")

proc run(s: string; c: char): int =
  while result < s.len and s[result] == c:
    inc result

proc startsAt(s, prefix: string; i: int): bool =
  i >= 0 and i + prefix.len <= s.len and
    s[i ..< i + prefix.len] == prefix

proc suffix(s: string; first: int): string =
  if first < s.len:
    result = s[first .. ^1]

proc isPunct(c: char): bool =
  c in {'!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-',
        '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^',
        '_', '`', '{', '|', '}', '~'}

proc isWord(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9'} or c >= '\x80'

proc closing(s, delimiter: string): int =
  result = -1
  var i = 1
  while i + delimiter.len <= s.len:
    case s[i]
    of '`':
      let n = run(s[i .. ^1], '`')
      let finish = s.find(s[i ..< i + n], i + n)
      if finish >= 0:
        i = finish + n - 1
    of '\\':
      inc i
    else:
      if s.startsAt(delimiter, i) and s[i - 1] != ' ' and s[i - 1] != '\n':
        if delimiter.len == 1 and i + 1 < s.len and s[i + 1] == delimiter[0]:
          inc i
          inc i
          continue
        if delimiter[0] == '_' and i + delimiter.len < s.len and
            s[i + delimiter.len].isWord:
          inc i
          continue
        return i
    inc i

proc parseLink(s: string): tuple[text, href: string, length: int, ok: bool] =
  var depth = 0
  var endAt = -1
  var i = 0
  while i < s.len and endAt < 0:
    case s[i]
    of '\\':
      inc i
    of '[':
      inc depth
    of ']':
      dec depth
      if depth == 0:
        endAt = i
    else:
      discard
    inc i
  if endAt < 0 or endAt + 1 >= s.len or s[endAt + 1] != '(':
    return
  let closeAt = s.find(')', endAt + 2)
  if closeAt < 0:
    return
  var destination = s[endAt + 2 ..< closeAt].strip()
  let title = destination.find({' ', '\n'})
  if title >= 0:
    destination.setLen(title)
  if destination.startsWith('<'):
    if destination.len > 1:
      destination = destination[1 .. ^1]
    else:
      destination.setLen(0)
  if destination.endsWith('>'):
    destination.setLen(destination.len - 1)
  (s[1 ..< endAt], destination, closeAt + 1, true)

type InlineBuilder = object
  values: seq[Inline]

proc addText(builder: var InlineBuilder; value: string) =
  if builder.values.len > 0 and builder.values[^1].kind == Text:
    builder.values[^1].text.add(value)
  else:
    builder.values.add(Inline(kind: Text, text: value))

proc addLink(builder: var InlineBuilder; href: string;
             children: seq[Inline]) =
  if not href.safeUrl:
    for child in children:
      if child.kind == Text:
        builder.addText(child.text)
      else:
        builder.values.add(child)
    return
  builder.values.add(Inline(kind: Link, url: href, children: children))

proc parseInline(s: string): seq[Inline] =
  var builder: InlineBuilder
  var i = 0
  while i < s.len:
    let c = s[i]
    case c
    of '\\':
      if i + 1 < s.len and s[i + 1].isPunct:
        builder.addText(s[i + 1 .. i + 1])
        i += 2
        continue
    of '\n':
      builder.addText(" ")
      inc i
      continue
    of '`':
      let n = run(s[i .. ^1], '`')
      let delimiter = s[i ..< i + n]
      let finish = s.find(delimiter, i + n)
      if finish >= 0:
        let code = s[i + n ..< finish].replace('\n', ' ').strip()
        builder.values.add(Inline(kind: CodeSpan, text: code))
        i = finish + n
        continue
      builder.addText(delimiter)
      i += n
      continue
    of '[', '!':
      let isImage = c == '!' and s.startsAt("![", i)
      if c == '[' or isImage:
        let start = i + (if isImage: 1 else: 0)
        let parsed = parseLink(s[start .. ^1])
        if parsed.ok:
          let children = if isImage:
            @[Inline(kind: Text, text: parsed.text)]
          else:
            parseInline(parsed.text)
          builder.addLink(parsed.href, children)
          i = start + parsed.length
          continue
    of '<':
      let endAt = s.find('>', i + 1)
      if endAt > i + 1:
        let address = s[i + 1 ..< endAt]
        if address.find({' ', '<'}) < 0 and address.safeUrl:
          builder.addLink(address, @[Inline(kind: Text, text: address)])
          i = endAt + 1
          continue
    of '*', '_':
      let n = min(run(s[i .. ^1], c), 2)
      if c == '_' and i > 0 and s[i - 1].isWord:
        discard
      else:
        let delimiter = s[i ..< i + n]
        let restStart = i + n
        if restStart < s.len and s[restStart] notin {' ', '\n'}:
          let finish = closing(s[restStart .. ^1], delimiter)
          if finish > 0:
            let kind = if n == 2: Strong else: Emphasis
            builder.values.add(Inline(kind: kind,
              children: parseInline(s[restStart ..< restStart + finish])))
            i = restStart + finish + n
            continue
        builder.addText(delimiter)
        i += n
        continue
    of 'h':
      if (i == 0 or not s[i - 1].isWord) and
          (s.startsAt("https://", i) or s.startsAt("http://", i)):
        var endAt = i
        while endAt < s.len and s[endAt] > ' ' and s[endAt] != '<':
          inc endAt
        var address = s[i ..< endAt]
        while address.len > 0 and address[^1] in {
            '.', ',', ':', ';', '!', '?', '"', '\'', ')'}:
          address.setLen(address.len - 1)
        if address.count('(') > address.count(')') and endAt > i + address.len and
            s[i + address.len] == ')':
          address.add(')')
        builder.addLink(address, @[Inline(kind: Text, text: address)])
        i += address.len
        continue
    else:
      discard
    let size = max(s.runeLenAt(i), 1)
    builder.addText(s[i ..< min(i + size, s.len)])
    i += size
  builder.values

proc leadingSpaces(s: string): int =
  while result < s.len and s[result] == ' ':
    inc result

proc isRule(s: string): bool =
  if s.len < 3 or s[0] notin {'-', '*', '_'}:
    return false
  var count = 0
  for c in s:
    if c == s[0]:
      inc count
    elif c != ' ':
      return false
  count >= 3

proc heading(s: string): int =
  while result < s.len and result < 7 and s[result] == '#':
    inc result
  if result == 0 or result > 6 or
      (s.len > result and s[result] != ' '):
    return 0

proc isFence(s: string): bool =
  s.startsWith("```") or s.startsWith("~~~")

proc listMarker(s: string): tuple[indent: int, ordered, ok: bool] =
  let indent = leadingSpaces(s)
  let rest = s.suffix(indent)
  if rest.len >= 2 and rest[0] in {'-', '*', '+'} and rest[1] == ' ':
    return (indent, false, not isRule(rest.strip()))
  var digits = 0
  while digits < rest.len and digits < 9 and rest[digits] in {'0'..'9'}:
    inc digits
  if digits > 0 and rest.len > digits + 1 and
      rest[digits] in {'.', ')'} and rest[digits + 1] == ' ':
    return (indent, true, true)

proc markerWidth(s: string): int =
  result = leadingSpaces(s)
  while result < s.len and s[result] != ' ':
    inc result
  let markerEnd = result
  while result < s.len and s[result] == ' ' and result - markerEnd < 4:
    inc result

proc startsList(s: string): bool =
  let marker = listMarker(s)
  marker.ok and (not marker.ordered or s.strip().startsWith("1"))

proc isBlockStart(s: string): bool =
  let trimmed = s.strip()
  heading(trimmed) > 0 or isFence(trimmed) or isRule(trimmed) or
    trimmed.startsWith('>')

proc parseBlocks(lines: seq[string]): seq[Block]

proc parseList(lines: seq[string]; start: int): tuple[value: Block, next: int] =
  let first = listMarker(lines[start])
  result.value = Block(kind: List, ordered: first.ordered)
  result.next = start
  while result.next < lines.len:
    let marker = listMarker(lines[result.next])
    if not marker.ok or marker.indent != first.indent or
        marker.ordered != first.ordered:
      break
    let width = markerWidth(lines[result.next])
    var item = @[lines[result.next].suffix(width)]
    var blank = false
    inc result.next
    while result.next < lines.len:
      let line = lines[result.next]
      if line.strip().len == 0:
        blank = true
        item.add("")
        inc result.next
        continue
      let indent = leadingSpaces(line)
      let nested = listMarker(line).ok
      if indent >= width:
        item.add(line.suffix(width))
      elif indent > first.indent and nested:
        item.add(line.suffix(indent))
      elif not blank and not nested and not isBlockStart(line):
        item.add(line.strip())
      else:
        break
      blank = false
      inc result.next
    while item.len > 0 and item[^1].len == 0:
      item.setLen(item.len - 1)
    result.value.items.add(parseBlocks(item))

proc parseBlocks(lines: seq[string]): seq[Block] =
  var paragraph: seq[string]
  proc flush(blocks: var seq[Block]; paragraph: var seq[string]) =
    if paragraph.len > 0:
      blocks.add(Block(kind: Paragraph,
        inlines: parseInline(paragraph.join("\n"))))
      paragraph.setLen(0)

  var i = 0
  while i < lines.len:
    let line = lines[i]
    let trimmed = line.strip()
    if trimmed.len == 0:
      flush(result, paragraph)
      inc i
    elif isFence(trimmed):
      flush(result, paragraph)
      let fence = trimmed[0 .. 2]
      var code: seq[string]
      inc i
      while i < lines.len and not lines[i].strip().startsWith(fence):
        code.add(lines[i])
        inc i
      if i < lines.len:
        inc i
      result.add(Block(kind: Code, text: code.join("\n")))
    elif heading(trimmed) > 0:
      flush(result, paragraph)
      let level = heading(trimmed)
      var text = trimmed.suffix(level).strip()
      while text.len > 0 and text[^1] == '#':
        text.setLen(text.len - 1)
      result.add(Block(kind: Heading, level: level,
        inlines: parseInline(text.strip())))
      inc i
    elif isRule(trimmed):
      flush(result, paragraph)
      result.add(Block(kind: Rule))
      inc i
    elif trimmed.startsWith('>'):
      flush(result, paragraph)
      var quote: seq[string]
      while i < lines.len and lines[i].strip().startsWith('>'):
        let stripped = lines[i].strip()
        var line = if stripped.len > 1: stripped[1 .. ^1] else: ""
        if line.startsWith(' '):
          line = line[1 .. ^1]
        quote.add(line)
        inc i
      result.add(Block(kind: Quote, blocks: parseBlocks(quote)))
    else:
      let marker = listMarker(line)
      if marker.ok and (paragraph.len == 0 or startsList(line)):
        flush(result, paragraph)
        let parsed = parseList(lines, i)
        result.add(parsed.value)
        i = parsed.next
      else:
        paragraph.add(trimmed)
        inc i
  flush(result, paragraph)

proc parse*(source: string): seq[Block] =
  ## Parses changelog Markdown into native-view blocks.
  let normalized = source.replace("\r\n", "\n").replace("\t", "    ")
  parseBlocks(normalized.split('\n'))
