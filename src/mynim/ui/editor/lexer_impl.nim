## Generic line lexer shared by the built-in language descriptors.
## Included by syntax.nim so the tokenizer types and implementations stay in
## one public module without making language metadata depend on a second module.

type
  LexString = object
    open, close: string
    prefix: string
    escape: bool
    multiline: bool
    kind: TokenKind

  LexConfig = object
    lineComments: seq[string]
    blockOpen, blockClose: string
    nestComments: bool
    strings: seq[LexString]
    words: Table[string, TokenKind]
    foldCase: bool
    identChars: string
    capitalTypes, calls, keys, directives, regexps, variables: bool
    decorator: char
    operators: string

const
  lexModeComment = 1
  lexModeString = 32
  lexOperators = "+-*/%=&|^!<>~?:@#"

proc addToken(tokens: var seq[Token]; pastLast: int; kind: TokenKind) =
  if tokens.len > 0:
    let last = tokens.len - 1
    if tokens[last].pastLast >= pastLast:
      return
    if tokens[last].kind == kind:
      tokens[last].pastLast = pastLast
      return
  tokens.add(Token(pastLast: pastLast, kind: kind))

proc addWords(config: var LexConfig; kind: TokenKind; words: string) =
  for word in words.splitWhitespace():
    config.words[word] = kind

proc addString(config: var LexConfig; open, close: string;
               escape = false; multiline = false; kind = tokenString;
               prefix = "") =
  config.strings.add(LexString(open: open, close: close, prefix: prefix,
    escape: escape, multiline: multiline, kind: kind))

proc addQuotedStrings(config: var LexConfig; quotes = "\"'") =
  for quote in quotes:
    let value = $quote
    config.addString(value, value, escape = true)

