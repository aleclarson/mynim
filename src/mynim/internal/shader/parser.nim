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
## Modified by the MyGo contributors: uint and uvecN, and dynamic loops.

import ./lexer

type
  ShaderAstExprKind* = enum
    saekIdentifier
    saekLiteral
    saekParenthesized
    saekUnary
    saekBinary
    saekCall
    saekSelector
    saekIndex
    saekSlice
    saekArrayType
    saekComposite
    saekKeyValue
    saekEllipsis

  ShaderAstExpr* = ref object
    ## An untyped shader expression; semantic resolution lowers it to shader IR.
    kind*: ShaderAstExprKind
    token*: ShaderToken
    name*: string
    operator*: string
    children*: seq[ShaderAstExpr]

  ShaderParseError* = object
    message*: string
    offset*: int
    line*: int
    column*: int

  ShaderExpressionResult* = object
    expr*: ShaderAstExpr
    error*: ShaderParseError

  ShaderFunctionDecl* = object
    ## A package-level function header and the raw tokens inside its body.
    name*: string
    token*: ShaderToken
    receiver*: bool
    bodyTokens*: seq[ShaderToken]

  ShaderSourceFile* = object
    packageName*: string
    functions*: seq[ShaderFunctionDecl]
    tokens*: seq[ShaderToken]

  ShaderFileResult* = object
    file*: ShaderSourceFile
    error*: ShaderParseError

  Parser = object
    tokens: seq[ShaderToken]
    index: int
    eof: ShaderToken
    error: ShaderParseError

proc current(p: Parser): ShaderToken {.inline.} =
  if p.index < p.tokens.len: p.tokens[p.index] else: p.eof

proc atEnd(p: Parser): bool {.inline.} =
  p.index >= p.tokens.len

proc advance(p: var Parser): ShaderToken =
  result = p.current
  if not p.atEnd:
    inc p.index

proc matches(p: Parser; text: string): bool {.inline.} =
  p.current.text == text

proc take(p: var Parser; text: string): bool =
  if p.matches(text):
    discard p.advance()
    return true

proc fail(p: var Parser; message: string) =
  if p.error.message.len == 0:
    let token = p.current
    p.error = ShaderParseError(
      message: message,
      offset: token.offset,
      line: token.line,
      column: token.column
    )

proc expect(p: var Parser; text: string): bool =
  if p.take(text):
    return true
  p.fail("expected '" & text & "', got '" & p.current.text & "'")

proc skipBalanced(p: var Parser; open, close: string;
                  contents: var seq[ShaderToken]): bool =
  if not p.expect(open):
    return false
  var depth = 1
  while not p.atEnd:
    let token = p.advance()
    if token.text == open:
      inc depth
    elif token.text == close:
      dec depth
      if depth == 0:
        return true
    contents.add token
  p.fail("unterminated '" & open & "' group")

proc skipDeclaration(p: var Parser) =
  discard p.advance()
  var parens = 0
  var brackets = 0
  var braces = 0
  while not p.atEnd:
    let token = p.current
    if token.kind == stkSemicolon and parens == 0 and brackets == 0 and braces == 0:
      discard p.advance()
      return
    case token.text
    of "(": inc parens
    of ")": parens = max(0, parens - 1)
    of "[": inc brackets
    of "]": brackets = max(0, brackets - 1)
    of "{": inc braces
    of "}": braces = max(0, braces - 1)
    else: discard
    discard p.advance()

proc endPosition(source: string): tuple[line, column: int]

proc parseFunctionDecl(p: var Parser): ShaderFunctionDecl =
  discard p.advance() # func
  if p.matches("("):
    result.receiver = true
    var receiver: seq[ShaderToken]
    discard p.skipBalanced("(", ")", receiver)
  let name = p.current
  if name.kind != stkIdentifier:
    p.fail("expected a function name")
    return
  result.name = name.text
  result.token = name
  discard p.advance()
  if p.matches("["):
    var typeParameters: seq[ShaderToken]
    discard p.skipBalanced("[", "]", typeParameters)
  if not p.matches("("):
    p.fail("expected a parameter list after function name")
    return
  var parameters: seq[ShaderToken]
  discard p.skipBalanced("(", ")", parameters)

  var parens = 0
  var brackets = 0
  var braces = 0
  while not p.atEnd and p.error.message.len == 0:
    let token = p.current
    if token.kind == stkSemicolon and parens == 0 and brackets == 0 and braces == 0:
      discard p.advance()
      return
    if token.text == "{" and parens == 0 and brackets == 0 and braces == 0 and
        (p.index == 0 or p.tokens[p.index - 1].text notin ["struct", "interface"]):
      discard p.skipBalanced("{", "}", result.bodyTokens)
      if p.error.message.len == 0 and not p.atEnd and
          p.current.kind != stkSemicolon:
        p.fail("expected a separator after function body")
      return
    case token.text
    of "(": inc parens
    of ")": parens = max(0, parens - 1)
    of "[": inc brackets
    of "]": brackets = max(0, brackets - 1)
    of "{": inc braces
    of "}": braces = max(0, braces - 1)
    else: discard
    discard p.advance()

