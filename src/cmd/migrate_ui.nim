## Preview or apply source-preserving migrations to the checked UI value API.

import std/[algorithm, os, strutils, tables]

const
  uiImportPath = "github.com/egoist/mygo/ui"
  usageMigrateUi* = """Usage: mygo migrate-ui [-write] [dir]

Preview changed Go files by default. Use -write to apply the migration.
"""
  nonElementFactories = [
    "View", "NewTester", "Render", "Local", "RGB", "RGBA", "Hex",
    "LightTheme", "DarkTheme", "ParseSVG", "MustParseSVG", "NewBitmap",
    "DecodeBitmap", "Shape", "ShapeText", "ShapeRichText", "NewRouter",
    "NewTextBuffer", "Fixed", "Fr", "FitContent", "Overlay", "Drop",
    "DragOver", "DropData", "DataDragOver", "RegisterFont",
    "AlertDialog", "FocusedValue"]
  elementQueries = [
    "Clicked", "Clicks", "Changed", "Submitted", "Hovered", "Pressed",
    "Focused", "FocusVisible", "FocusWithin", "Valid", "Shortcut", "ID",
    "Bounds", "IsDisabled", "PointerPosition", "Dragged", "TextSelection",
    "Composing", "DroppedFiles", "FileDragOver", "Dragging",
    "ClickModifiers", "DoubleClicked", "RightClicked", "PressedOutside",
    "Highlighted", "Loop", "Animate", "AnimateWith"]
  partsElements = ["Trigger", "Input", "Track", "List", "Root"]

type
  MigrationResult* = object
    source*: string
    changed*: bool
    notes*: seq[string]

  GoTokenKind = enum
    tokenIdentifier, tokenString, tokenNumber, tokenSymbol

  GoToken = object
    kind: GoTokenKind
    text: string
    first, past: int
    line: int

  TypeFact = object
    kind, objectName: string

  GoScope = object
    parent: int
    symbols: Table[string, TypeFact]
    returns: seq[TypeFact]
    functionScope: bool

  ScopeTree = object
    scopes: seq[GoScope]
    tokenScope, openScope: seq[int]

  FunctionInfo = object
    name, receiver: string
    receiverFact: TypeFact
    bodyOpen: int
    paramsOpen, paramsClose: int
    results: seq[TypeFact]

  PackageFacts = object
    structs: Table[string, Table[string, string]]
    returns: Table[string, seq[TypeFact]]

  Edit = object
    first, past: int
    replacement: string

  KeyMove = object
    contextFirst, contextPast: int
    contextText: string
    keys: seq[string]

proc isIdentStart(c: char): bool {.inline.} =
  c == '_' or c in {'a'..'z', 'A'..'Z'} or ord(c) >= 0x80

proc lexGo(source: string): tuple[tokens: seq[GoToken], pairs: seq[int]]

proc isIdentContinue(c: char): bool {.inline.} =
  isIdentStart(c) or c in {'0'..'9'}

proc isHex(c: char): bool {.inline.} =
  c in {'0'..'9', 'a'..'f', 'A'..'F'}

proc newGoScope(parent: int): GoScope =
  GoScope(parent: parent, symbols: initTable[string, TypeFact]())

proc makeScopeTree(tokens: seq[GoToken]): ScopeTree =
  result.scopes.add newGoScope(-1)
  result.tokenScope = newSeq[int](tokens.len)
  result.openScope = newSeq[int](tokens.len)
  for scope in result.openScope.mitems: scope = -1
  var stack = @[0]
  for i, token in tokens:
    if token.text == "{":
      result.tokenScope[i] = stack[^1]
      let next = result.scopes.len
      result.scopes.add newGoScope(stack[^1])
      result.openScope[i] = next
      stack.add next
    elif token.text == "}":
      result.tokenScope[i] = stack[^1]
      if stack.len > 1: stack.setLen(stack.len - 1)
    else:
      result.tokenScope[i] = stack[^1]

proc splitTopLevel(tokens: seq[GoToken]; pairs: seq[int];
                   first, past: int; separator: string): seq[(int, int)] =
  var start = first
  var i = first
  while i < past:
    if tokens[i].text == separator:
      result.add (start, i)
      start = i + 1
      inc i
    elif tokens[i].text in ["(", "[", "{"] and pairs[i] > i and
        pairs[i] < past:
      i = pairs[i] + 1
    else:
      inc i
  if start < past: result.add (start, past)

proc directUiType(tokens: seq[GoToken]; first, past: int; alias: string):
    tuple[kind: string, typeFirst: int] =
  if first < 0 or past > tokens.len or first >= past: return
  for i in first..<past:
    if tokens[i].text != alias or i + 2 >= past or tokens[i + 1].text != ".":
      continue
    var kind = tokens[i + 2].text
    if kind notin ["Context", "Element", "SelectParts", "ComboboxParts",
                   "TabsParts", "CollapsibleParts", "SegmentedParts",
                   "ToastParts"]:
      continue
    var typeFirst = i
    while typeFirst > first and tokens[typeFirst - 1].text == "*":
      dec typeFirst
    var prefixIsNames = true
    for j in first..<typeFirst:
      if tokens[j].kind != tokenIdentifier and tokens[j].text != ",":
        prefixIsNames = false
        break
    if prefixIsNames:
      return (kind, typeFirst)