proc lexConfig(name: string): LexConfig =
  result.words = initTable[string, TokenKind]()
  result.operators = lexOperators
  case name
  of "Go":
    result.lineComments = @["//"]
    result.blockOpen = "/*"
    result.blockClose = "*/"
    result.addQuotedStrings()
    result.addString("`", "`", multiline = true)
    result.addWords(tokenKeyword,
      "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var")
    result.addWords(tokenType,
      "any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr")
    result.addWords(tokenConstant, "true false nil iota")
    result.addWords(tokenFunction,
      "append cap clear close complex copy delete imag len make max min new panic print println real recover")
    result.calls = true
  of "JavaScript", "TypeScript":
    result.lineComments = @["//"]
    result.blockOpen = "/*"
    result.blockClose = "*/"
    result.addQuotedStrings()
    result.addString("`", "`", escape = true, multiline = true)
    result.identChars = "$"
    result.addWords(tokenKeyword,
      "abstract async await break case catch class const continue debugger default delete do else enum export extends finally for from function get if implements import in instanceof interface let new of package private protected public return set static super switch this throw try typeof var void while with yield as declare infer is keyof module namespace override readonly satisfies type")
    result.addWords(tokenConstant, "true false null undefined NaN Infinity")
    result.addWords(tokenType,
      "any Array BigInt Boolean Date Error Function JSON Map Math Never Number Object Promise Proxy Reflect RegExp Set String Symbol Unknown WeakMap WeakSet console window document globalThis")
    if name == "TypeScript":
      result.addWords(tokenType, "boolean bigint never number object string symbol unknown void")
    result.capitalTypes = true
    result.calls = true
    result.regexps = true
    result.decorator = '@'
  of "JSON":
    result.lineComments = @["//"]
    result.blockOpen = "/*"
    result.blockClose = "*/"
    result.addQuotedStrings()
    result.addWords(tokenConstant, "true false null")
    result.keys = true
    result.operators = ":"
  of "Python":
    result.lineComments = @["#"]
    for prefix in ["", "r", "R", "b", "B", "u", "U", "f", "F", "rb", "br", "Rb", "bR", "fr", "rf", "Fr", "rF"]:
      let raw = 'r' in prefix or 'R' in prefix
      for quote in ["\"\"\"", "'''", "\"", "'"]:
        result.addString(quote, quote, escape = not raw,
          multiline = quote.len == 3, prefix = prefix)
    result.addWords(tokenKeyword,
      "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case")
    result.addWords(tokenConstant,
      "True False None NotImplemented Ellipsis __name__ __file__")
    result.addWords(tokenType,
      "int float str bytes bool list dict set tuple object type complex frozenset bytearray range Exception")
    result.addWords(tokenFunction, "print len open isinstance super self cls")
    result.calls = true
    result.capitalTypes = true
    result.decorator = '@'
  of "Rust":
    result.lineComments = @["//"]
    result.blockOpen = "/*"
    result.blockClose = "*/"
    result.nestComments = true
    result.addString("\"", "\"", escape = true, multiline = true)
    result.addString("'", "'", escape = true)
    result.addWords(tokenKeyword,
      "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while yield")
    result.addWords(tokenType,
      "bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize String Vec Option Result Box")
    result.addWords(tokenConstant, "true false None Some Ok Err")
    result.calls = true
    result.capitalTypes = true
    result.decorator = '#'
  of "C", "C++", "Java", "Kotlin", "Swift", "C#", "Protobuf":
    result.lineComments = @["//"]
    result.blockOpen = "/*"
    result.blockClose = "*/"
    result.addQuotedStrings()
    result.calls = true
    result.capitalTypes = true
    result.addWords(tokenKeyword,
      "abstract as assert auto break case catch class const continue default do else enum extern final finally for foreach friend goto if implements import instanceof interface namespace native new operator package private protected public register return restrict static struct switch synchronized template this throw throws transient try typedef typename union using virtual volatile while")
    result.addWords(tokenType,
      "bool boolean byte char char8_t char16_t char32_t decimal double float int long object short signed size_t ssize_t string uint ulong ushort void wchar_t String Object Integer")
    result.addWords(tokenConstant, "true false null NULL nullptr nil")
    result.addWords(tokenKeyword,
      "alignas alignof and asm concept consteval constexpr constinit decltype delete dynamic_cast explicit export mutable noexcept not or override reinterpret_cast requires static_assert static_cast thread_local try_cast typeid xor async await var record sealed permits yield fun val when")
    if name == "C" or name == "C++":
      result.directives = true
    if name == "C++":
      result.addString("R\"(", ")\"", multiline = true)
      result.addWords(tokenType, "std vector map")
    if name == "Kotlin" or name == "Swift":
      result.nestComments = true
  of "Shell":
    result.lineComments = @["#"]
    result.addQuotedStrings("\"'`")
    result.identChars = "-"
    result.variables = true
    result.operators = "|&;<>=!*?"
    result.addWords(tokenKeyword,
      "if then else elif fi case esac for select while until do done in function time coproc return exit break continue local export declare readonly unset shift source alias eval exec set trap")
    result.addWords(tokenFunction,
      "echo printf cd pwd test read mkdir rm cp mv ls cat grep sed awk find xargs sudo chmod chown curl git go bun npm")
  of "YAML":
    result.lineComments = @["#"]
    result.addQuotedStrings()
    result.addWords(tokenConstant, "true false null yes no on off True False Null")
    result.keys = true
    result.identChars = "-./"
    result.operators = "|>-*&!?:"
  of "TOML":
    result.lineComments = @["#", ";"]
    result.addString("\"\"\"", "\"\"\"", escape = true, multiline = true)
    result.addString("'''", "'''", multiline = true)
    result.addQuotedStrings()
    result.addWords(tokenConstant, "true false")
    result.identChars = "-."
    result.operators = "="
  of "SQL":
    result.lineComments = @["--"]
    result.blockOpen = "/*"
    result.blockClose = "*/"
    result.foldCase = true
    result.addString("'", "'", multiline = true)
    result.addString("\"", "\"", kind = tokenVariable)
    result.addString("`", "`", kind = tokenVariable)
    result.addWords(tokenKeyword,
      "select from where and or not insert into values update set delete create table drop alter add column index view as on join left right inner outer full cross group by order having limit offset union all distinct case when then else end is null in exists between like primary key foreign references default unique check constraint begin commit rollback transaction if returning with recursive asc desc trigger function procedure replace temporary temp database schema grant revoke cascade conflict do nothing using natural explain analyze pragma vacuum")
    result.addWords(tokenType,
      "int integer bigint smallint tinyint real float double decimal numeric text varchar char boolean bool date time timestamp blob json jsonb uuid serial")
    result.addWords(tokenConstant, "true false null")
    result.calls = true
    result.operators = "+-*/%=<>!|"
  of "Ruby":
    result.lineComments = @["#"]
    result.addQuotedStrings()
    result.addWords(tokenKeyword,
      "alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield require require_relative attr_accessor attr_reader attr_writer private protected public")
    result.addWords(tokenConstant, "true false nil")
    result.identChars = "?!"
    result.calls = true
    result.capitalTypes = true
  of "Lua":
    result.lineComments = @["--"]
    result.blockOpen = "--[["
    result.blockClose = "]]"
    result.addString("[[", "]]", multiline = true)
    result.addQuotedStrings()
    result.addWords(tokenKeyword,
      "and break do else elseif end for function goto if in local not or repeat return then until while")
    result.addWords(tokenConstant, "true false nil")
    result.calls = true
    result.operators = "+-*/%^#=<>~.:"
  of "PHP":
    result.lineComments = @["//", "#"]
    result.blockOpen = "/*"
    result.blockClose = "*/"
    result.addQuotedStrings()
    result.variables = true
    result.calls = true
    result.capitalTypes = true
    result.addWords(tokenKeyword,
      "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield")
    result.addWords(tokenConstant, "true false null TRUE FALSE NULL")
  of "CSS":
    result.blockOpen = "/*"
    result.blockClose = "*/"
    result.addQuotedStrings()
    result.identChars = "-"
    result.keys = true
    result.operators = "#@!$%&*+-/:<>?=|~"
  of "Dockerfile", "Makefile":
    result.lineComments = @["#"]
    result.addQuotedStrings()
    result.operators = "|&;<>=!*?"
    result.addWords(tokenKeyword,
      "ADD ARG CMD COPY ENTRYPOINT ENV EXPOSE FROM HEALTHCHECK LABEL MAINTAINER ONBUILD RUN SHELL STOPSIGNAL USER VOLUME WORKDIR include define ifdef ifndef endif else export override")
  of "Zig":
    result.lineComments = @["//"]
    result.addQuotedStrings()
    result.addWords(tokenKeyword,
      "addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline noalias noinline nosuspend opaque or packed pub resume return linksection suspend switch test threadlocal try union unreachable usingnamespace var volatile while")
    result.addWords(tokenType,
      "bool c_int c_long c_uint f16 f32 f64 i8 i16 i32 i64 i128 isize noreturn u8 u16 u32 u64 u128 usize void")
    result.calls = true
  else:
    discard

