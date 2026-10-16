## Language metadata and line-tokenizer types for native code editors.

import std/[strutils, tables]

type
  BracketMode = enum
    bracketCommon
    bracketCommonAndAngles
    bracketAngles
    bracketNone

  TokenKind* = enum ## The syntax role used to style a run of source text.
    tokenText
    tokenKeyword
    tokenType
    tokenFunction
    tokenVariable
    tokenProperty
    tokenConstant
    tokenNumber
    tokenString
    tokenEscape
    tokenRegexp
    tokenComment
    tokenOperator
    tokenPunctuation
    tokenTag
    tokenAttribute
    tokenMeta
    tokenHeading
    tokenEmphasis
    tokenStrong
    tokenLink
    tokenCode
    tokenInserted
    tokenDeleted
    tokenInvalid

  Token* = object ## One token run, ending at a UTF-8 byte offset in its line.
    pastLast*: int ## Exclusive byte offset from the start of the line.
    kind*: TokenKind ## Style role for the bytes since the previous token.

  Tokenizer* = proc(line: string; state: uint64;
                    tokens: var seq[Token]): uint64 {.closure.}
    ## Splits one line without its newline into byte-ranged tokens.
    ## The returned state is passed to the next line; equal states mean the
    ## tokenizer sees those lines in the same context.

  BracketPair* = object ## A pair used for bracket matching and auto-close.
    open*, close*: string ## Opening and closing text.
    notInKinds*: seq[TokenKind] ## Token kinds where auto-close is disabled.

  Language* = ref object ## Editing and syntax settings associated with a file.
    name*: string ## Display name, such as "Go" or "TypeScript".
    extensions*: seq[string] ## Lowercase extensions, including the dot.
    filenames*: seq[string] ## Exact basename matches, such as "Makefile".
    lineComment*: string ## Marker for comments through the end of a line.
    blockComment*: array[2, string] ## Opening and closing block-comment markers.
    brackets*: seq[BracketPair] ## Pairs recognized by editor navigation.
    autoClose*: seq[BracketPair] ## Pairs inserted while typing their opener.
    wordChars*: string ## Extra word characters beyond letters, digits and `_`.
    tabSize*: int ## Preferred indentation width; zero means unspecified.
    hardTabs*: bool ## Whether this language usually indents with tab bytes.
    tokenizer*: Tokenizer ## Optional line tokenizer; nil leaves text unstyled.

proc languageNamed*(name: string): Language
proc languages*(): seq[Language]
proc specialTokenizer(name: string): Tokenizer

include "lexer_impl"
include "special_lexer_impl"

proc brackets(mode: BracketMode): seq[BracketPair] =
  if mode in {bracketCommon, bracketCommonAndAngles}:
    result.add(BracketPair(open: "(", close: ")"))
    result.add(BracketPair(open: "[", close: "]"))
    result.add(BracketPair(open: "{", close: "}"))
  if mode in {bracketCommonAndAngles, bracketAngles}:
    result.add(BracketPair(open: "<", close: ">"))

proc autoClosePairs(quotes: seq[string];
                    excludedKinds: seq[TokenKind]): seq[BracketPair] =
  result = brackets(bracketCommon)
  for quote in quotes:
    result.add(BracketPair(open: quote, close: quote,
      notInKinds: excludedKinds))

proc builtin(name: string; extensions: seq[string];
             filenames: seq[string] = @[]; lineComment = "";
             blockOpen = ""; blockClose = ""; wordChars = "";
             tabSize = 4; hardTabs = false;
             bracketMode = bracketCommon;
             autoQuotes: seq[string] = @["\"", "'", "`"];
             autoCloseNotIn: seq[TokenKind] = @[tokenString, tokenComment];
             hasAutoClose = true): Language =
  Language(name: name, extensions: extensions, filenames: filenames,
    lineComment: lineComment, blockComment: [blockOpen, blockClose],
    brackets: brackets(bracketMode),
    autoClose: if hasAutoClose: autoClosePairs(autoQuotes, autoCloseNotIn)
      else: @[],
    wordChars: wordChars, tabSize: tabSize, hardTabs: hardTabs,
    tokenizer: builtinTokenizer(name))

