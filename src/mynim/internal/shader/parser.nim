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

  ShaderAstStmtKind* = enum
    saskBlock
    saskDeclaration
    saskAssignment
    saskExpression
    saskIncDec
    saskReturn
    saskBranch
    saskLabel
    saskIf
    saskFor
    saskRange

  ShaderAstStmt* = ref object
    ## An untyped statement; semantic resolution lowers it to shader IR.
    kind*: ShaderAstStmtKind
    token*: ShaderToken
    name*: string
    operator*: string
    expressions*: seq[ShaderAstExpr]
    statements*: seq[ShaderAstStmt]
    rawTokens*: seq[ShaderToken]

  ShaderStatementResult* = object
    statement*: ShaderAstStmt
    error*: ShaderParseError

  ShaderParameterDecl* = object
    ## One or more names that share a shader type.
    names*: seq[string]
    typeExpr*: ShaderAstExpr

  ParameterParseResult = object
    declarations: seq[ShaderParameterDecl]
    error: ShaderParseError

  ShaderGlobalDeclKind* = enum
    sgdkVariable
    sgdkConstant

  ShaderGlobalDecl* = object
    ## One source-level var/const specification.
    kind*: ShaderGlobalDeclKind
    token*: ShaderToken
    names*: seq[string]
    typeExpr*: ShaderAstExpr
    values*: seq[ShaderAstExpr]
    specIndex*: int
    inheritsPrevious*: bool

  GlobalParseResult = object
    declarations: seq[ShaderGlobalDecl]
    error: ShaderParseError

  ShaderFunctionDecl* = object
    ## A package-level function header, body syntax tree, and source tokens.
    name*: string
    token*: ShaderToken
    receiver*: bool
    parameters*: seq[ShaderParameterDecl]
    results*: seq[ShaderParameterDecl]
    hasBody*: bool
    body*: ShaderAstStmt
    bodyTokens*: seq[ShaderToken]

  ShaderSourceFile* = object
    packageName*: string
    globals*: seq[ShaderGlobalDecl]
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
    suppressComposite: bool

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

proc skipDeclaration(p: var Parser; consumeSeparator = true) =
  discard p.advance()
  var parens = 0
  var brackets = 0
  var braces = 0
  while not p.atEnd:
    let token = p.current
    if token.kind == stkSemicolon and parens == 0 and brackets == 0 and braces == 0:
      if consumeSeparator:
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
proc parseShaderStatements*(tokens: seq[ShaderToken]): ShaderStatementResult
proc parseParameterDeclarations(tokens: seq[ShaderToken]): ParameterParseResult
proc parseResultDeclarations(tokens: seq[ShaderToken]): ParameterParseResult
proc parseGlobalDeclaration(p: var Parser): GlobalParseResult