proc isAsciiLetter(c: char): bool {.inline.} =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')

proc isDigit(c: char): bool {.inline.} = c >= '0' and c <= '9'

proc isIdentStart(s: string; at: int; extra: string): bool {.inline.} =
  let c = s[at]
  c == '_' or isAsciiLetter(c) or ord(c) >= 128 or
    (c != '-' and c != '.' and extra.len > 0 and c in extra)

proc isIdentPart(s: string; at: int; extra: string): bool {.inline.} =
  let c = s[at]
  c == '_' or isAsciiLetter(c) or isDigit(c) or ord(c) >= 128 or
    (extra.len > 0 and c in extra)

proc startsWithAt(s, prefix: string; at: int): bool {.inline.} =
  prefix.len > 0 and at + prefix.len <= s.len and
    s[at ..< at + prefix.len] == prefix

proc startsComment(config: LexConfig; line: string; at: int): bool =
  if config.blockOpen.len > 0 and line.startsWithAt(config.blockOpen, at):
    return true
  for marker in config.lineComments:
    if line.startsWithAt(marker, at):
      return true

proc startString(config: LexConfig; line: string; at: int;
                 prefix: string; mode: var int; tokens: var seq[Token]): int =
  for index, spec in config.strings:
    if spec.prefix == prefix and line.startsWithAt(spec.open, at):
      mode = lexModeString + index
      result = at + spec.open.len
      tokens.addToken(result, spec.kind)
      return
  result = at