proc parseShaderFile*(source: string): ShaderFileResult =
  ## Parses package-level declarations and function boundaries from shader source.
  let lexed = lexShaderSource(source)
  if lexed.error.message.len > 0:
    return ShaderFileResult(error: ShaderParseError(
      message: lexed.error.message,
      offset: lexed.error.offset,
      line: lexed.error.line,
      column: lexed.error.column
    ))
  let endPos = endPosition(source)
  var parser = Parser(
    tokens: lexed.tokens,
    eof: ShaderToken(offset: source.len, line: endPos.line, column: endPos.column)
  )
  result.file.tokens = lexed.tokens
  if parser.current.text != "package":
    parser.fail("expected a package clause")
  else:
    discard parser.advance()
    if parser.current.kind != stkIdentifier:
      parser.fail("expected a package name")
    else:
      result.file.packageName = parser.current.text
      discard parser.advance()
      if parser.current.kind == stkSemicolon:
        discard parser.advance()
      else:
        parser.fail("expected a separator after package clause")
  while not parser.atEnd and parser.error.message.len == 0:
    if parser.current.kind == stkSemicolon:
      discard parser.advance()
    elif parser.current.text == "func" and parser.current.kind == stkKeyword:
      let function = parser.parseFunctionDecl()
      if parser.error.message.len == 0:
        result.file.functions.add function
    elif parser.current.text in ["var", "const", "type", "import"] and
        parser.current.kind == stkKeyword:
      parser.skipDeclaration()
    else:
      parser.fail("expected a top-level declaration, got '" & parser.current.text & "'")
  result.error = parser.error

proc precedence(operator: string): int =
  case operator
  of "||": 1
  of "&&": 2
  of "==", "!=", "<", "<=", ">", ">=": 3
  of "+", "-", "|", "^": 4
  of "*", "/", "%", "<<", ">>", "&", "&^": 5
  else: 0

proc parseExpression(p: var Parser; minimumPrecedence = 1): ShaderAstExpr
proc parseTypeExpression(p: var Parser): ShaderAstExpr

proc parseComposite(p: var Parser; typeExpr: ShaderAstExpr): ShaderAstExpr =
  let open = p.advance()
  result = ShaderAstExpr(
    kind: saekComposite,
    token: open,
    children: @[typeExpr]
  )
  while not p.atEnd and not p.matches("}") and p.error.message.len == 0:
    var element = p.parseExpression()
    if p.take(":"):
      let value = p.parseExpression()
      element = ShaderAstExpr(
        kind: saekKeyValue,
        token: element.token,
        children: @[element, value]
      )
    result.children.add element
    if p.take(","):
      continue
    if not p.matches("}"):
      p.fail("expected ',' or '}' in composite literal")
  discard p.expect("}")

proc parseArrayType(p: var Parser): ShaderAstExpr =
  let open = p.advance()
  var length: ShaderAstExpr
  if p.matches("..."):
    let token = p.advance()
    length = ShaderAstExpr(kind: saekEllipsis, token: token)
  elif not p.matches("]"):
    length = p.parseExpression()
  let hasLength = length != nil
  discard p.expect("]")
  let elementType = p.parseTypeExpression()
  result = ShaderAstExpr(
    kind: saekArrayType,
    token: open,
    operator: if hasLength: "array" else: "slice",
    children: @[length, elementType]
  )

proc parseTypeExpression(p: var Parser): ShaderAstExpr =
  if p.matches("["):
    return p.parseArrayType()
  if p.matches("("):
    let open = p.advance()
    let inner = p.parseTypeExpression()
    discard p.expect(")")
    return ShaderAstExpr(kind: saekParenthesized, token: open, children: @[inner])
  let token = p.current
  if token.kind != stkIdentifier:
    p.fail("expected a type, got '" & token.text & "'")
    return
  discard p.advance()
  result = ShaderAstExpr(kind: saekIdentifier, token: token, name: token.text)
  while p.take("."):
    let field = p.current
    if field.kind != stkIdentifier:
      p.fail("expected a type name after '.'")
      return
    discard p.advance()
    result = ShaderAstExpr(
      kind: saekSelector,
      token: field,
      name: field.text,
      children: @[result]
    )