proc parseFunctionDecl(p: var Parser): ShaderFunctionDecl =
  discard p.advance() # func
  if p.matches("("):
    result.receiver = true
    var receiver: seq[ShaderToken]
    discard p.skipBalanced("(", ")", receiver)
    if p.error.message.len > 0:
      return
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
    if p.error.message.len > 0:
      return
  if not p.matches("("):
    p.fail("expected a parameter list after function name")
    return
  var parameters: seq[ShaderToken]
  discard p.skipBalanced("(", ")", parameters)
  if p.error.message.len > 0:
    return
  let parsedParameters = parseParameterDeclarations(parameters)
  if parsedParameters.error.message.len > 0:
    p.error = parsedParameters.error
    return
  result.parameters = parsedParameters.declarations

  var resultTokens: seq[ShaderToken]
  var parens = 0
  var brackets = 0
  var braces = 0
  while not p.atEnd and p.error.message.len == 0:
    let token = p.current
    if token.kind == stkSemicolon and parens == 0 and brackets == 0 and braces == 0:
      discard p.advance()
      let parsedResults = parseResultDeclarations(resultTokens)
      if parsedResults.error.message.len > 0:
        p.error = parsedResults.error
      else:
        result.results = parsedResults.declarations
      return
    if token.text == "{" and parens == 0 and brackets == 0 and braces == 0 and
        (p.index == 0 or p.tokens[p.index - 1].text notin ["struct", "interface"]):
      let parsedResults = parseResultDeclarations(resultTokens)
      if parsedResults.error.message.len > 0:
        p.error = parsedResults.error
        return
      result.results = parsedResults.declarations
      result.hasBody = p.skipBalanced("{", "}", result.bodyTokens)
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
    resultTokens.add token
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
      var function = parser.parseFunctionDecl()
      if parser.error.message.len == 0 and function.hasBody:
        let body = parseShaderStatements(function.bodyTokens)
        if body.error.message.len > 0:
          parser.error = body.error
        else:
          function.body = body.statement
      if parser.error.message.len == 0:
        result.file.functions.add function
    elif parser.current.text in ["var", "const"] and
        parser.current.kind == stkKeyword:
      let globals = parser.parseGlobalDeclaration()
      if globals.error.message.len > 0:
        parser.error = globals.error
      else:
        for declaration in globals.declarations:
          result.file.globals.add declaration
    elif parser.current.text in ["type", "import"] and
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

proc parserFor(tokens: seq[ShaderToken]): Parser =
  var eof = ShaderToken(line: 1, column: 1)
  if tokens.len > 0:
    let last = tokens[^1]
    eof = ShaderToken(
      offset: last.offset + last.text.len,
      line: last.line,
      column: last.column + last.text.len
    )
  Parser(tokens: tokens, eof: eof)

proc commaSegments(tokens: seq[ShaderToken]): seq[seq[ShaderToken]] =
  var start = 0
  var parens = 0
  var brackets = 0
  var braces = 0
  for i, token in tokens:
    if token.text == "," and parens == 0 and brackets == 0 and braces == 0:
      if start < i:
        result.add tokens[start ..< i]
      start = i + 1
      continue
    case token.text
    of "(": inc parens
    of ")": parens = max(0, parens - 1)
    of "[": inc brackets
    of "]": brackets = max(0, brackets - 1)
    of "{": inc braces
    of "}": braces = max(0, braces - 1)
    else: discard
  if start < tokens.len:
    result.add tokens[start .. ^1]

proc parseTypeTokens(tokens: seq[ShaderToken]): tuple[
    typeExpr: ShaderAstExpr, error: ShaderParseError] =
  var parser = parserFor(tokens)
  result.typeExpr = parser.parseTypeExpression()
  if parser.error.message.len == 0 and not parser.atEnd:
    parser.fail("unexpected token '" & parser.current.text & "' after type")
  result.error = parser.error

proc parseParameterDeclarations(tokens: seq[ShaderToken]): ParameterParseResult =
  if tokens.len == 0:
    return
  let segments = commaSegments(tokens)
  var pendingNames: seq[string]
  for i, segment in segments:
    if segment.len == 1 and segment[0].kind == stkIdentifier and
        i < segments.high:
      pendingNames.add segment[0].text
      continue

    var matchedNamedType = false
    for split in 1 ..< segment.len:
      var prefixIsNames = true
      var names: seq[string]
      for token in segment[0 ..< split]:
        if token.kind != stkIdentifier:
          prefixIsNames = false
          break
        names.add token.text
      if not prefixIsNames:
        continue
      let parsedType = parseTypeTokens(segment[split .. ^1])
      if parsedType.error.message.len == 0:
        result.declarations.add ShaderParameterDecl(
          names: pendingNames & names,
          typeExpr: parsedType.typeExpr
        )
        pendingNames.setLen(0)
        matchedNamedType = true
        break
    if matchedNamedType:
      continue

    let parsedType = parseTypeTokens(segment)
    if parsedType.error.message.len > 0:
      result.error = parsedType.error
      return
    var names = pendingNames
    if names.len == 0:
      names.add ""
    result.declarations.add ShaderParameterDecl(
      names: names,
      typeExpr: parsedType.typeExpr
    )
    pendingNames.setLen(0)
  if pendingNames.len > 0:
    let token = segments[^1][^1]
    result.error = ShaderParseError(
      message: "expected a type after parameter name",
      offset: token.offset + token.text.len,
      line: token.line,
      column: token.column + token.text.len
    )

