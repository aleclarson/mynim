## Copyright 2020 The Ebiten Authors
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
## https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##
## Modified by the MyGo contributors: uint and uvecN.

import std/unicode

type
  ShaderTokenKind* = enum
    stkIdentifier
    stkKeyword
    stkNumber
    stkString
    stkRawString
    stkRune
    stkSymbol
    stkSemicolon

  ShaderToken* = object
    ## A token and its byte-based source position.
    kind*: ShaderTokenKind
    text*: string
    offset*: int
    line*: int
    column*: int
    implicit*: bool

  ShaderLexError* = object
    ## The first lexical error in a source file.
    message*: string
    offset*: int
    line*: int
    column*: int

  ShaderLexResult* = object
    tokens*: seq[ShaderToken]
    error*: ShaderLexError

  Scanner = object
    source: string
    offset: int
    line: int
    column: int
    insertSemicolon: bool
    tokens: seq[ShaderToken]
    error: ShaderLexError

const
  keywords = [
    "break", "case", "chan", "const", "continue", "default", "defer",
    "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
    "interface", "map", "package", "range", "return", "select", "struct",
    "switch", "type", "var"
  ]

  operators = [
    "...", "<<=", ">>=", "&^=", "&&", "||", "<=", ">=", "==", "!=",
    "<<", ">>", "&^", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=",
    "|=", "^=", ":=", "<-"
  ]

proc current(s: Scanner; lookahead = 0): char {.inline.} =
  let at = s.offset + lookahead
  if at < s.source.len: s.source[at] else: '\0'

proc matches(s: Scanner; text: string): bool {.inline.} =
  let pastLast = s.offset + text.len
  pastLast <= s.source.len and s.source[s.offset ..< pastLast] == text

proc advance(s: var Scanner): char =
  result = s.source[s.offset]
  inc s.offset
  if result == '\n':
    inc s.line
    s.column = 1
  else:
    inc s.column

proc advanceRune(s: var Scanner) =
  let count = s.source.runeLenAt(s.offset)
  for _ in 0 ..< max(count, 1):
    discard s.advance()

proc isIdentifierStart(s: Scanner): bool =
  let c = s.current
  if c == '_' or c in {'a'..'z', 'A'..'Z'}:
    return true
  if ord(c) >= 0x80:
    return s.source.runeAt(s.offset).isAlpha

proc isIdentifierPart(s: Scanner): bool =
  s.isIdentifierStart or s.current in {'0'..'9'}

proc canEndStatement(token: ShaderToken): bool =
  if token.kind in {stkIdentifier, stkNumber, stkString, stkRawString, stkRune}:
    return true
  if token.kind == stkKeyword:
    return token.text in ["break", "continue", "fallthrough", "return"]
  token.kind == stkSymbol and token.text in [")", "]", "}", "++", "--"]

proc addToken(s: var Scanner; kind: ShaderTokenKind; start: int;
              line, column: int) =
  let token = ShaderToken(
    kind: kind,
    text: s.source[start ..< s.offset],
    offset: start,
    line: line,
    column: column
  )
  s.tokens.add token
  s.insertSemicolon = token.canEndStatement

proc addSemicolon(s: var Scanner; implicit: bool) =
  s.tokens.add ShaderToken(
    kind: stkSemicolon,
    text: ";",
    offset: s.offset,
    line: s.line,
    column: s.column,
    implicit: implicit
  )
  s.insertSemicolon = false

proc fail(s: var Scanner; message: string; offset, line, column: int) =
  if s.error.message.len == 0:
    s.error = ShaderLexError(
      message: message,
      offset: offset,
      line: line,
      column: column
    )

proc scanIdentifier(s: var Scanner) =
  let start = s.offset
  let line = s.line
  let column = s.column
  while s.isIdentifierPart:
    if ord(s.current) >= 0x80:
      s.advanceRune()
    else:
      discard s.advance()
  let text = s.source[start ..< s.offset]
  let kind = if text in keywords: stkKeyword else: stkIdentifier
  s.addToken(kind, start, line, column)

proc scanDigits(s: var Scanner; digits: set[char]) =
  while s.current in digits or s.current == '_':
    discard s.advance()

proc scanExponent(s: var Scanner; markers: set[char]) =
  if s.current notin markers:
    return
  discard s.advance()
  if s.current in {'+', '-'}:
    discard s.advance()
  s.scanDigits({'0'..'9'})