proc typeFact(tokens: seq[GoToken]; first, past: int; alias: string): TypeFact =
  let ui = directUiType(tokens, first, past, alias)
  if ui.kind.len > 0:
    return TypeFact(kind: ui.kind)
  var start = first
  while start < past and tokens[start].text == "*": inc start
  if start + 1 == past and tokens[start].kind == tokenIdentifier:
    result.objectName = tokens[start].text

proc fieldNames(tokens: seq[GoToken]; first, past, typeFirst: int): seq[string] =
  if typeFirst <= first: return
  for i in first..<typeFirst:
    if tokens[i].kind == tokenIdentifier:
      result.add tokens[i].text

proc splitFields(tokens: seq[GoToken]; pairs: seq[int];
                 first, past: int): seq[(int, int)] =
  var start = first
  var i = first
  while i < past:
    if tokens[i].text == ";":
      if start < i: result.add (start, i)
      start = i + 1
      inc i
    elif tokens[i].line > tokens[i - 1].line and i > start:
      if start < i: result.add (start, i)
      start = i
      inc i
    elif tokens[i].text in ["(", "[", "{"] and pairs[i] > i and
        pairs[i] < past:
      i = pairs[i] + 1
    else:
      inc i
  if start < past: result.add (start, past)

proc parseNamedFacts(tokens: seq[GoToken]; pairs: seq[int];
                     first, past: int; alias: string):
    tuple[names: seq[string], facts: seq[TypeFact]] =
  var pending: seq[string]
  for (start, finish) in splitTopLevel(tokens, pairs, first, past, ","):
    let ui = directUiType(tokens, start, finish, alias)
    var fact: TypeFact
    var names: seq[string]
    if ui.kind.len > 0:
      fact.kind = ui.kind
      names = fieldNames(tokens, start, finish, ui.typeFirst)
    else:
      var typeStart = start
      while typeStart < finish and tokens[typeStart].text == "*":
        inc typeStart
      if typeStart + 1 < finish and tokens[typeStart].kind == tokenIdentifier and
          tokens[typeStart + 1].kind == tokenIdentifier:
        names.add tokens[typeStart].text
        fact = typeFact(tokens, typeStart + 1, finish, alias)
      elif typeStart + 2 < finish and tokens[typeStart].kind == tokenIdentifier and
          tokens[typeStart + 1].text == "*":
        names.add tokens[typeStart].text
        fact = typeFact(tokens, typeStart + 1, finish, alias)
      elif typeStart + 3 < finish and tokens[typeStart].kind == tokenIdentifier and
          tokens[typeStart + 1].kind == tokenIdentifier and
          tokens[typeStart + 2].text == ".":
        names.add tokens[typeStart].text
        fact = typeFact(tokens, typeStart + 1, finish, alias)
      else:
        fact = typeFact(tokens, start, finish, alias)
    if fact.kind.len == 0 and fact.objectName.len == 0:
      for i in start..<finish:
        if tokens[i].kind == tokenIdentifier: pending.add tokens[i].text
      continue
    names = pending & names
    pending.setLen(0)
    if names.len == 0:
      result.facts.add fact
    else:
      for name in names:
        result.names.add name
        result.facts.add fact

proc functionInfo(tokens: seq[GoToken]; pairs: seq[int]; index: int;
                  alias: string; declaration: bool): FunctionInfo =
  result.bodyOpen = -1
  var cursor = index + 1
  if declaration and cursor < tokens.len and tokens[cursor].text == "(":
    let receiverClose = pairs[cursor]
    if receiverClose < 0 or receiverClose + 1 >= tokens.len: return
    let receiver = parseNamedFacts(tokens, pairs, cursor + 1, receiverClose,
                                   alias)
    if receiver.names.len > 0:
      result.receiver = receiver.names[0]
      if receiver.facts.len > 0: result.receiverFact = receiver.facts[0]
    cursor = receiverClose + 1
  if declaration and cursor < tokens.len and
      tokens[cursor].kind == tokenIdentifier:
    result.name = tokens[cursor].text
    inc cursor
  if cursor < tokens.len and tokens[cursor].text == "[" and pairs[cursor] > cursor:
    cursor = pairs[cursor] + 1
  if cursor >= tokens.len or tokens[cursor].text != "(": return
  result.paramsOpen = cursor
  result.paramsClose = pairs[cursor]
  if result.paramsClose < 0: return
  var body = result.paramsClose + 1
  if body < tokens.len and tokens[body].text == "(":
    let endResults = pairs[body]
    if endResults < 0: return
    let parsed = parseNamedFacts(tokens, pairs, body + 1, endResults, alias)
    result.results = parsed.facts
    body = endResults + 1
  else:
    while body < tokens.len:
      if tokens[body].text == "{":
        if body > 0 and tokens[body - 1].text in ["interface", "struct"] and
            pairs[body] > body:
          body = pairs[body] + 1
          continue
        break
      if tokens[body].text in ["(", "[", "{"] and pairs[body] > body:
        body = pairs[body] + 1
      else:
        inc body
    if body > result.paramsClose + 1:
      let fact = typeFact(tokens, result.paramsClose + 1, body, alias)
      if fact.kind.len > 0 or fact.objectName.len > 0:
        result.results.add fact
  if body < tokens.len and tokens[body].text == "{":
    result.bodyOpen = body