proc parseResultDeclarations(tokens: seq[ShaderToken]): ParameterParseResult =
  if tokens.len == 0:
    return
  if tokens.len >= 2 and tokens[0].text == "(" and tokens[^1].text == ")":
    return parseParameterDeclarations(tokens[1 ..< tokens.len - 1])
  parseParameterDeclarations(tokens)

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
    elif p.matches("{") and not p.suppressComposite:
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

proc parseExpressionList(p: var Parser): seq[ShaderAstExpr] =
  result.add p.parseExpression()
  while p.take(",") and p.error.message.len == 0:
    result.add p.parseExpression()

proc parseValueSpec(p: var Parser; kind: ShaderGlobalDeclKind;
                    specIndex: int; grouped: bool): ShaderGlobalDecl =
  result.kind = kind
  result.specIndex = specIndex
  result.token = p.current
  if p.current.kind != stkIdentifier:
    p.fail("expected a name in variable declaration")
    return
  result.names.add p.advance().text
  while p.take(","):
    if p.current.kind != stkIdentifier:
      p.fail("expected a name after ',' in variable declaration")
      return
    result.names.add p.advance().text

  if not p.matches("=") and p.current.kind != stkSemicolon and
      not p.matches(")") and not p.atEnd:
    result.typeExpr = p.parseTypeExpression()
  if p.take("="):
    result.values = p.parseExpressionList()
  elif kind == sgdkConstant:
    if grouped and specIndex > 0:
      result.inheritsPrevious = true
    else:
      p.fail("a constant declaration requires a value")
  elif result.typeExpr == nil:
    p.fail("a variable declaration requires a type or value")

proc parseGlobalDeclaration(p: var Parser): GlobalParseResult =
  let keyword = p.advance()
  let kind = if keyword.text == "const": sgdkConstant else: sgdkVariable
  let grouped = p.take("(")
  if grouped:
    var specIndex = 0
    while not p.atEnd and not p.matches(")") and p.error.message.len == 0:
      if p.current.kind == stkSemicolon:
        discard p.advance()
        continue
      let declaration = p.parseValueSpec(kind, specIndex, grouped = true)
      if p.error.message.len > 0:
        break
      result.declarations.add declaration
      inc specIndex
      if p.current.kind == stkSemicolon:
        discard p.advance()
      elif not p.matches(")"):
        p.fail("expected ';' or ')' after declaration")
    if specIndex == 0 and p.error.message.len == 0:
      p.fail("a variable or constant group cannot be empty")
    if p.error.message.len == 0:
      discard p.expect(")")
  else:
    result.declarations.add p.parseValueSpec(kind, 0, grouped = false)
  result.error = p.error

proc parseSimpleStatement(p: var Parser): ShaderAstStmt =
  let token = p.current
  let expressions = p.parseExpressionList()
  if p.error.message.len > 0:
    return
  if p.current.text in ["=", ":=", "+=", "-=", "*=", "/=", "%=", "&=",
                        "|=", "^=", "<<=", ">>=", "&^="]:
    let operator = p.advance()
    let right = p.parseExpressionList()
    return ShaderAstStmt(
      kind: saskAssignment,
      token: token,
      operator: operator.text,
      expressions: expressions & right
    )
  if p.current.text in ["++", "--"]:
    let operator = p.advance()
    if expressions.len != 1:
      p.fail("increment and decrement require one expression")
      return
    return ShaderAstStmt(
      kind: saskIncDec,
      token: token,
      operator: operator.text,
      expressions: expressions
    )
  if expressions.len != 1:
    p.fail("an expression statement requires one expression")
    return
  ShaderAstStmt(kind: saskExpression, token: token, expressions: expressions)

