import std/[sequtils, unittest]

import mynim/internal/shader/lexer

proc tokenTexts(source: string): seq[string] =
  let lexed = lexShaderSource(source)
  if lexed.error.message.len > 0:
    return
  for token in lexed.tokens:
    result.add token.text

suite "shader source lexer":
  test "recognizes identifiers, keywords, numeric forms, and longest operators":
    let lexed = lexShaderSource("package main\nvar α2 = .5 + 0x1.fp2<<=1 && true")
    check lexed.error.message.len == 0
    check tokenTexts("package main\nvar α2 = .5 + 0x1.fp2<<=1 && true") == @[
      "package", "main", ";", "var", "α2", "=", ".5", "+", "0x1.fp2", "<<=",
      "1", "&&", "true", ";"
    ]
    check lexed.tokens[0].kind == stkKeyword
    check lexed.tokens[4].kind == stkIdentifier
    check lexed.tokens[6].kind == stkNumber
    check lexed.tokens[9].text == "<<="

  test "inserts semicolons at line ends and after multiline comments":
    let source = "x := 1\nx++ /* comment\ncontinued */ return\n"
    let lexed = lexShaderSource(source)
    check lexed.error.message.len == 0
    check tokenTexts(source) == @[
      "x", ":=", "1", ";", "x", "++", ";", "return", ";"
    ]
    check lexed.tokens[3].kind == stkSemicolon
    check lexed.tokens[3].implicit
    check not lexed.tokens[1].implicit

  test "tracks byte offsets and line and column positions":
    let lexed = lexShaderSource("α2 := .5\nreturn")
    check lexed.error.message.len == 0
    check lexed.tokens[0].text == "α2"
    check lexed.tokens[0].offset == 0
    check lexed.tokens[0].line == 1
    check lexed.tokens[0].column == 1
    check lexed.tokens[2].text == ".5"
    check lexed.tokens[2].offset == 7
    check lexed.tokens[2].column == 8
    check lexed.tokens[4].text == "return"
    check lexed.tokens[4].line == 2
    check lexed.tokens[4].column == 1

  test "keeps literal contents as one token":
    let lexed = lexShaderSource("x := \"func Fragment() {}\"; y := `image3At(x)`; z := '\\n'")
    check lexed.error.message.len == 0
    check tokenTexts("x := \"func Fragment() {}\"; y := `image3At(x)`; z := '\\n'") == @[
      "x", ":=", "\"func Fragment() {}\"", ";", "y", ":=", "`image3At(x)`", ";",
      "z", ":=", "'\\n'", ";"
    ]
    check lexed.tokens[2].kind == stkString
    check lexed.tokens[6].kind == stkRawString
    check lexed.tokens[10].kind == stkRune

  test "lexes shader declarations, loops, swizzles, and image built-ins":
    let source = """
      package main
      var Seed uint
      var Taps [4]vec4

      func noise(seed uint) uint {
        value := seed*747796405 + 2891336453
        return (value >> 22) ^ value
      }

      func Fragment(dst vec4, pos vec2) vec4 {
        total := 0.0
        for i := 0; i < 4; i++ {
          total += Taps[i].z / (1 + distance(pos, Taps[i].xy))
        }
        return image0Sample(pos*pixelScale()) * float(noise(Seed)%255) * total
      }
    """
    let lexed = lexShaderSource(source)
    check lexed.error.message.len == 0
    check lexed.tokens.anyIt(it.kind == stkIdentifier and it.text == "Fragment")
    check lexed.tokens.anyIt(it.kind == stkIdentifier and it.text == "image0Sample")
    check lexed.tokens.anyIt(it.kind == stkSymbol and it.text == "++")

  test "reports unterminated comments and quoted literals":
    let comment = lexShaderSource("package main\n/* unfinished")
    check comment.error.message == "unterminated block comment"
    check comment.error.line == 2
    let literal = lexShaderSource("x := \"unfinished")
    check literal.error.message == "unterminated quoted literal"
    check literal.error.column == 6

  test "rejects invalid UTF-8 and control characters":
    let invalidUtf8 = lexShaderSource("x\xff")
    check invalidUtf8.error.message == "invalid UTF-8 encoding"
    check invalidUtf8.error.offset == 1
    let control = lexShaderSource("x\f")
    check control.error.message == "illegal control character"
    check control.error.column == 2