proc prepareScopes(tokens: seq[GoToken]; pairs: seq[int]; alias: string):
    ScopeTree =
  result = makeScopeTree(tokens)
  for i, token in tokens:
    if token.text != "func": continue
    let isDeclaration = result.tokenScope[i] == 0
    let fn = functionInfo(tokens, pairs, i, alias, isDeclaration)
    if fn.bodyOpen < 0 or fn.bodyOpen >= result.openScope.len: continue
    let scopeId = result.openScope[fn.bodyOpen]
    if scopeId < 0: continue
    result.scopes[scopeId].functionScope = true
    result.scopes[scopeId].returns = fn.results
    var cursor = fn.paramsOpen + 1
    let parameters = parseNamedFacts(tokens, pairs, cursor, fn.paramsClose,
                                     alias)
    for i, name in parameters.names:
      if i < parameters.facts.len:
        result.scopes[scopeId].symbols[name] = parameters.facts[i]
    if fn.receiver.len > 0:
      result.scopes[scopeId].symbols[fn.receiver] = fn.receiverFact

proc resolveFact(scopes: seq[GoScope]; scopeId: int; name: string): TypeFact =
  var current = scopeId
  while current >= 0 and current < scopes.len:
    if scopes[current].symbols.hasKey(name):
      return scopes[current].symbols[name]
    current = scopes[current].parent

proc expressionFact(tokens: seq[GoToken]; pairs: seq[int]; endIndex: int;
                    alias: string; facts: PackageFacts;
                    scopes: seq[GoScope]; tokenScope: seq[int];
                    depth = 0): TypeFact =
  if endIndex < 0 or endIndex >= tokens.len or depth > 16: return
  let token = tokens[endIndex]
  if token.kind == tokenIdentifier:
    if endIndex >= 2 and tokens[endIndex - 1].text == ".":
      let field = token.text
      let receiver = expressionFact(tokens, pairs, endIndex - 2, alias, facts,
                                    scopes, tokenScope, depth + 1)
      if receiver.kind.endsWith("Parts") and field in partsElements:
        return TypeFact(kind: "Element")
      if receiver.kind == "Context" and field == "Root":
        return TypeFact(kind: "Element")
      if receiver.kind == "Context" and field == "Key":
        return TypeFact(kind: "Context")
      if receiver.objectName.len > 0 and
          facts.structs.hasKey(receiver.objectName):
        let fields = facts.structs[receiver.objectName]
        if fields.hasKey(field): return TypeFact(kind: fields[field])
      return
    if endIndex < tokenScope.len:
      return resolveFact(scopes, tokenScope[endIndex], token.text)
  elif token.text == ")":
    let open = pairs[endIndex]
    if open < 0: return
    var calleeEnd = open - 1
    if calleeEnd >= 0 and tokens[calleeEnd].text == "]":
      let genericOpen = pairs[calleeEnd]
      if genericOpen >= 0: calleeEnd = genericOpen - 1
    if calleeEnd >= 0 and tokens[calleeEnd].kind == tokenIdentifier:
      if calleeEnd >= 2 and tokens[calleeEnd - 1].text == "." and
          tokens[calleeEnd - 2].text == alias:
        let factory = tokens[calleeEnd].text
        if factory in nonElementFactories: return
        if factory in ["SelectBase", "TabsBase", "ComboboxBase",
                       "CollapsibleBase", "SegmentedBase", "ToastBase"]:
          return TypeFact(kind: "Parts")
        return TypeFact(kind: "Element")
      if calleeEnd >= 2 and tokens[calleeEnd - 1].text == ".":
        let methodName = tokens[calleeEnd].text
        let receiver = expressionFact(tokens, pairs, calleeEnd - 2, alias,
                                      facts, scopes, tokenScope, depth + 1)
        if receiver.kind == "Element" and methodName notin elementQueries:
          return receiver
        if receiver.kind.endsWith("Parts") and methodName in partsElements:
          return TypeFact(kind: "Element")
        if receiver.kind == "Context" and methodName == "Root":
          return TypeFact(kind: "Element")
        if receiver.kind == "Context" and methodName == "Key":
          return TypeFact(kind: "Context")
      if facts.returns.hasKey(tokens[calleeEnd].text):
        let returns = facts.returns[tokens[calleeEnd].text]
        if returns.len == 1: return returns[0]
    if calleeEnd == open - 1 and open + 1 < endIndex:
      return expressionFact(tokens, pairs, endIndex - 1, alias, facts,
                            scopes, tokenScope, depth + 1)
  elif token.text == "]":
    let open = pairs[endIndex]
    if open > 0:
      return expressionFact(tokens, pairs, open - 1, alias, facts, scopes,
                            tokenScope, depth + 1)
  elif token.text == "}":
    let open = pairs[endIndex]
    if open > 0 and open > 1 and tokens[open - 1].kind == tokenIdentifier:
      return TypeFact(objectName: tokens[open - 1].text)

proc assignmentEnd(tokens: seq[GoToken]; pairs: seq[int]; first: int): int =
  result = first
  var i = first
  while i < tokens.len:
    if i > first and tokens[i].line > tokens[i - 1].line and
        tokens[i - 1].text notin [".", ",", "=", ":=", "&", "|", "+", "-",
                                 "*", "/", "(", "[", "{"]:
      break
    if tokens[i].text in [",", ";", "}"]:
      break
    if tokens[i].text in ["(", "[", "{"] and pairs[i] > i:
      i = pairs[i] + 1
    else:
      inc i
  result = i

