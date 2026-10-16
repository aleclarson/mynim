## Specialized lexers matching Mygo's language-specific syntax roles.

proc relabelTokens(input: seq[Token]; start, finish: int;
                   kind: TokenKind): seq[Token] =
  var startAtToken = 0
  for token in input:
    let past = token.pastLast
    if past <= start or startAtToken >= finish:
      result.addToken(past, token.kind)
    else:
      if startAtToken < start:
        result.addToken(start, token.kind)
      result.addToken(min(past, finish), kind)
      if past > finish:
        result.addToken(past, token.kind)
    startAtToken = past

proc jsonTokenizer(): Tokenizer =
  let config = lexConfig("JSON")
  result = proc(line: string; state: uint64;
                tokens: var seq[Token]): uint64 =
    let base = tokens.len
    result = lexLine(config, line, state, tokens)
    if tokens.len == base:
      return
    var lineTokens: seq[Token]
    for i in base ..< tokens.len:
      lineTokens.add(tokens[i])
    var properties: seq[tuple[start, finish: int]]
    var i = 0
    while i < lineTokens.len:
      if lineTokens[i].kind != tokenString:
        inc i
        continue
      let first = i
      var last = i
      while last + 1 < lineTokens.len and
          lineTokens[last + 1].kind in {tokenString, tokenEscape}:
        inc last
      let start = if first == 0: 0 else: lineTokens[first - 1].pastLast
      let finish = lineTokens[last].pastLast
      var look = finish
      while look < line.len and line[look] in {' ', '\t'}:
        inc look
      if look < line.len and line[look] == ':':
        properties.add((start, finish))
      i = last + 1
    for property in properties:
      lineTokens = relabelTokens(lineTokens, property.start, property.finish,
        tokenProperty)
    tokens.setLen(base)
    for token in lineTokens:
      tokens.addToken(token.pastLast, token.kind)

proc tomlTokenizer(): Tokenizer =
  let config = lexConfig("TOML")
  result = proc(line: string; state: uint64;
                tokens: var seq[Token]): uint64 =
    let base = tokens.len
    result = lexLine(config, line, state, tokens)
    if state != 0 or tokens.len == base:
      return
    var lineTokens: seq[Token]
    for i in base ..< tokens.len:
      lineTokens.add(tokens[i])
    var start = 0
    while start < line.len and line[start] in {' ', '\t'}:
      inc start
    if start < line.len and line[start] == '[':
      let ending = line.rfind(']')
      if ending > start:
        lineTokens = relabelTokens(lineTokens, start, ending + 1, tokenType)
    else:
      let eq = line.find('=')
      var cleanKey = true
      if eq > start:
        for c in line[start ..< eq]:
          if c in {'\"', '\'', '#'}:
            cleanKey = false
            break
      if eq > start and cleanKey:
        var keyEnd = eq
        while keyEnd > start and line[keyEnd - 1] in {' ', '\t'}:
          dec keyEnd
        if keyEnd > start:
          lineTokens = relabelTokens(lineTokens, start, keyEnd, tokenProperty)
    tokens.setLen(base)
    for token in lineTokens:
      tokens.addToken(token.pastLast, token.kind)

proc isIdentByte(c: char): bool {.inline.} =
  c == '_' or isAsciiLetter(c) or isDigit(c)

proc cssSelectorAhead(s: string): bool =
  let brace = s.find('{')
  let semi = s.find(';')
  brace >= 0 and (semi < 0 or brace < semi)

