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
    doAssert (language.tokenizer == nil) ==
      (language.name in ["HTML", "XML", "Markdown", "Diff"])

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

block buffer_language_binding:
  let buffer = editor.newBuffer("package main")
  let go = editor.languageFor("main.go")
  doAssert buffer.language == nil
  buffer.setLanguage(go)
  doAssert buffer.language == go
  buffer.setLanguage(nil)
  doAssert buffer.language == nil