proc setVariableFact(scopes: var seq[GoScope]; scopeId: int; name: string;
                     fact: TypeFact; newDeclaration: bool) =
  if fact.kind.len == 0 and fact.objectName.len == 0: return
  if scopeId < 0 or scopeId >= scopes.len: return
  if newDeclaration:
    scopes[scopeId].symbols[name] = fact
    return
  var current = scopeId
  while current >= 0 and current < scopes.len:
    if scopes[current].symbols.hasKey(name):
      scopes[current].symbols[name] = fact
      return
    current = scopes[current].parent

proc callReturnFacts(tokens: seq[GoToken]; pairs: seq[int]; first, past: int;
                     facts: PackageFacts): seq[TypeFact] =
  if first >= past or tokens[past - 1].text != ")": return
  let open = pairs[past - 1]
  if open <= first: return
  var callee = open - 1
  if tokens[callee].text == "]":
    let genericOpen = pairs[callee]
    if genericOpen >= 0: callee = genericOpen - 1
  if callee >= first and tokens[callee].kind == tokenIdentifier and
      facts.returns.hasKey(tokens[callee].text):
    result = facts.returns[tokens[callee].text]

proc collectVariables(tokens: seq[GoToken]; pairs: seq[int]; alias: string;
                      facts: PackageFacts; tree: var ScopeTree) =
  for i, token in tokens:
    if token.text != "var" or i + 1 >= tokens.len: continue
    let scopeId = tree.tokenScope[i]
    if tokens[i + 1].text == "(":
      let close = pairs[i + 1]
      if close < 0: continue
      for (first, past) in splitFields(tokens, pairs, i + 2, close):
        let parsed = parseNamedFacts(tokens, pairs, first, past, alias)
        for j, name in parsed.names:
          if j < parsed.facts.len:
            tree.scopes[scopeId].symbols[name] = parsed.facts[j]
    else:
      let past = assignmentEnd(tokens, pairs, i + 1)
      let parsed = parseNamedFacts(tokens, pairs, i + 1, past, alias)
      for j, name in parsed.names:
        if j < parsed.facts.len:
          tree.scopes[scopeId].symbols[name] = parsed.facts[j]

  for _ in 0..<3:
    for i, token in tokens:
      if token.text notin [":=", "="] or i == 0 or i + 1 >= tokens.len:
        continue
      var names = @[tokens[i - 1].text]
      if tokens[i - 1].kind != tokenIdentifier or
          (i >= 2 and tokens[i - 2].text == "."):
        continue
      var lhs = i - 1
      while lhs >= 2 and tokens[lhs - 1].text == "," and
          tokens[lhs - 2].kind == tokenIdentifier:
        names.insert(tokens[lhs - 2].text, 0)
        lhs -= 2
      let scopeId = tree.tokenScope[i]
      let rhsEnd = assignmentEnd(tokens, pairs, i + 1)
      if rhsEnd <= i + 1: continue
      if rhsEnd == i + 2 and tokens[i + 1].text == "nil": continue
      var values = callReturnFacts(tokens, pairs, i + 1, rhsEnd, facts)
      if values.len != names.len:
        values.setLen(0)
        if names.len == 1:
          values.add expressionFact(tokens, pairs, rhsEnd - 1, alias, facts,
                                    tree.scopes, tree.tokenScope)
      if values.len != names.len: continue
      for j, name in names:
        if name == "_": continue
        let newDeclaration = token.text == ":="
        setVariableFact(tree.scopes, scopeId, name, values[j], newDeclaration)

proc collectPackageFacts(source, alias: string): PackageFacts =
  result.structs = initTable[string, Table[string, string]]()
  result.returns = initTable[string, seq[TypeFact]]()
  let parsed = lexGo(source)
  let tree = makeScopeTree(parsed.tokens)
  for i, token in parsed.tokens:
    if tree.tokenScope[i] != 0: continue
    if token.text == "struct" and alias.len > 0 and alias notin [".", "_"] and
        i > 0 and i + 1 < parsed.tokens.len and
        parsed.tokens[i + 1].text == "{" and parsed.pairs[i + 1] > i:
      let typeName = parsed.tokens[i - 1].text
      let close = parsed.pairs[i + 1]
      var fields = result.structs.getOrDefault(typeName,
        initTable[string, string]())
      for (first, past) in splitFields(parsed.tokens, parsed.pairs, i + 2,
                                       close):
        let ui = directUiType(parsed.tokens, first, past, alias)
        if ui.kind.len == 0: continue
        for name in fieldNames(parsed.tokens, first, past, ui.typeFirst):
          fields[name] = ui.kind
      result.structs[typeName] = fields
    elif token.text == "func":
      let fn = functionInfo(parsed.tokens, parsed.pairs, i, alias, true)
      if fn.bodyOpen >= 0 and fn.name.len > 0 and fn.receiver.len == 0:
        result.returns[fn.name] = fn.results

proc packageName(tokens: seq[GoToken]): string =
  for i, token in tokens:
    if token.text == "package" and i + 1 < tokens.len:
      return tokens[i + 1].text

