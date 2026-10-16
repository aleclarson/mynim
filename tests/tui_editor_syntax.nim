import std/assertions
import mynim/ui/editor as editor

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

block buffer_language_binding:
  let buffer = editor.newBuffer("package main")
  let go = editor.languageFor("main.go")
  doAssert buffer.language == nil
  buffer.setLanguage(go)
  doAssert buffer.language == go
  buffer.setLanguage(nil)
  doAssert buffer.language == nil