proc scanNumber(s: var Scanner) =
  let start = s.offset
  let line = s.line
  let column = s.column
  if s.current == '.':
    discard s.advance()
    s.scanDigits({'0'..'9'})
    s.scanExponent({'e', 'E'})
  elif s.current == '0' and s.current(1) in {'b', 'B', 'o', 'O'}:
    discard s.advance()
    discard s.advance()
    while s.current == '_' or s.current in {'0'..'9', 'a'..'z', 'A'..'Z'}:
      discard s.advance()
  elif s.current == '0' and s.current(1) in {'x', 'X'}:
    discard s.advance()
    discard s.advance()
    s.scanDigits({'0'..'9', 'a'..'f', 'A'..'F'})
    if s.current == '.' and s.current(1) != '.':
      discard s.advance()
      s.scanDigits({'0'..'9', 'a'..'f', 'A'..'F'})
    s.scanExponent({'p', 'P'})
  else:
    s.scanDigits({'0'..'9'})
    if s.current == '.' and s.current(1) != '.':
      discard s.advance()
      s.scanDigits({'0'..'9'})
    s.scanExponent({'e', 'E'})
  if s.current == 'i':
    discard s.advance()
  s.addToken(stkNumber, start, line, column)

proc scanQuoted(s: var Scanner; quote: char; kind: ShaderTokenKind) =
  let start = s.offset
  let line = s.line
  let column = s.column
  discard s.advance()
  while s.offset < s.source.len:
    let c = s.current
    if c == '\n':
      s.fail("newline in quoted literal", start, line, column)
      return
    discard s.advance()
    if c == '\\':
      if s.offset >= s.source.len or s.current == '\n':
        s.fail("unterminated quoted literal", start, line, column)
        return
      discard s.advance()
    elif c == quote:
      s.addToken(kind, start, line, column)
      return
  s.fail("unterminated quoted literal", start, line, column)

proc scanRawString(s: var Scanner) =
  let start = s.offset
  let line = s.line
  let column = s.column
  discard s.advance()
  while s.offset < s.source.len:
    if s.current == '`':
      discard s.advance()
      s.addToken(stkRawString, start, line, column)
      return
    discard s.advance()
  s.fail("unterminated raw string literal", start, line, column)

proc scanBlockComment(s: var Scanner) =
  let start = s.offset
  let line = s.line
  let column = s.column
  discard s.advance()
  discard s.advance()
  var hasNewline = false
  while s.offset < s.source.len:
    if s.matches("*/"):
      discard s.advance()
      discard s.advance()
      if hasNewline and s.insertSemicolon:
        s.addSemicolon(implicit = true)
      return
    if s.current == '\n':
      hasNewline = true
    discard s.advance()
  s.fail("unterminated block comment", start, line, column)

proc scanOperator(s: var Scanner): bool =
  for op in operators:
    if s.matches(op):
      let start = s.offset
      let line = s.line
      let column = s.column
      for _ in 0 ..< op.len:
        discard s.advance()
      s.addToken(stkSymbol, start, line, column)
      return true

proc scanShader(s: var Scanner) =
  while s.offset < s.source.len and s.error.message.len == 0:
    let c = s.current
    if c in {' ', '\t', '\r'}:
      discard s.advance()
    elif c == '\n':
      if s.insertSemicolon:
        s.addSemicolon(implicit = true)
      discard s.advance()
    elif s.matches("//"):
      while s.offset < s.source.len and s.current != '\n':
        discard s.advance()
    elif s.matches("/*"):
      s.scanBlockComment()
    elif c == '`':
      s.scanRawString()
    elif c == '"':
      s.scanQuoted(c, stkString)
    elif c == '\'':
      s.scanQuoted(c, stkRune)
    elif s.isIdentifierStart:
      s.scanIdentifier()
    elif c in {'0'..'9'} or (c == '.' and s.current(1) in {'0'..'9'}):
      s.scanNumber()
    elif ord(c) < 0x20 or ord(c) == 0x7f:
      s.fail("illegal control character", s.offset, s.line, s.column)
    elif not s.scanOperator():
      let start = s.offset
      let line = s.line
      let column = s.column
      discard s.advance()
      if c == ';':
        s.addToken(stkSemicolon, start, line, column)
      else:
        s.addToken(stkSymbol, start, line, column)
  if s.error.message.len == 0 and s.insertSemicolon:
    s.addSemicolon(implicit = true)

proc lexShaderSource*(source: string): ShaderLexResult =
  ## Tokenizes Go-style Kage source, recording byte offsets and inserting
  ## semicolons where Go would at line endings and end of file.
  let invalidUtf8At = source.validateUtf8()
  if invalidUtf8At >= 0:
    var line = 1
    var column = 1
    for i in 0 ..< invalidUtf8At:
      if source[i] == '\n':
        inc line
        column = 1
      else:
        inc column
    return ShaderLexResult(error: ShaderLexError(
      message: "invalid UTF-8 encoding",
      offset: invalidUtf8At,
      line: line,
      column: column
    ))
  var scanner = Scanner(source: source, line: 1, column: 1)
  scanner.scanShader()
  ShaderLexResult(tokens: scanner.tokens, error: scanner.error)