proc collectTypeNotes(tokens: seq[GoToken]; pairs: seq[int]; alias: string):
    seq[string] =
  if alias.len == 0 or alias in [".", "_"]: return
  let tree = makeScopeTree(tokens)
  for i, token in tokens:
    if token.text != "struct" or tree.tokenScope[i] != 0 or i == 0 or
        i + 1 >= tokens.len or tokens[i + 1].text != "{" or
        pairs[i + 1] < 0:
      continue
    let close = pairs[i + 1]
    let typeName = tokens[i - 1].text
    for (first, past) in splitFields(tokens, pairs, i + 2, close):
      let ui = directUiType(tokens, first, past, alias)
      if ui.kind.len == 0: continue
      let advice = if ui.kind == "Context": "Services for retained window services"
        else: "Handle for persistent control identity"
      result.add "review stored " & ui.kind & " fields on " & typeName &
        "; use " & advice

proc lexGo(source: string): tuple[tokens: seq[GoToken], pairs: seq[int]] =
  var i = 0
  var line = 1
  var delimiters: seq[int]
  while i < source.len:
    let c = source[i]
    if c in {' ', '\t', '\r', '\n'}:
      if c == '\n': inc line
      inc i
      continue
    if c == '/' and i + 1 < source.len and source[i + 1] == '/':
      i += 2
      while i < source.len and source[i] != '\n': inc i
      continue
    if c == '/' and i + 1 < source.len and source[i + 1] == '*':
      let first = i
      i += 2
      var closed = false
      while i + 1 < source.len:
        if source[i] == '*' and source[i + 1] == '/':
          i += 2
          closed = true
          break
        if source[i] == '\n': inc line
        inc i
      if not closed:
        raise newException(ValueError,
          "unterminated block comment at byte " & $first)
      continue

    let first = i
    let tokenLine = line
    var kind: GoTokenKind
    if c == '"' or c == '\'' or c == '`':
      kind = tokenString
      inc i
      var closed = false
      while i < source.len:
        let current = source[i]
        if current == c:
          inc i
          closed = true
          break
        if current == '\n':
          if c != '`':
            raise newException(ValueError,
              "newline in quoted literal at byte " & $first)
          inc line
          inc i
        elif current == '\\' and c != '`':
          if i + 1 >= source.len:
            break
          if source[i + 1] == '\n': inc line
          i += 2
        else:
          inc i
      if not closed:
        raise newException(ValueError,
          "unterminated quoted literal at byte " & $first)
    elif isIdentStart(c):
      kind = tokenIdentifier
      inc i
      while i < source.len and isIdentContinue(source[i]): inc i
    elif c in {'0'..'9'}:
      kind = tokenNumber
      inc i
      while i < source.len and
          (isIdentContinue(source[i]) or source[i] == '.'):
        inc i
    else:
      kind = tokenSymbol
      var matched = false
      for symbol in ["...", ":=", "==", "!=", "<=", ">=", "&&", "||",
                     "++", "--", "<-", "+=", "-=", "*=", "/=", "%=",
                     "&=", "|=", "^=", "<<", ">>", "&^", "...", "=>"]:
        if i + symbol.len <= source.len and
            source[i ..< i + symbol.len] == symbol:
          i += symbol.len
          matched = true
          break
      if not matched: inc i

    let tokenIndex = result.tokens.len
    result.tokens.add GoToken(kind: kind, text: source[first ..< i],
                              first: first, past: i, line: tokenLine)
    result.pairs.add(-1)
    case result.tokens[^1].text
    of "(", "[", "{":
      delimiters.add tokenIndex
    of ")", "]", "}":
      if delimiters.len == 0:
        raise newException(ValueError,
          "unmatched " & result.tokens[^1].text & " at line " & $line)
      let openIndex = delimiters[^1]
      let openText = result.tokens[openIndex].text
      let expected = if result.tokens[^1].text == ")": "("
        elif result.tokens[^1].text == "]": "[" else: "{"
      if openText != expected:
        raise newException(ValueError,
          "mismatched delimiter at line " & $line)
      delimiters.setLen(delimiters.len - 1)
      result.pairs[openIndex] = tokenIndex
      result.pairs[tokenIndex] = openIndex
    else:
      discard
  if delimiters.len > 0:
    let token = result.tokens[delimiters[^1]]
    raise newException(ValueError,
      "unclosed " & token.text & " at line " & $token.line)

proc decodeImportPath(token: GoToken): string =
  if token.text.len < 2: return
  let quote = token.text[0]
  if quote == '`':
    return token.text[1 ..< token.text.high]
  var i = 1
  let finish = token.text.high
  while i < finish:
    if token.text[i] != '\\':
      result.add token.text[i]
      inc i
      continue
    inc i
    if i >= finish: return ""
    let escaped = token.text[i]
    case escaped
    of 'a': result.add '\a'; inc i
    of 'b': result.add '\b'; inc i
    of 'f': result.add '\f'; inc i
    of 'n': result.add '\n'; inc i
    of 'r': result.add '\r'; inc i
    of 't': result.add '\t'; inc i
    of 'v': result.add '\v'; inc i
    of '\\', '"', '\'': result.add escaped; inc i
    of 'x':
      if i + 2 >= finish or not isHex(token.text[i + 1]) or
          not isHex(token.text[i + 2]): return ""
      result.add char(parseHexInt(token.text[i + 1 .. i + 2]))
      i += 3
    of '0'..'7':
      if i + 2 >= finish or token.text[i + 1] notin {'0'..'7'} or
          token.text[i + 2] notin {'0'..'7'}: return ""
      let value = (ord(token.text[i]) - ord('0')) * 64 +
        (ord(token.text[i + 1]) - ord('0')) * 8 +
        ord(token.text[i + 2]) - ord('0')
      result.add char(value)
      i += 3
    else:
      return ""