proc lexLine(config: LexConfig; line: string; state: uint64;
             tokens: var seq[Token]): uint64 =
  var mode = int(state and 0xff'u64)
  var depth = int((state shr 8) and 0xff'u64)
  var previousDot = false
  var regexAllowed = true
  var i = 0
  while i < line.len:
    if mode >= lexModeString:
      let index = mode - lexModeString
      if index < 0 or index >= config.strings.len:
        mode = 0
        continue
      let spec = config.strings[index]
      var j = i
      var closed = false
      while j < line.len:
        if spec.escape and line[j] == '\\':
          tokens.addToken(j, spec.kind)
          let finish = min(line.len, j + 2)
          tokens.addToken(finish, tokenEscape)
          j = finish
        elif line.startsWithAt(spec.close, j):
          j += spec.close.len
          tokens.addToken(j, spec.kind)
          mode = 0
          regexAllowed = false
          closed = true
          break
        else:
          inc j
      if not closed:
        tokens.addToken(line.len, spec.kind)
        if not spec.multiline:
          mode = 0
      i = max(i + 1, j)
      continue

    if mode >= lexModeComment:
      var j = i
      while j < line.len:
        if config.nestComments and line.startsWithAt(config.blockOpen, j):
          inc depth
          j += config.blockOpen.len
        elif line.startsWithAt(config.blockClose, j):
          j += config.blockClose.len
          if depth > 0:
            dec depth
          else:
            mode = 0
            break
        else:
          inc j
      tokens.addToken(j, tokenComment)
      i = max(i + 1, j)
      continue

    let c = line[i]
    if c in {' ', '\t', '\r', '\f'}:
      var j = i + 1
      while j < line.len and line[j] in {' ', '\t', '\r', '\f'}:
        inc j
      tokens.addToken(j, tokenText)
      i = j
      continue

    if config.blockOpen.len > 0 and line.startsWithAt(config.blockOpen, i):
      mode = lexModeComment
      depth = 0
      let finish = i + config.blockOpen.len
      tokens.addToken(finish, tokenComment)
      i = finish
      continue
    var foundLineComment = false
    for marker in config.lineComments:
      if line.startsWithAt(marker, i):
        tokens.addToken(line.len, tokenComment)
        i = line.len
        foundLineComment = true
        break
    if foundLineComment:
      continue

    if config.directives and c == '#' and line[0 ..< i].strip().len == 0:
      var j = i + 1
      while j < line.len and line[j] in {' ', '\t'}: inc j
      while j < line.len and isIdentPart(line, j, ""): inc j
      tokens.addToken(j, tokenMeta)
      i = j
      continue

    if config.decorator != '\0' and c == config.decorator and
        i + 1 < line.len and isIdentStart(line, i + 1, config.identChars):
      var j = i + 1
      while j < line.len and (isIdentPart(line, j, config.identChars) or line[j] == '.'):
        inc j
      tokens.addToken(j, tokenMeta)
      i = j
      previousDot = false
      regexAllowed = false
      continue

    if config.variables and c == '$' and i + 1 < line.len:
      var j = i + 1
      if line[j] == '{':
        inc j
        while j < line.len and line[j] != '}': inc j
        if j < line.len: inc j
      elif isDigit(line[j]) or line[j] in {'@', '*', '#', '?', '!', '-'}:
        inc j
      else:
        while j < line.len and isIdentPart(line, j, "-"): inc j
      if j > i + 1:
        tokens.addToken(j, tokenVariable)
        i = j
        previousDot = false
        regexAllowed = false
        continue

    if config.startString(line, i, "", mode, tokens) > i:
      i += config.strings[mode - lexModeString].open.len
      previousDot = false
      continue

    if isDigit(c) or (c == '.' and i + 1 < line.len and
        isDigit(line[i + 1]) and not previousDot):
      let hex = c == '0' and i + 1 < line.len and line[i + 1] in {'x', 'X'}
      var j = i + 1
      while j < line.len:
        let d = line[j]
        if isDigit(d) or (d >= 'a' and d <= 'z') or
            (d >= 'A' and d <= 'Z') or d == '_':
          inc j
        elif d == '.' and j + 1 < line.len and isDigit(line[j + 1]):
          inc j
        elif d in {'+', '-'} and j > i and
            ((not hex and line[j - 1] in {'e', 'E'}) or
             (hex and line[j - 1] in {'p', 'P'})):
          inc j
        else:
          break
      tokens.addToken(j, tokenNumber)
      i = j
      previousDot = false
      regexAllowed = false
      continue

    if isIdentStart(line, i, config.identChars):
      var j = i
      while j < line.len and isIdentPart(line, j, config.identChars): inc j
      let word = line[i ..< j]
      if j < line.len and config.strings.len > 0:
        let stringStart = config.startString(line, j, word, mode, tokens)
        if stringStart > j:
          tokens.addToken(stringStart, tokenString)
          i = stringStart
          previousDot = false
          continue
      var key = word
      if config.foldCase: key = key.toLowerAscii()
      var kind = tokenVariable
      if not previousDot and key in config.words:
        kind = config.words[key]
      else:
        var next = j
        while next < line.len and line[next] in {' ', '\t'}: inc next
        if config.keys and next < line.len and line[next] == ':' and
            (next + 1 >= line.len or line[next + 1] != ':'):
          kind = tokenProperty
        elif config.calls and next < line.len and
            (line[next] == '(' or
             (line[next] == '!' and next + 1 < line.len and line[next + 1] == '(')):
          kind = tokenFunction
        elif previousDot:
          kind = tokenProperty
        elif config.capitalTypes and word[0] >= 'A' and word[0] <= 'Z':
          kind = tokenType
      tokens.addToken(j, kind)
      i = j
      previousDot = false
      regexAllowed = kind == tokenKeyword
      continue

    if config.regexps and c == '/' and regexAllowed and i + 1 < line.len and
        line[i + 1] notin {'/', '*'}:
      var j = i + 1
      var inClass = false
      while j < line.len:
        if line[j] == '\\':
          j = min(line.len, j + 2)
        elif line[j] == '[':
          inClass = true
          inc j
        elif line[j] == ']':
          inClass = false
          inc j
        elif line[j] == '/' and not inClass:
          break
        else:
          inc j
      if j < line.len:
        inc j
        while j < line.len and line[j] >= 'a' and line[j] <= 'z': inc j
        tokens.addToken(j, tokenRegexp)
        i = j
        regexAllowed = false
        continue

    if c in {'(', ')', '[', ']', '{', '}', ',', ';'}:
      tokens.addToken(i + 1, tokenPunctuation)
      regexAllowed = c notin {')', ']', '}'}
      previousDot = false
      inc i
      continue
    if c == '.':
      tokens.addToken(i + 1, tokenPunctuation)
      previousDot = true
      regexAllowed = false
      inc i
      continue
    if c in config.operators:
      var j = i + 1
      while j < line.len and line[j] in config.operators and
          not config.startsComment(line, j):
        inc j
      tokens.addToken(j, tokenOperator)
      i = j
      previousDot = false
      regexAllowed = true
      continue

    tokens.addToken(i + 1, tokenText)
    previousDot = false
    inc i

  if mode >= lexModeString and mode - lexModeString < config.strings.len and
      not config.strings[mode - lexModeString].multiline:
    mode = 0
    depth = 0
  result = uint64(mode and 0xff) or (uint64(depth and 0xff) shl 8)

proc builtinTokenizer(name: string): Tokenizer =
  if name in ["HTML", "XML", "Markdown", "Diff"]:
    return nil
  let config = lexConfig(name)
  result = proc(line: string; state: uint64;
                tokens: var seq[Token]): uint64 =
    lexLine(config, line, state, tokens)