proc parseStatement(p: var Parser): ShaderAstStmt

proc parseStatementList(p: var Parser; untilClose: bool): seq[ShaderAstStmt] =
  while not p.atEnd and p.error.message.len == 0 and
      (not untilClose or not p.matches("}")):
    if p.current.kind == stkSemicolon:
      discard p.advance()
      continue
    let start = p.index
    let statement = p.parseStatement()
    if p.error.message.len > 0:
      break
    if statement != nil:
      result.add statement
    if p.index == start:
      p.fail("expected a statement")
      break
    if p.current.kind == stkSemicolon:
      discard p.advance()
    elif untilClose and not p.matches("}"):
      p.fail("expected ';' or '}' after statement")
    elif not untilClose and not p.atEnd:
      p.fail("expected ';' after statement")

proc parseBlock(p: var Parser): ShaderAstStmt =
  let open = p.current
  if not p.expect("{"):
    return
  result = ShaderAstStmt(kind: saskBlock, token: open)
  result.statements = p.parseStatementList(untilClose = true)
  if p.error.message.len == 0:
    if p.atEnd:
      p.fail("unterminated block")
    else:
      discard p.expect("}")

proc parseIf(p: var Parser): ShaderAstStmt =
  let token = p.advance()
  let previousMode = p.suppressComposite
  p.suppressComposite = true
  let head = p.parseSimpleStatement()
  var condition: ShaderAstExpr
  var initializer: ShaderAstStmt
  if p.current.kind == stkSemicolon:
    initializer = head
    discard p.advance()
    condition = p.parseExpression()
  elif head != nil and head.kind == saskExpression and head.expressions.len == 1:
    condition = head.expressions[0]
  else:
    p.fail("expected a condition after 'if'")
  p.suppressComposite = previousMode
  if p.error.message.len > 0:
    return
  if not p.matches("{"):
    p.fail("expected a block after 'if' condition")
    return
  let thenBlock = p.parseBlock()
  result = ShaderAstStmt(kind: saskIf, token: token, expressions: @[condition])
  if initializer != nil:
    result.statements.add initializer
  result.statements.add thenBlock
  if p.take("else"):
    if p.matches("if"):
      result.statements.add p.parseIf()
    elif p.matches("{"):
      result.statements.add p.parseBlock()
    else:
      p.fail("expected 'if' or a block after 'else'")

proc hasRangeClause(p: Parser): bool =
  var parens = 0
  var brackets = 0
  var braces = 0
  for i in p.index ..< p.tokens.len:
    let token = p.tokens[i]
    if token.kind == stkSemicolon and parens == 0 and brackets == 0 and braces == 0:
      return false
    if token.text == "range" and token.kind == stkKeyword:
      return true
    case token.text
    of "(": inc parens
    of ")": parens = max(0, parens - 1)
    of "[": inc brackets
    of "]": brackets = max(0, brackets - 1)
    of "{": inc braces
    of "}":
      if braces == 0:
        return false
      dec braces
    else: discard

proc parseRange(p: var Parser; token: ShaderToken): ShaderAstStmt =
  result = ShaderAstStmt(kind: saskRange, token: token)
  if p.take("range"):
    result.expressions = @[p.parseExpression()]
  else:
    let left = p.parseExpressionList()
    if p.current.text notin ["=", ":="]:
      p.fail("expected '=' or ':=' before 'range'")
      return
    result.operator = p.advance().text
    result.expressions = left
    if not p.take("range"):
      p.fail("expected 'range' in range clause")
      return
    result.expressions.add p.parseExpression()
  if p.error.message.len == 0:
    if not p.matches("{"):
      p.fail("expected a block after range clause")
    else:
      result.statements.add p.parseBlock()