proc importAlias(tokens: seq[GoToken]; pairs: seq[int]): tuple[
    alias: string, dotImport: bool] =
  for i, token in tokens:
    if token.text != "import" or token.kind != tokenIdentifier: continue
    if i + 1 >= tokens.len: continue
    if tokens[i + 1].text == "(":
      let close = pairs[i + 1]
      if close < 0: continue
      var j = i + 2
      while j < close:
        if tokens[j].kind != tokenString:
          inc j
          continue
        let path = decodeImportPath(tokens[j])
        if path == uiImportPath:
          if j > i + 2 and tokens[j - 1].line == tokens[j].line and
              tokens[j - 1].kind == tokenIdentifier:
            return (tokens[j - 1].text, false)
          if j > i + 2 and tokens[j - 1].line == tokens[j].line and
              tokens[j - 1].text in [".", "_"]:
            return (tokens[j - 1].text, tokens[j - 1].text == ".")
          return ("ui", false)
        inc j
    elif tokens[i + 1].kind == tokenString:
      if decodeImportPath(tokens[i + 1]) == uiImportPath:
        return ("ui", false)
    elif i + 2 < tokens.len and tokens[i + 2].kind == tokenString and
        decodeImportPath(tokens[i + 2]) == uiImportPath:
      return (tokens[i + 1].text, tokens[i + 1].text == ".")

proc isUiType(tokens: seq[GoToken]; i: int; alias: string): string =
  if i + 2 >= tokens.len or tokens[i].text != alias or
      tokens[i + 1].text != ".":
    return ""
  let name = tokens[i + 2].text
  if name in ["Context", "Element", "SelectParts", "ComboboxParts",
              "TabsParts", "CollapsibleParts", "SegmentedParts", "ToastParts"]:
    return name

proc expressionStart(tokens: seq[GoToken]; pairs: seq[int]; endIndex: int;
                     depth = 0): int =
  if endIndex < 0 or endIndex >= tokens.len or depth > 12: return endIndex
  if tokens[endIndex].kind == tokenIdentifier:
    result = endIndex
    while result >= 2 and tokens[result - 1].text == "." and
        tokens[result - 2].kind == tokenIdentifier:
      result -= 2
  elif tokens[endIndex].text == ")":
    let open = pairs[endIndex]
    if open < 0: return endIndex
    let calleeEnd = open - 1
    if calleeEnd >= 0 and tokens[calleeEnd].kind == tokenIdentifier:
      if calleeEnd >= 2 and tokens[calleeEnd - 1].text == ".":
        return expressionStart(tokens, pairs, calleeEnd - 2, depth + 1)
      return calleeEnd
    return open + 1
  elif tokens[endIndex].text == "]":
    let open = pairs[endIndex]
    if open >= 0: return expressionStart(tokens, pairs, open - 1, depth + 1)
    return endIndex
  else:
    result = endIndex

proc constructorCall(tokens: seq[GoToken]; pairs: seq[int]; endIndex: int;
                     alias: string; depth = 0): tuple[
    open, factory: int, found: bool] =
  if endIndex < 0 or endIndex >= tokens.len or depth > 16 or
      tokens[endIndex].text != ")":
    return
  let open = pairs[endIndex]
  if open < 0: return
  var calleeEnd = open - 1
  if calleeEnd >= 0 and tokens[calleeEnd].text == "]":
    let genericOpen = pairs[calleeEnd]
    if genericOpen >= 0: calleeEnd = genericOpen - 1
  if calleeEnd < 0: return
  if tokens[calleeEnd].kind == tokenIdentifier and calleeEnd >= 2 and
      tokens[calleeEnd - 1].text == "." and
      tokens[calleeEnd - 2].text == alias:
    if tokens[calleeEnd].text notin nonElementFactories:
      return (open, calleeEnd, true)
    return
  if tokens[calleeEnd].kind == tokenIdentifier and calleeEnd >= 2 and
      tokens[calleeEnd - 1].text == ".":
    return constructorCall(tokens, pairs, calleeEnd - 2, alias, depth + 1)
  if calleeEnd == open - 1 and open + 1 < endIndex:
    return constructorCall(tokens, pairs, endIndex - 1, alias, depth + 1)

proc functionReturn(scopes: seq[GoScope]; scopeId: int): seq[TypeFact] =
  var current = scopeId
  while current >= 0 and current < scopes.len:
    if scopes[current].functionScope: return scopes[current].returns
    current = scopes[current].parent

proc applyEdits(source: string; edits: var seq[Edit]): string =
  edits.sort(proc(a, b: Edit): int = cmp(b.first, a.first))
  result = source
  var lastStart = source.len + 1
  for edit in edits:
    if edit.first < 0 or edit.past < edit.first or edit.past > lastStart:
      raise newException(ValueError, "overlapping source edits")
    let suffix = if edit.past < result.len: result[edit.past .. ^1] else: ""
    let prefix = if edit.first > 0: result[0 ..< edit.first] else: ""
    result = prefix & edit.replacement & suffix
    lastStart = edit.first