proc cssTokenizer(): Tokenizer =
  result = proc(line: string; state: uint64;
                tokens: var seq[Token]): uint64 =
    var mode = int(state and 0xf'u64)
    var depth = int((state shr 8) and 0xff'u64)
    var value = false
    var i = 0
    while i < line.len:
      let c = line[i]
      if mode == 1:
        let endAt = line.find("*/", i)
        if endAt < 0:
          tokens.addToken(line.len, tokenComment)
          i = line.len
        else:
          tokens.addToken(endAt + 2, tokenComment)
          i = endAt + 2
          mode = 0
        continue
      if c in {' ', '\t', '\r'}:
        tokens.addToken(i + 1, tokenText)
        inc i
      elif line.startsWithAt("/*", i):
        mode = 1
        tokens.addToken(i + 2, tokenComment)
        i += 2
      elif line.startsWithAt("//", i) and (i == 0 or line[i - 1] != ':'):
        tokens.addToken(line.len, tokenComment)
        i = line.len
      elif c == '"' or c == '\'':
        var j = i + 1
        while j < line.len and line[j] != c:
          if line[j] == '\\':
            inc j
          inc j
        let finish = min(line.len, j + 1)
        tokens.addToken(finish, tokenString)
        i = finish
      elif c == '{':
        depth = min(depth + 1, 255)
        value = false
        tokens.addToken(i + 1, tokenPunctuation)
        inc i
      elif c == '}':
        depth = max(depth - 1, 0)
        value = false
        tokens.addToken(i + 1, tokenPunctuation)
        inc i
      elif c == ';':
        value = false
        tokens.addToken(i + 1, tokenPunctuation)
        inc i
      elif c == '@':
        var j = i + 1
        while j < line.len and (isIdentByte(line[j]) or line[j] == '-'):
          inc j
        tokens.addToken(j, tokenKeyword)
        i = j
      elif c == '$' and i + 1 < line.len and
          (isIdentByte(line[i + 1]) or line[i + 1] == '-'):
        var j = i + 1
        while j < line.len and (isIdentByte(line[j]) or line[j] == '-'):
          inc j
        tokens.addToken(j, tokenVariable)
        i = j
      elif c == '#' and value:
        var j = i + 1
        while j < line.len and isIdentByte(line[j]):
          inc j
        tokens.addToken(j, tokenNumber)
        i = j
      elif (c >= '0' and c <= '9') or
          ((c == '.' or c == '-' or c == '+') and i + 1 < line.len and
            isDigit(line[i + 1]) and value):
        var j = i + 1
        while j < line.len and (isDigit(line[j]) or line[j] == '.'):
          inc j
        while j < line.len and
            ((line[j] >= 'a' and line[j] <= 'z') or line[j] == '%'):
          inc j
        tokens.addToken(j, tokenNumber)
        i = j
      elif isIdentByte(c) or c == '-' or ord(c) >= 0x80:
        var j = i
        while j < line.len and
            (isIdentByte(line[j]) or line[j] == '-' or ord(line[j]) >= 0x80):
          inc j
        var look = j
        while look < line.len and line[look] in {' ', '\t'}:
          inc look
        var kind = tokenTag
        if value and look < line.len and line[look] == '(':
          kind = tokenFunction
        elif value:
          kind = tokenConstant
          if line[i] == '-' and line.startsWithAt("--", i):
            kind = tokenVariable
        elif depth > 0 and look < line.len and line[look] == ':' and
            not cssSelectorAhead(line[look .. ^1]):
          kind = tokenProperty
        elif line.startsWithAt("--", i):
          kind = tokenVariable
        tokens.addToken(j, kind)
        i = j
      elif c == ':' and not value and depth > 0 and
          not cssSelectorAhead(line[i .. ^1]):
        value = true
        tokens.addToken(i + 1, tokenPunctuation)
        inc i
      elif c == ':':
        var j = i + 1
        while j < line.len and
            (line[j] == ':' or isIdentByte(line[j]) or line[j] == '-'):
          inc j
        tokens.addToken(j, tokenKeyword)
        i = j
      elif (c == '.' or c == '#') and not value and i + 1 < line.len and
          (isIdentByte(line[i + 1]) or line[i + 1] == '-'):
        var j = i + 1
        while j < line.len and (isIdentByte(line[j]) or line[j] == '-'):
          inc j
        tokens.addToken(j, tokenType)
        i = j
      elif c == '!' and line.startsWithAt("!important", i):
        tokens.addToken(i + 10, tokenKeyword)
        i += 10
      else:
        let kind = if c in {'(', ')', ',', '[', ']'}:
          tokenPunctuation
        else:
          tokenOperator
        tokens.addToken(i + 1, kind)
        inc i
    result = uint64(mode) or (uint64(depth) shl 8)

proc lowerAscii(c: char): char {.inline.} =
  if c >= 'A' and c <= 'Z': chr(ord(c) + 32) else: c

proc indexFold(s, sub: string): int =
  if sub.len == 0:
    return 0
  if sub.len > s.len:
    return -1
  for i in 0 .. s.len - sub.len:
    var matches = true
    for j in 0 ..< sub.len:
      if lowerAscii(s[i + j]) != sub[j]:
        matches = false
        break
    if matches:
      return i
  -1

const
  markupText = 0
  markupTag = 1
  markupComment = 2
  markupDouble = 3
  markupSingle = 4
  markupCData = 5
  markupScript = 6
  markupStyle = 7

proc markupTokenizer(html: bool): Tokenizer =
  let script = builtinTokenizer("JavaScript")
  let style = builtinTokenizer("CSS")
  result = proc(line: string; state: uint64;
                tokens: var seq[Token]): uint64 =
    var mode = int(state and 0xf'u64)
    var embed = int((state shr 4) and 3'u64)
    var inner = state shr 16
    let n = line.len
    var i = 0
    while i < n:
      case mode
      of markupScript, markupStyle:
        var tag = "</script"
        var tokenizer = script
        if mode == markupStyle:
          tag = "</style"
          tokenizer = style
        let endAt = indexFold(line[i .. ^1], tag)
        let stop = if endAt < 0: n else: i + endAt
        if tokenizer != nil and stop > i:
          var innerTokens: seq[Token]
          inner = tokenizer(line[i ..< stop], inner, innerTokens)
          for token in innerTokens:
            tokens.addToken(i + token.pastLast, token.kind)
        tokens.addToken(stop, tokenText)
        i = stop
        if endAt >= 0:
          mode = markupText
          inner = 0
      of markupComment:
        let endAt = line.find("-->", i)
        if endAt < 0:
          tokens.addToken(n, tokenComment)
          i = n
        else:
          tokens.addToken(endAt + 3, tokenComment)
          i = endAt + 3
          mode = markupText
      of markupCData:
        let endAt = line.find("]]>", i)
        if endAt < 0:
          tokens.addToken(n, tokenString)
          i = n
        else:
          tokens.addToken(endAt + 3, tokenString)
          i = endAt + 3
          mode = markupText
      of markupDouble, markupSingle:
        let quote = if mode == markupSingle: '\'' else: '"'
        let endAt = line.find(quote, i)
        if endAt < 0:
          tokens.addToken(n, tokenString)
          i = n
        else:
          tokens.addToken(endAt + 1, tokenString)
          i = endAt + 1
          mode = markupTag
      of markupTag:
        let c = line[i]
        if c == '>':
          tokens.addToken(i + 1, tokenPunctuation)
          inc i
          mode = markupText
          if embed == 1:
            mode = markupScript
          elif embed == 2:
            mode = markupStyle
          embed = 0
        elif c == '/' and i + 1 < n and line[i + 1] == '>':
          tokens.addToken(i + 2, tokenPunctuation)
          i += 2
          mode = markupText
          embed = 0
        elif c == '"':
          tokens.addToken(i + 1, tokenString)
          inc i
          mode = markupDouble
        elif c == '\'':
          tokens.addToken(i + 1, tokenString)
          inc i
          mode = markupSingle
        elif c == '=':
          tokens.addToken(i + 1, tokenOperator)
          inc i
        elif c in {' ', '\t', '\r'}:
          tokens.addToken(i + 1, tokenText)
          inc i
        else:
          var j = i
          while j < n and line[j] notin {' ', '\t', '\r', '=', '>', '/', '"', '\''}:
            inc j
          if j == i:
            inc j
          tokens.addToken(j, tokenAttribute)
          i = j
      else:
        let c = line[i]
        if line.startsWithAt("<!--", i):
          tokens.addToken(i + 4, tokenComment)
          i += 4
          mode = markupComment
        elif line.startsWithAt("<![CDATA[", i):
          tokens.addToken(i + 9, tokenString)
          i += 9
          mode = markupCData
        elif c == '<' and i + 1 < n and line[i + 1] in {'!', '?'}:
          var j = i + 2
          while j < n and line[j] != '>' and line[j] != ' ':
            inc j
          tokens.addToken(j, tokenMeta)
          i = j
          mode = markupTag
        elif c == '<' and i + 1 < n and
            (line[i + 1] == '/' or isIdentStart(line, i + 1, "")):
          tokens.addToken(i + 1, tokenPunctuation)
          var j = i + 1
          let closing = line[j] == '/'
          if closing:
            tokens.addToken(j + 1, tokenPunctuation)
            inc j
          let start = j
          while j < n and
              (isIdentByte(line[j]) or line[j] in {'-', ':', '.'}):
            inc j
          tokens.addToken(j, tokenTag)
          let name = line[start ..< j].toLowerAscii()
          embed = 0
          if html and not closing:
            if name == "script":
              embed = 1
            elif name == "style":
              embed = 2
          i = j
          mode = markupTag
        elif c == '&':
          var j = i + 1
          while j < n and j - i < 32 and
              (isIdentByte(line[j]) or line[j] == '#'):
            inc j
          if j < n and line[j] == ';':
            tokens.addToken(j + 1, tokenEscape)
            i = j + 1
          else:
            tokens.addToken(i + 1, tokenText)
            inc i
        else:
          var j = i + 1
          while j < n and line[j] != '<' and line[j] != '&':
            inc j
          tokens.addToken(j, tokenText)
          i = j
    result = uint64(mode) or (uint64(embed) shl 4) or (inner shl 16)
const
  mdFence = 1'u64 shl 40
  mdTilde = 1'u64 shl 41
  mdComment = 1'u64 shl 54
  mdInner = (1'u64 shl 40) - 1

proc markdownInline(line: string; start: int;
                    tokens: var seq[Token]): bool =
  var i = start
  let n = line.len
  while i < n:
    let c = line[i]
    if c == '\\' and i + 1 < n and
        line[i + 1] in {'\\', char(96), '*', '_', '{', '}', '[', ']', '(', ')',
          '#', '+', '-', '.', '!', '|', '<', '>', '~'}:
      tokens.addToken(i + 2, tokenEscape)
      i += 2
    elif c == char(96):
      var run = 1
      while i + run < n and line[i + run] == char(96):
        inc run
      let marker = repeat($char(96), run)
      let endAt = line.find(marker, i + run)
      if endAt < 0:
        tokens.addToken(i + run, tokenText)
        i += run
      else:
        tokens.addToken(endAt + run, tokenCode)
        i = endAt + run
    elif line.startsWithAt("<!--", i):
      let endAt = line.find("-->", i + 4)
      if endAt < 0:
        tokens.addToken(n, tokenComment)
        return true
      tokens.addToken(endAt + 3, tokenComment)
      i = endAt + 3
    elif c == '<' and i + 1 < n and
        (isIdentStart(line, i + 1, "") or line[i + 1] == '/'):
      let endAt = line.find('>', i)
      if endAt < 0:
        tokens.addToken(i + 1, tokenText)
        inc i
      else:
        let kind = if line[i ..< endAt].contains("://") or
            line[i ..< endAt].contains('@'): tokenLink else: tokenTag
        tokens.addToken(endAt + 1, kind)
        i = endAt + 1
    elif c == '[' or (c == '!' and i + 1 < n and line[i + 1] == '['):
      let startAt = i
      if c == '!':
        inc i
      let endAt = line.find(']', i)
      if endAt < 0:
        tokens.addToken(i + 1, tokenText)
        inc i
      else:
        tokens.addToken(startAt, tokenText)
        tokens.addToken(endAt + 1, tokenLink)
        i = endAt + 1
        if i < n and line[i] in {'(', '['}:
          let closing = if line[i] == '[': ']' else: ')'
          let destEnd = line.find(closing, i)
          if destEnd >= 0:
            tokens.addToken(destEnd + 1, tokenString)
            i = destEnd + 1
    elif c in {'*', '_', '~'}:
      var run = 1
      while i + run < n and line[i + run] == c:
        inc run
      if (c == '~' and run < 2) or i + run >= n or line[i + run] == ' ':
        tokens.addToken(i + run, tokenText)
        i += run
      elif c == '_' and i > 0 and isIdentByte(line[i - 1]):
        tokens.addToken(i + run, tokenText)
        i += run
      else:
        let marker = line[i ..< i + run]
        let endAt = line.find(marker, i + run)
        if endAt <= i + run or line[endAt - 1] == ' ':
          tokens.addToken(i + run, tokenText)
          i += run
        else:
          var kind = tokenEmphasis
          if c == '~':
            kind = tokenDeleted
          elif run >= 2:
            kind = tokenStrong
          tokens.addToken(endAt + run, kind)
          i = endAt + run
    elif line.startsWithAt("http://", i) or line.startsWithAt("https://", i):
      var j = i
      while j < n and line[j] notin {' ', ')', '>'}:
        inc j
      tokens.addToken(j, tokenLink)
      i = j
    elif c == '|':
      tokens.addToken(i + 1, tokenPunctuation)
      inc i
    else:
      var j = i + 1
      while j < n and line[j] notin {'\\', char(96), '<', '[', '!', '*', '_', '~', 'h', '|'}:
        inc j
      tokens.addToken(j, tokenText)
      i = j
  false

proc markdownTokenizer(): Tokenizer =
  result = proc(line: string; state: uint64;
                tokens: var seq[Token]): uint64 =
    let n = line.len
    var indent = 0
    while indent < n and line[indent] == ' ':
      inc indent
    let trimmed = if indent < n: line[indent .. ^1] else: ""
    if (state and mdComment) != 0:
      let endAt = line.find("-->")
      if endAt < 0:
        tokens.addToken(n, tokenComment)
        return state
      tokens.addToken(endAt + 3, tokenComment)
      let next = markdownInline(line, endAt + 3, tokens)
      result = state and (not mdComment)
      if next:
        result = result or mdComment
      return
    if (state and mdFence) != 0:
      let ch = if (state and mdTilde) != 0: '~' else: char(96)
      var run = 0
      while run < trimmed.len and trimmed[run] == ch:
        inc run
      let tail = if indent + run < n: line[indent + run .. ^1] else: ""
      if indent < 4 and run >= int((state shr 42) and 0xf'u64) and
          tail.strip().len == 0:
        tokens.addToken(n, tokenPunctuation)
        return 0
      let languageIndex = int((state shr 46) and 0xff'u64)
      let langs = languages()
      if languageIndex > 0 and languageIndex <= langs.len and
          langs[languageIndex - 1].tokenizer != nil:
        let inner = langs[languageIndex - 1].tokenizer(line, state and mdInner, tokens)
        let clipped = if inner > mdInner: 0'u64 else: inner
        tokens.addToken(n, tokenText)
        return (state and (not mdInner)) or clipped
      tokens.addToken(n, tokenCode)
      return state
    let tickFence = repeat($char(96), 3)
    if indent < 4 and trimmed.len >= 3 and
        (trimmed.startsWith(tickFence) or trimmed.startsWith("~~~")):
      let ch = trimmed[0]
      var run = 0
      while run < trimmed.len and trimmed[run] == ch:
        inc run
      let info = if run < trimmed.len: trimmed[run .. ^1].strip() else: ""
      if ch == char(96) and info.contains(char(96)):
        discard markdownInline(line, 0, tokens)
        return state
      tokens.addToken(indent + run, tokenPunctuation)
      tokens.addToken(n, tokenType)
      var next = mdFence or (uint64(min(run, 15)) shl 42)
      if ch == '~':
        next = next or mdTilde
      var name = info
      let nameEnd = name.find({' ', '\t', '{'})
      if nameEnd >= 0:
        name = name[0 ..< nameEnd]
      let language = languageNamed(name)
      if language != nil:
        let langs = languages()
        for index, candidate in langs:
          if candidate == language:
            next = next or (uint64(index + 1) shl 46)
      return next
    if indent < 4 and trimmed.startsWith("#"):
      var heading = 0
      while heading < trimmed.len and trimmed[heading] == '#':
        inc heading
      if heading <= 6 and
          (heading == trimmed.len or trimmed[heading] in {' ', '\t'}):
        tokens.addToken(n, tokenHeading)
        return state
    if indent < 4 and trimmed.len > 0 and
        (trimmed.strip(chars = {'='}).len == 0 or
         (trimmed.strip(chars = {'-', ' '}).len == 0 and
          trimmed.count('-') >= 2)):
      tokens.addToken(n, tokenHeading)
      return state
    if indent < 4 and trimmed.len >= 3 and
        (trimmed.strip(chars = {'*', ' '}).len == 0 or
         trimmed.strip(chars = {'_', ' '}).len == 0):
      tokens.addToken(n, tokenPunctuation)
      return state

    var i = indent
    tokens.addToken(i, tokenText)
    while i < n and line[i] == '>':
      tokens.addToken(i + 1, tokenPunctuation)
      inc i
      while i < n and line[i] == ' ':
        inc i
      tokens.addToken(i, tokenText)
    if i + 1 < n and line[i] in {'-', '*', '+'} and line[i + 1] == ' ':
      tokens.addToken(i + 1, tokenPunctuation)
      inc i
    else:
      var j = i
      while j < n and j - i < 9 and isDigit(line[j]):
        inc j
      if j > i and j + 1 < n and line[j] in {'.', ')'} and line[j + 1] == ' ':
        tokens.addToken(j + 1, tokenPunctuation)
        i = j + 1
    let rest = if i < n: line[i .. ^1] else: ""
    let trimmedRest = rest.strip(leading = true, trailing = false, chars = {' '})
    if trimmedRest.startsWith("[ ] ") or trimmedRest.startsWith("[x] ") or
        trimmedRest.startsWith("[X] "):
      let bracket = line.find('[', i)
      if bracket >= 0:
        tokens.addToken(bracket, tokenText)
        tokens.addToken(bracket + 3, tokenKeyword)
        i = bracket + 3
    if markdownInline(line, i, tokens):
      result = state or mdComment
    else:
      result = state

proc diffTokenizer(): Tokenizer =
  result = proc(line: string; state: uint64;
                tokens: var seq[Token]): uint64 =
    var kind = tokenText
    if line.startsWith("+++") or line.startsWith("---") or
        line.startsWith("diff ") or line.startsWith("index ") or
        line.startsWith("new file") or line.startsWith("deleted file") or
        line.startsWith("similarity") or line.startsWith("rename ") or
        line.startsWith("old mode") or line.startsWith("new mode"):
      kind = tokenMeta
    elif line.startsWith("@@"):
      let endAt = line.find("@@", 2)
      if endAt >= 0:
        tokens.addToken(endAt + 2, tokenKeyword)
        tokens.addToken(line.len, tokenFunction)
      else:
        tokens.addToken(line.len, tokenKeyword)
      return 0
    elif line.len > 0 and line[0] in {'+', '>'}:
      kind = tokenInserted
    elif line.len > 0 and line[0] in {'-', '<'}:
      kind = tokenDeleted
    elif line.len > 0 and line[0] == '\\':
      kind = tokenComment
    tokens.addToken(line.len, kind)
    0

proc specialTokenizer(name: string): Tokenizer =
  case name
  of "JSON": result = jsonTokenizer()
  of "TOML": result = tomlTokenizer()
  of "CSS": result = cssTokenizer()
  of "HTML": result = markupTokenizer(true)
  of "XML": result = markupTokenizer(false)
  of "Markdown": result = markdownTokenizer()
  of "Diff": result = diffTokenizer()
  else: discard