let builtinLanguages = @[
  builtin("Go", @[".go"], lineComment = "//", blockOpen = "/*",
    blockClose = "*/", tabSize = 4, hardTabs = true),
  builtin("JavaScript", @[".js", ".mjs", ".cjs", ".jsx"],
    lineComment = "//", blockOpen = "/*", blockClose = "*/",
    wordChars = "$", tabSize = 2),
  builtin("TypeScript", @[".ts", ".mts", ".cts", ".tsx"],
    lineComment = "//", blockOpen = "/*", blockClose = "*/",
    wordChars = "$", tabSize = 2),
  builtin("JSON", @[".json", ".jsonc", ".json5", ".webmanifest"],
    @[".babelrc", ".eslintrc", "tsconfig.json"], "//", "/*", "*/",
    tabSize = 2, autoQuotes = @["\""]),
  builtin("Python", @[".py", ".pyi", ".pyw"], @["SConstruct", "SConscript"],
    "#", tabSize = 4, autoQuotes = @["\"", "'"]),
  builtin("Rust", @[".rs"], lineComment = "//", blockOpen = "/*",
    blockClose = "*/", tabSize = 4, autoQuotes = @["\""]),
  builtin("C", @[".c", ".h"], lineComment = "//", blockOpen = "/*",
    blockClose = "*/", autoQuotes = @["\"", "'"]),
  builtin("C++", @[".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx",
    ".ino", ".mm", ".m"], lineComment = "//", blockOpen = "/*",
    blockClose = "*/", autoQuotes = @["\"", "'"]),
  builtin("Java", @[".java"], lineComment = "//", blockOpen = "/*",
    blockClose = "*/", autoQuotes = @["\"", "'"]),
  builtin("Kotlin", @[".kt", ".kts"], lineComment = "//", blockOpen = "/*",
    blockClose = "*/", autoQuotes = @["\"", "'"]),
  builtin("Swift", @[".swift"], lineComment = "//", blockOpen = "/*",
    blockClose = "*/", autoQuotes = @["\""]),
  builtin("C#", @[".cs", ".csx"], lineComment = "//", blockOpen = "/*",
    blockClose = "*/", autoQuotes = @["\"", "'"]),
  builtin("Shell", @[".sh", ".bash", ".zsh", ".fish", ".ksh", ".command"],
    @[".bashrc", ".zshrc", ".profile", ".bash_profile", "PKGBUILD", ".envrc"],
    "#", tabSize = 2),
  builtin("YAML", @[".yaml", ".yml"], @[".clang-format"], "#",
    tabSize = 2, autoQuotes = @["\"", "'"]),
  builtin("TOML", @[".toml", ".ini", ".cfg", ".conf", ".properties",
    ".editorconfig"], @["Cargo.lock", ".gitconfig", ".npmrc"], "#",
    tabSize = 2, autoQuotes = @["\"", "'"]),
  builtin("SQL", @[".sql"], lineComment = "--", blockOpen = "/*",
    blockClose = "*/", tabSize = 2, autoQuotes = @["\"", "'"]),
  builtin("Ruby", @[".rb", ".rake", ".gemspec"],
    @["Gemfile", "Rakefile", "Podfile", "Fastfile"], "#", tabSize = 2,
    autoQuotes = @["\"", "'"]),
  builtin("Lua", @[".lua"], lineComment = "--", blockOpen = "--[[",
    blockClose = "]]", tabSize = 2, autoQuotes = @["\"", "'"]),
  builtin("PHP", @[".php"], lineComment = "//", blockOpen = "/*",
    blockClose = "*/", autoQuotes = @["\"", "'"]),
  builtin("CSS", @[".css", ".scss", ".less", ".sass", ".pcss"],
    blockOpen = "/*", blockClose = "*/", wordChars = "-", tabSize = 2,
    autoQuotes = @["\"", "'"]),
  builtin("HTML", @[".html", ".htm", ".xhtml", ".vue", ".svelte"],
    blockOpen = "<!--", blockClose = "-->", wordChars = "-", tabSize = 2,
    bracketMode = bracketCommonAndAngles, autoQuotes = @["\"", "'"]),
  builtin("XML", @[".xml", ".svg", ".plist", ".xsd", ".xsl", ".rss",
    ".atom", ".csproj", ".storyboard", ".xib"], blockOpen = "<!--",
    blockClose = "-->", wordChars = "-:", tabSize = 2,
    bracketMode = bracketAngles, autoQuotes = @["\"", "'"]),
  builtin("Markdown", @[".md", ".markdown", ".mdx", ".mkd"],
    @["README", "CHANGELOG"], blockOpen = "<!--", blockClose = "-->",
    tabSize = 2, autoQuotes = @["`"],
    autoCloseNotIn = @[tokenString, tokenComment]),
  builtin("Diff", @[".diff", ".patch", ".rej"],
    bracketMode = bracketNone, hasAutoClose = false),
  builtin("Dockerfile", @[".dockerfile"], @["Dockerfile", "Containerfile"],
    "#", autoQuotes = @["\"", "'"]),
  builtin("Makefile", @[".mk", ".mak"], @["Makefile", "makefile",
    "GNUmakefile"], "#", tabSize = 4, hardTabs = true,
    autoQuotes = @["\"", "'"]),
  builtin("Protobuf", @[".proto"], lineComment = "//", blockOpen = "/*",
    blockClose = "*/", tabSize = 2, autoQuotes = @["\""]),
  builtin("Zig", @[".zig", ".zon"], lineComment = "//", tabSize = 4,
    autoQuotes = @["\"", "'"]),
]