proc migrateSource(source: string; facts: PackageFacts): MigrationResult =
  let (tokens, pairs) = lexGo(source)
  let (alias, dotImport) = importAlias(tokens, pairs)
  result.source = source
  if alias.len == 0 or alias == "_": return
  if dotImport:
    result.notes.add "replace the dot import with an explicit MyGo UI alias before migrating"
    return

  result.notes = collectTypeNotes(tokens, pairs, alias)
  var scopes = prepareScopes(tokens, pairs, alias)
  collectVariables(tokens, pairs, alias, facts, scopes)
  var edits: seq[Edit]
  var keyReviewNote = false
  var keyMoves = initTable[int, KeyMove]()
  for i in 0..<tokens.len:
    if tokens[i].text == "*" and i + 3 < tokens.len and
        tokens[i + 1].text == alias and tokens[i + 2].text == ".":
      let kind = isUiType(tokens, i + 1, alias)
      if kind.len > 0 and kind != "Context":
        edits.add Edit(first: tokens[i].first, past: tokens[i].past)

    if tokens[i].text == "Key" and i >= 2 and i + 1 < tokens.len and
        tokens[i - 1].text == "." and tokens[i + 1].text == "(":
      let keyClose = pairs[i + 1]
      if keyClose > i + 1:
        let receiverEnd = i - 2
        if expressionFact(tokens, pairs, receiverEnd, alias, facts,
                          scopes.scopes, scopes.tokenScope).kind == "Element":
          let constructor = constructorCall(tokens, pairs, receiverEnd, alias)
          var keyMoved = false
          if constructor.found:
            let constructorClose = pairs[constructor.open]
            if constructorClose > constructor.open:
              let constructorArgs = splitTopLevel(tokens, pairs,
                constructor.open + 1, constructorClose, ",")
              let keyArgs = splitTopLevel(tokens, pairs, i + 2, keyClose, ",")
              if constructorArgs.len > 0 and keyArgs.len == 1:
                let (contextFirst, contextPast) = constructorArgs[0]
                let (keyFirst, keyPast) = keyArgs[0]
                if contextFirst < contextPast and keyFirst < keyPast and
                    expressionFact(tokens, pairs, contextPast - 1, alias,
                                   facts, scopes.scopes,
                                   scopes.tokenScope).kind == "Context":
                  let contextText = source[tokens[contextFirst].first ..<
                                           tokens[contextPast - 1].past]
                  let keyText = source[tokens[keyFirst].first ..<
                                       tokens[keyPast - 1].past]
                  var move = keyMoves.getOrDefault(constructor.open,
                    KeyMove(contextFirst: tokens[contextFirst].first,
                      contextPast: tokens[contextPast - 1].past,
                      contextText: contextText))
                  move.keys.add keyText
                  keyMoves[constructor.open] = move
                  edits.add Edit(first: tokens[i - 1].first,
                    past: tokens[keyClose].past)
                  keyMoved = true
          if not keyMoved and not keyReviewNote:
            result.notes.add "move a stored element's Key to Context.Key before its constructor"
            keyReviewNote = true

    if tokens[i].text == "Rows" and i >= 2 and i + 2 < tokens.len and
        tokens[i - 1].text == "." and tokens[i + 1].text == "(":
      let close = pairs[i + 1]
      if close > i + 1 and close < tokens.len:
        let elementKind = expressionFact(tokens, pairs, i - 2, alias, facts,
                                         scopes.scopes, scopes.tokenScope).kind
        let args = splitTopLevel(tokens, pairs, i + 2, close, ",")
        if elementKind == "Element" and args.len == 1:
          let (argFirst, argPast) = args[0]
          let functionLiteral = tokens[argFirst].text == "func"
          let declaredFunction = argPast == argFirst + 1 and
            tokens[argFirst].kind == tokenIdentifier and
            facts.returns.hasKey(tokens[argFirst].text)
          if not functionLiteral and not declaredFunction:
            edits.add Edit(first: tokens[i].first, past: tokens[i].past,
                          replacement: "GridRows")

  for move in keyMoves.values:
    edits.add Edit(first: move.contextFirst, past: move.contextPast,
      replacement: move.contextText & ".Key(" & move.keys.join(").Key(") & ")")

  for i, token in tokens:
    if token.text in ["==", "!="] and i > 0 and i + 1 < tokens.len:
      if tokens[i + 1].text == "nil":
        let endIndex = i - 1
        if expressionFact(tokens, pairs, endIndex, alias, facts,
                          scopes.scopes, scopes.tokenScope).kind == "Element":
          let firstIndex = expressionStart(tokens, pairs, endIndex)
          let expression = source[tokens[firstIndex].first ..< tokens[endIndex].past]
          let replacement = (if token.text == "==": "!" else: "") &
            expression & ".Valid()"
          edits.add Edit(first: tokens[firstIndex].first,
                         past: tokens[i + 1].past,
                         replacement: replacement)
      elif tokens[i - 1].text == "nil":
        let firstIndex = i + 1
        if expressionFact(tokens, pairs, firstIndex, alias, facts,
                          scopes.scopes, scopes.tokenScope).kind == "Element":
          let lastIndex = firstIndex
          let expressionFirst = expressionStart(tokens, pairs, lastIndex)
          let expression = source[tokens[expressionFirst].first ..<
                                  tokens[lastIndex].past]
          let replacement = (if token.text == "==": "!" else: "") &
            expression & ".Valid()"
          edits.add Edit(first: tokens[i - 1].first,
                         past: tokens[lastIndex].past,
                         replacement: replacement)

    if token.text == "nil" and i > 0:
      if tokens[i - 1].text in ["=", ":="] and i >= 2:
        let lhsEnd = i - 2
        if expressionFact(tokens, pairs, lhsEnd, alias, facts,
                          scopes.scopes, scopes.tokenScope).kind == "Element":
          edits.add Edit(first: token.first, past: token.past,
                        replacement: alias & ".Element{}")
      elif tokens[i - 1].text == "return":
        let returns = functionReturn(scopes.scopes, scopes.tokenScope[i - 1])
        if returns.len > 0 and returns[0].kind == "Element":
          edits.add Edit(first: token.first, past: token.past,
                        replacement: alias & ".Element{}")

  if edits.len > 0:
    result.source = applyEdits(source, edits)
  result.changed = result.source != source