proc parseFor(p: var Parser): ShaderAstStmt =
  let token = p.advance()
  result = ShaderAstStmt(kind: saskFor, token: token)
  if p.matches("{"):
    result.statements.add p.parseBlock()
    return
  if p.hasRangeClause:
    let previousMode = p.suppressComposite
    p.suppressComposite = true
    result = p.parseRange(token)
    p.suppressComposite = previousMode
    return

  let previousMode = p.suppressComposite
  p.suppressComposite = true
  var initializer: ShaderAstStmt
  if p.current.kind != stkSemicolon:
    initializer = p.parseSimpleStatement()
  if p.current.kind == stkSemicolon:
    if initializer != nil:
      result.statements.add initializer
    discard p.advance()
    if p.current.kind != stkSemicolon:
      result.expressions.add p.parseExpression()
    if not p.expect(";"):
      p.suppressComposite = previousMode
      return
    if not p.matches("{"):
      result.statements.add p.parseSimpleStatement()
  elif initializer != nil and initializer.kind == saskExpression and
      initializer.expressions.len == 1:
    result.expressions.add initializer.expressions[0]
  else:
    p.fail("expected a condition or three-part clause after 'for'")
  p.suppressComposite = previousMode
  if p.error.message.len == 0:
    if not p.matches("{"):
      p.fail("expected a block after 'for' clause")
    else:
      result.statements.add p.parseBlock()

proc parseLocalDeclaration(p: var Parser): ShaderAstStmt =
  let start = p.index
  let token = p.current
  p.skipDeclaration(consumeSeparator = false)
  result = ShaderAstStmt(
    kind: saskDeclaration,
    token: token,
    rawTokens: p.tokens[start ..< p.index]
  )

proc parseStatement(p: var Parser): ShaderAstStmt =
  let token = p.current
  if token.kind == stkIdentifier and p.index + 1 < p.tokens.len and
      p.tokens[p.index + 1].text == ":":
    result = ShaderAstStmt(kind: saskLabel, token: token)
    result.name = token.text
    discard p.advance()
    discard p.advance()
    result.statements.add p.parseStatement()
    return
  case token.text
  of "{":
    return p.parseBlock()
  of "if":
    return p.parseIf()
  of "for":
    return p.parseFor()
  of "var", "const", "type":
    return p.parseLocalDeclaration()
  of "return":
    discard p.advance()
    result = ShaderAstStmt(kind: saskReturn, token: token)
    if not p.atEnd and p.current.kind != stkSemicolon and not p.matches("}"):
      result.expressions = p.parseExpressionList()
  of "break", "continue", "fallthrough", "goto":
    discard p.advance()
    result = ShaderAstStmt(kind: saskBranch, token: token, operator: token.text)
    if token.text == "goto" or token.text in ["break", "continue"]:
      if p.current.kind == stkIdentifier:
        result.name = p.advance().text
  else:
    return p.parseSimpleStatement()

proc tokenEnd(token: ShaderToken): tuple[offset, line, column: int] =
  result = (offset: token.offset, line: token.line, column: token.column)
  for c in token.text:
    inc result.offset
    if c == '\n':
      inc result.line
      result.column = 1
    else:
      inc result.column

proc parseShaderStatements*(tokens: seq[ShaderToken]): ShaderStatementResult =
  ## Parses the statement sequence captured inside one function body.
  var eof = ShaderToken(line: 1, column: 1)
  if tokens.len > 0:
    let endPos = tokenEnd(tokens[^1])
    eof = ShaderToken(offset: endPos.offset, line: endPos.line, column: endPos.column)
  var parser = Parser(tokens: tokens, eof: eof)
  result.statement = ShaderAstStmt(kind: saskBlock, token: eof)
  result.statement.statements = parser.parseStatementList(untilClose = false)
  if parser.error.message.len > 0:
    result.statement = nil
  result.error = parser.error

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
