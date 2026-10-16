import std/assertions
import mynim/ui/editor as editor

proc scan(language: editor.Language; line: string; state = 0'u64):
    tuple[tokens: seq[editor.Token], nextState: uint64] =
  result.nextState = language.tokenizer(line, state, result.tokens)
  var pastLast = 0
  for token in result.tokens:
    doAssert token.pastLast > pastLast
    doAssert token.pastLast <= line.len
    pastLast = token.pastLast
  doAssert pastLast == line.len

proc hasKind(tokens: seq[editor.Token]; kind: editor.TokenKind): bool =
  for token in tokens:
    if token.kind == kind:
      return true

proc countKind(tokens: seq[editor.Token]; kind: editor.TokenKind): int =
  for token in tokens:
    if token.kind == kind:
      inc result

block built_in_language_lookup:
  doAssert editor.languages().len == 28
  doAssert editor.languageFor("main.go").name == "Go"
  doAssert editor.languageFor("a/b/Makefile").name == "Makefile"
  doAssert editor.languageFor("a\\b\\component.TSX").name == "TypeScript"
  doAssert editor.languageFor("Dockerfile").name == "Dockerfile"
  doAssert editor.languageFor(".bashrc").name == "Shell"
  doAssert editor.languageFor("README").name == "Markdown"
  doAssert editor.languageFor("unknown.ext") == nil

block language_name_aliases:
  doAssert editor.languageNamed(" GoLang ").name == "Go"
  doAssert editor.languageNamed("tsx").name == "TypeScript"
  doAssert editor.languageNamed("python3").name == "Python"
  doAssert editor.languageNamed("Objective-C").name == "C++"
  doAssert editor.languageNamed("jsonc").name == "JSON"
  doAssert editor.languageNamed("") == nil
  doAssert editor.languageNamed("unknown") == nil

block language_metadata_and_custom_tokenizer:
  let lang = editor.Language(name: "Notes", lineComment: "#", tabSize: 2,
    tokenizer: proc(line: string; state: uint64;
                    tokens: var seq[editor.Token]): uint64 =
      tokens.add(editor.Token(pastLast: line.len,
        kind: editor.tokenKeyword))
      state + 1)
  var tokens: seq[editor.Token]
  let nextState = lang.tokenizer("note", 4, tokens)
  doAssert nextState == 5
  doAssert tokens == @[editor.Token(pastLast: 4, kind: editor.tokenKeyword)]

  let go = editor.languageNamed("go")
  doAssert go.lineComment == "//"
  doAssert go.blockComment == ["/*", "*/"]
  doAssert go.hardTabs and go.tabSize == 4
  doAssert go.autoClose.len == 6
  doAssert editor.tokenString in go.autoClose[3].notInKinds
  doAssert editor.tokenComment in go.autoClose[3].notInKinds
  doAssert editor.languageNamed("html").brackets.len == 4
  doAssert editor.languageNamed("xml").brackets == @[
    editor.BracketPair(open: "<", close: ">")]
  doAssert editor.languageNamed("diff").brackets.len == 0
  doAssert editor.languageNamed("diff").autoClose.len == 0

block built_in_line_tokenizers:
  for language in editor.languages():
    doAssert language.tokenizer != nil

  let go = editor.languageNamed("go")
  let goLine = scan(go, "func main() { return 42 }")
  doAssert goLine.nextState == 0
  doAssert goLine.tokens.hasKind(editor.tokenKeyword)
  doAssert goLine.tokens.hasKind(editor.tokenFunction)
  doAssert goLine.tokens.hasKind(editor.tokenNumber)

  let commentStart = scan(go, "x := 1 /* open")
  doAssert commentStart.nextState != 0
  let commentEnd = scan(go, "close */ y", commentStart.nextState)
  doAssert commentEnd.nextState == 0
  doAssert commentEnd.tokens.hasKind(editor.tokenComment)
  doAssert commentEnd.tokens.hasKind(editor.tokenVariable)

  let rawStart = scan(go, "value := `raw")
  let rawEnd = scan(go, "still` + 1", rawStart.nextState)
  doAssert rawStart.nextState != 0
  doAssert rawEnd.nextState == 0
  doAssert rawEnd.tokens.hasKind(editor.tokenString)
  doAssert rawEnd.tokens.hasKind(editor.tokenOperator)
  doAssert rawEnd.tokens.hasKind(editor.tokenNumber)

  let js = scan(editor.languageNamed("js"), "x = /a[/]b/g.test(y)")
  doAssert js.tokens.hasKind(editor.tokenRegexp)
  doAssert js.tokens.hasKind(editor.tokenFunction)

  let py = scan(editor.languageNamed("python"), "@app.route(\"/\")")
  doAssert py.tokens.hasKind(editor.tokenMeta)
  doAssert py.tokens.hasKind(editor.tokenString)

  let c = scan(editor.languageNamed("c"), "#include <stdio.h>")
  doAssert c.tokens.hasKind(editor.tokenMeta)

block specialized_tokenizers:
  let json = scan(editor.languageNamed("json"), "{\"a\": [1, true, \"b\"]}")
  doAssert json.tokens.hasKind(editor.tokenProperty)
  doAssert json.tokens.hasKind(editor.tokenConstant)
  let jsonEscapedKeys = scan(editor.languageNamed("json"),
    "{\"a\\tb\": 1, \"c\": 2}")
  doAssert jsonEscapedKeys.tokens.countKind(editor.tokenProperty) == 2

  let toml = editor.languageNamed("toml")
  let table = scan(toml, "[server]")
  let setting = scan(toml, "port = 8080")
  doAssert table.tokens.hasKind(editor.tokenType)
  doAssert setting.tokens.hasKind(editor.tokenProperty)

  let css = editor.languageNamed("css")
  let selectors = scan(css, ".a:hover, #b { color: red; margin: -4px; }")
  doAssert selectors.tokens.hasKind(editor.tokenType)
  doAssert selectors.tokens.hasKind(editor.tokenKeyword)
  doAssert selectors.tokens.hasKind(editor.tokenProperty)
  doAssert selectors.tokens.hasKind(editor.tokenConstant)
  doAssert selectors.tokens.hasKind(editor.tokenNumber)
  let commentStart = scan(css, ".a { /* open")
  let commentEnd = scan(css, "close */ color: red;", commentStart.nextState)
  doAssert commentStart.nextState != 0
  doAssert commentEnd.tokens.hasKind(editor.tokenComment)
  doAssert commentEnd.tokens.hasKind(editor.tokenProperty)

  let html = editor.languageNamed("html")
  let markup = scan(html,
    "<div class=\"x\">a &amp; b<script>let y = 1</script>")
  doAssert markup.tokens.hasKind(editor.tokenTag)
  doAssert markup.tokens.hasKind(editor.tokenAttribute)
  doAssert markup.tokens.hasKind(editor.tokenEscape)
  doAssert markup.tokens.hasKind(editor.tokenKeyword)
  doAssert markup.tokens.hasKind(editor.tokenNumber)
  var htmlTokens: seq[editor.Token]
  let htmlComment = html.tokenizer("<!-- open", 0, htmlTokens)
  doAssert htmlComment != 0
  htmlTokens.setLen(0)
  let htmlCommentEnd = html.tokenizer("close --> <p>x</p>", htmlComment,
    htmlTokens)
  doAssert htmlCommentEnd == 0
  doAssert htmlTokens.hasKind(editor.tokenComment)
  doAssert htmlTokens.hasKind(editor.tokenTag)

  let xml = scan(editor.languageNamed("xml"), "<node key=\"value\">text</node>")
  doAssert xml.tokens.hasKind(editor.tokenTag)
  doAssert xml.tokens.hasKind(editor.tokenAttribute)
  doAssert xml.tokens.hasKind(editor.tokenString)

  let markdown = editor.languageNamed("markdown")
  let heading = scan(markdown, "# Title")
  let inline = scan(markdown, "Some *em* and **strong** `code` [link](url)")
  doAssert heading.tokens.hasKind(editor.tokenHeading)
  doAssert inline.tokens.hasKind(editor.tokenEmphasis)
  doAssert inline.tokens.hasKind(editor.tokenStrong)
  doAssert inline.tokens.hasKind(editor.tokenCode)
  doAssert inline.tokens.hasKind(editor.tokenLink)
  var markdownTokens: seq[editor.Token]
  let fence = markdown.tokenizer("```go", 0, markdownTokens)
  doAssert fence != 0
  markdownTokens.setLen(0)
  discard markdown.tokenizer("func x() {}", fence, markdownTokens)
  doAssert markdownTokens.hasKind(editor.tokenKeyword)
  markdownTokens.setLen(0)
  let closedFence = markdown.tokenizer("```", fence, markdownTokens)
  doAssert closedFence == 0
  var firstComment: seq[editor.Token]
  let markdownComment = markdown.tokenizer("before <!-- open", 0,
    firstComment)
  doAssert markdownComment != 0
  var secondComment: seq[editor.Token]
  let markdownCommentEnd = markdown.tokenizer("close --> after",
    markdownComment, secondComment)
  doAssert markdownCommentEnd == 0
  doAssert secondComment.hasKind(editor.tokenComment)

  let diff = editor.languageNamed("diff")
  let hunk = scan(diff, "@@ -1,2 +1,2 @@ func x")
  let removed = scan(diff, "-a")
  let added = scan(diff, "+b")
  doAssert hunk.tokens.hasKind(editor.tokenKeyword)
  doAssert hunk.tokens.hasKind(editor.tokenFunction)
  doAssert removed.tokens.hasKind(editor.tokenDeleted)
  doAssert added.tokens.hasKind(editor.tokenInserted)

block buffer_language_binding:
  let buffer = editor.newBuffer("package main")
  let go = editor.languageFor("main.go")
  doAssert buffer.language == nil
  buffer.setLanguage(go)
  doAssert buffer.language == go
  buffer.setLanguage(nil)
  doAssert buffer.language == nil