proc parsePrefix(p: var Parser): ShaderAstExpr =
  let token = p.current
  if token.text in ["+", "-", "!", "^", "&", "*", "<-"]:
    discard p.advance()
    let operand = p.parseExpression(6)
    return ShaderAstExpr(
      kind: saekUnary,
      token: token,
      operator: token.text,
      children: @[operand]
    )
  case token.kind
  of stkIdentifier:
    discard p.advance()
    result = ShaderAstExpr(kind: saekIdentifier, token: token, name: token.text)
  of stkNumber, stkString, stkRawString, stkRune:
    discard p.advance()
    result = ShaderAstExpr(kind: saekLiteral, token: token, name: token.text)
  of stkSymbol:
    if token.text == "(":
      discard p.advance()
      let inner = p.parseExpression()
      discard p.expect(")")
      result = ShaderAstExpr(kind: saekParenthesized, token: token, children: @[inner])
    elif token.text == "[":
      result = p.parseArrayType()
    elif token.text == "{":
      result = p.parseComposite(nil)
    else:
      p.fail("expected expression, got '" & token.text & "'")
  of stkKeyword, stkSemicolon:
    p.fail("expected expression, got '" & token.text & "'")

proc parsePostfix(p: var Parser; expr: ShaderAstExpr): ShaderAstExpr =
  result = expr
  while not p.atEnd and p.error.message.len == 0:
    if p.matches("("):
      let open = p.advance()
      var children = @[result]
      while not p.atEnd and not p.matches(")") and p.error.message.len == 0:
        var arg = p.parseExpression()
        if p.take("..."):
          arg = ShaderAstExpr(
            kind: saekEllipsis,
            token: arg.token,
            operator: "argument",
            children: @[arg]
          )
        children.add arg
        if p.take(","):
          continue
        if not p.matches(")"):
          p.fail("expected ',' or ')' in argument list")
      discard p.expect(")")
      result = ShaderAstExpr(kind: saekCall, token: open, children: children)
    elif p.take("."):
      let field = p.current
      if field.kind != stkIdentifier:
        p.fail("expected a selector name after '.'")
      else:
        discard p.advance()
        result = ShaderAstExpr(
          kind: saekSelector,
          token: field,
          name: field.text,
          children: @[result]
        )
    elif p.take("["):
      let open = p.tokens[p.index - 1]
      var low: ShaderAstExpr
      if not p.matches(":") and not p.matches("]"):
        low = p.parseExpression()
      if p.take(":"):
        var high: ShaderAstExpr
        var maximum: ShaderAstExpr
        if not p.matches(":") and not p.matches("]"):
          high = p.parseExpression()
        if p.take(":") and not p.matches("]"):
          maximum = p.parseExpression()
        discard p.expect("]")
        result = ShaderAstExpr(
          kind: saekSlice,
          token: open,
          children: @[result, low, high, maximum]
        )
      else:
        discard p.expect("]")
        if low == nil:
          p.fail("expected an index expression")
        result = ShaderAstExpr(kind: saekIndex, token: open, children: @[result, low])
    elif p.matches("{"):
      result = p.parseComposite(result)
    else:
      break

proc parseExpression(p: var Parser; minimumPrecedence = 1): ShaderAstExpr =
  result = p.parsePostfix(p.parsePrefix())
  while not p.atEnd and p.error.message.len == 0:
    let level = precedence(p.current.text)
    if level < minimumPrecedence:
      break
    let operator = p.advance()
    let right = p.parseExpression(level + 1)
    result = ShaderAstExpr(
      kind: saekBinary,
      token: operator,
      operator: operator.text,
      children: @[result, right]
    )

proc endPosition(source: string): tuple[line, column: int] =
  result = (line: 1, column: 1)
  for c in source:
    if c == '\n':
      inc result.line
      result.column = 1
    else:
      inc result.column

proc parseShaderExpression*(source: string): ShaderExpressionResult =
  ## Parses one Kage expression using Go operator precedence and postfix forms.
  let lexed = lexShaderSource(source)
  if lexed.error.message.len > 0:
    return ShaderExpressionResult(error: ShaderParseError(
      message: lexed.error.message,
      offset: lexed.error.offset,
      line: lexed.error.line,
      column: lexed.error.column
    ))
  let endPos = endPosition(source)
  var parser = Parser(
    tokens: lexed.tokens,
    eof: ShaderToken(offset: source.len, line: endPos.line, column: endPos.column)
  )
  result.expr = parser.parseExpression()
  if parser.error.message.len == 0 and parser.current.kind == stkSemicolon:
    discard parser.advance()
  if parser.error.message.len == 0 and not parser.atEnd:
    parser.fail("unexpected token '" & parser.current.text & "' after expression")
  if parser.error.message.len > 0:
    result.expr = nil
  result.error = parser.error