proc migrateFile*(filename, source: string): MigrationResult =
  ## Migrates one Go file, retaining its whitespace and comments.
  try:
    let tokens = lexGo(source)
    let (alias, _) = importAlias(tokens.tokens, tokens.pairs)
    result = migrateSource(source,
      collectPackageFacts(source, alias))
  except ValueError as error:
    raise newException(ValueError, filename & ": " & error.msg)

proc migrateFiles*(sources: Table[string, string]): Table[string, MigrationResult] =
  ## Shares imported UI syntax facts across files in the same package.
  var names: seq[string]
  for name in sources.keys: names.add name
  names.sort()
  var grouped = initTable[string, PackageFacts]()
  for name in names:
    try:
      let parsed = lexGo(sources[name])
      let (alias, _) = importAlias(parsed.tokens, parsed.pairs)
      let group = parentDir(name) & "\x00" & packageName(parsed.tokens)
      if not grouped.hasKey(group):
        grouped[group] = PackageFacts(
          structs: initTable[string, Table[string, string]](),
          returns: initTable[string, seq[TypeFact]]())
      let local = collectPackageFacts(sources[name], alias)
      for structName, localFields in local.structs:
        var fields = grouped[group].structs.getOrDefault(structName,
          initTable[string, string]())
        for fieldName, kind in localFields: fields[fieldName] = kind
        grouped[group].structs[structName] = fields
      for functionName, returns in local.returns:
        grouped[group].returns[functionName] = returns
    except ValueError as error:
      raise newException(ValueError, name & ": " & error.msg)
  for name in names:
    let parsed = lexGo(sources[name])
    let group = parentDir(name) & "\x00" & packageName(parsed.tokens)
    try:
      result[name] = migrateSource(sources[name], grouped[group])
    except ValueError as error:
      raise newException(ValueError, name & ": " & error.msg)

proc collectGoFiles(root: string; files: var seq[string]) =
  for kind, path in walkDir(root):
    if kind == pcDir:
      if path.splitPath.tail in [".git", "node_modules", "vendor", "build",
                                 ".mygo"]:
        continue
      collectGoFiles(path, files)
    elif path.endsWith(".go"):
      files.add path

proc runMigrateUI*(args: seq[string]): int =
  var write = false
  var positional = false
  var paths: seq[string]
  for arg in args:
    if not positional and arg == "--":
      positional = true
    elif not positional and arg in ["-h", "--help"]:
      stdout.write(usageMigrateUi)
      return 0
    elif not positional and arg in ["-write", "--write"]:
      write = true
    elif not positional and
        (arg.startsWith("-write=") or arg.startsWith("--write=")):
      let value = arg.toLowerAscii.split('=')[^1]
      if value in ["1", "t", "true"]:
        write = true
      elif value in ["0", "f", "false"]:
        write = false
      else:
        stderr.writeLine("mygo migrate-ui: invalid boolean value " & value)
        stderr.write(usageMigrateUi)
        return 2
    elif not positional and arg.startsWith("-"):
      stderr.writeLine("mygo migrate-ui: unknown flag " & arg)
      stderr.write(usageMigrateUi)
      return 2
    else:
      paths.add arg
  if paths.len > 1:
    stderr.writeLine("mygo migrate-ui: accepts one directory")
    stderr.write(usageMigrateUi)
    return 2

  try:
    let root = if paths.len == 0: getCurrentDir() else: paths[0]
    if not dirExists(root):
      raise newException(ValueError, root & " is not a directory")
    var names: seq[string]
    collectGoFiles(root, names)
    names.sort()
    var sources = initTable[string, string]()
    var permissions = initTable[string, set[FilePermission]]()
    for name in names:
      sources[name] = readFile(name)
      permissions[name] = getFilePermissions(name)
    let results = migrateFiles(sources)
    for name in names:
      let migrated = results[name]
      for note in migrated.notes:
        stdout.writeLine(name & ": " & note)
      if not migrated.changed: continue
      if write:
        writeFile(name, migrated.source)
        setFilePermissions(name, permissions[name])
      stdout.writeLine(name)
  except CatchableError as error:
    stderr.writeLine("mygo migrate-ui: " & error.msg)
    return 1