proc languages*(): seq[Language] =
  ## Returns the built-in language descriptors in their display order.
  for language in builtinLanguages:
    result.add(language)

proc alias(name: string): string =
  case name
  of "golang": result = "go"
  of "js", "node", "mjs", "cjs": result = "javascript"
  of "ts": result = "typescript"
  of "py", "python3": result = "python"
  of "sh", "bash", "zsh", "console", "shellscript", "fish": result = "shell"
  of "yml": result = "yaml"
  of "md": result = "markdown"
  of "rs": result = "rust"
  of "cpp", "cc", "cxx", "objc", "objective-c", "objectivec": result = "c++"
  of "cs", "csharp": result = "c#"
  of "kt": result = "kotlin"
  of "rb": result = "ruby"
  of "patch", "udiff": result = "diff"
  of "docker": result = "dockerfile"
  of "make", "mk": result = "makefile"
  of "svg", "plist": result = "xml"
  of "jsonc", "json5": result = "json"
  of "postgres", "postgresql", "mysql", "sqlite", "plsql": result = "sql"
  of "ini", "cfg", "conf": result = "toml"
  of "proto": result = "protobuf"
  of "scss", "less": result = "css"
  else: result = name

proc languageNamed*(name: string): Language =
  ## Finds a built-in language by name, extension, or common alias.
  let key = alias(name.strip().toLowerAscii())
  if key.len == 0:
    return
  for language in builtinLanguages:
    if language.name.toLowerAscii() == key:
      return language
    for extension in language.extensions:
      if extension[1..^1] == key:
        return language

proc baseName(path: string): string =
  let normalized = path.replace('\\', '/')
  let slash = normalized.rfind('/')
  if slash < 0:
    result = normalized
  elif slash + 1 < normalized.len:
    result = normalized[slash + 1..^1]

proc fileExtension(name: string): string =
  let dot = name.rfind('.')
  if dot >= 0:
    result = name[dot..^1].toLowerAscii()

proc languageFor*(filename: string): Language =
  ## Finds a built-in language by exact basename first, then extension.
  let base = baseName(filename)
  for language in builtinLanguages:
    if base in language.filenames:
      return language
  let extension = fileExtension(base)
  if extension.len == 0:
    return
  for language in builtinLanguages:
    if extension in language.extensions:
      return language
