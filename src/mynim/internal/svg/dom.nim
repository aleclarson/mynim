## dom.go: the document's elements, XML parsing, style sheets and the
## cascade.

## latin1 decodes the single-byte encodings old editors declare; other
## encodings are read as UTF-8.
proc latin1(data: string): string =
  result = newStringOfCap(data.len * 2)
  for c in data:
    let b = byte(c)
    if b < 0x80:
      result.add(c)
    else:
      result.add(char(0xC0 or (b shr 6)))
      result.add(char(0x80 or (b and 0x3F)))

proc localName(s: string): string =
  ## The local part of a qualified name, after its prefix.
  let c = s.find(':')
  if c >= 0: s[c + 1 ..< s.len] else: s

proc walk(e: elem; fn: proc(e: elem) {.closure.}) =
  fn(e)
  for k in e.kids:
    walk(k, fn)

## maxRules bounds the rules of a document's style sheets.
const maxRules = 4096

## rule is a rule of a style sheet with a single selector. selector
## is a compound selector: a type, an id and classes, any of which may
## be missing. Style sheets with combinators, pseudo-classes or
## attribute selectors are not matched.
type
  selector = object
    tag: string
    id: string
    classes: seq[string]
    spec: int ## specificity
  rule = object
    sel: selector
    decls: seq[decl]

proc match(s: selector; e: elem): bool =
  if (s.tag != "" and s.tag != e.name) or
      (s.id != "" and e.attrs.getOrDefault("id") != s.id):
    return false
  if s.classes.len > 0:
    let have = e.attrs.getOrDefault("class").splitWhiteSpace()
    for c in s.classes:
      if c notin have:
        return false
  true

proc stripComments(s: string): string =
  var s = s
  while true:
    let i = s.find("/*")
    if i < 0:
      return s
    let j = s.find("*/", i + 2)
    if j < 0:
      return s[0 ..< i]
    s = s[0 ..< i] & " " & s[j + 2 ..< s.len]

## blockEnd returns the index after the block opening at s[open].
proc blockEnd(s: string; open: int): int =
  var depth = 0
  for i in open ..< s.len:
    case s[i]
    of '{':
      inc depth
    of '}':
      dec depth
      if depth == 0:
        return i + 1
    else:
      discard
  s.len

proc isNameChar(c: byte): bool =
  c == byte('-') or c == byte('_') or
    (c >= byte('0') and c <= byte('9')) or
    (c >= byte('a') and c <= byte('z')) or
    (c >= byte('A') and c <= byte('Z')) or c >= 0x80

proc nameEnd(s: string; i: int): int =
  var i = i
  while i < s.len and isNameChar(byte(s[i])):
    inc i
  i

proc parseSelector(s: string): tuple[sel: selector, ok: bool] =
  var sel: selector
  if s == "":
    return (sel, false)
  var i = 0
  if s[0] == '*':
    i = 1
  elif isNameChar(byte(s[0])):
    i = nameEnd(s, 0)
    sel.tag = s[0 ..< i]
    inc sel.spec
  while i < s.len:
    let c = s[i]
    let j = nameEnd(s, i + 1)
    if j == i + 1 or (c != '.' and c != '#'):
      return (selector(), false)
    if c == '.':
      sel.classes.add(s[i + 1 ..< j])
      sel.spec += 100
    else:
      sel.id = s[i + 1 ..< j]
      sel.spec += 10000
    i = j
  (sel, true)

proc parseDecls(s: string): seq[decl] =
  ## Parses declarations, such as those of a style attribute.
  for part in s.split(';'):
    let ci = part.find(':')
    if ci < 0:
      continue
    let name = part[0 ..< ci].strip().toLower()
    var value = part[ci + 1 ..< part.len].strip()
    let ii = value.toLower().find("!important")
    if ii >= 0:
      value = value[0 ..< ii].strip()
    if name in properties and value != "":
      result.add(decl(name: name, value: value))

proc parseCss(s: string): seq[rule] =
  ## Parses the rules of a style sheet.
  var s = s
  while true:
    s = s.strip()
    if s == "":
      return
    if s.startsWith("/*"):
      let `end` = s.find("*/", 2)
      if `end` < 0:
        return
      s = s[`end` + 2 ..< s.len]
      continue
    if s.startsWith("<!--"):
      s = s[4 ..< s.len]
      continue
    if s.startsWith("-->"):
      s = s[3 ..< s.len]
      continue
    if s[0] == '@':
      ## An at-rule ends at a semicolon or with its block.
      let i = s.find({';', '{'})
      if i < 0:
        return
      if s[i] == ';':
        s = s[i + 1 ..< s.len]
      else:
        s = s[blockEnd(s, i) ..< s.len]
      continue
    let open = s.find('{')
    if open < 0:
      return
    let `end` = blockEnd(s, open)
    var body = s[open + 1 ..< `end`]
    body = body.strip(leading = false, chars = {' '})
    if body.endsWith("}"):
      body = body[0 ..< body.len - 1]
    let decls = parseDecls(stripComments(body))
    for part in stripComments(s[0 ..< open]).split(','):
      let (sel, ok) = parseSelector(part.strip())
      if ok:
        result.add(rule(sel: sel, decls: decls))
    s = s[`end` ..< s.len]

## cascade gives every element the declarations of its properties.
proc cascade(root: elem) =
  var rules: seq[rule]
  walk(root, proc(e: elem) =
    if e.name == "style":
      let t = e.attrs.getOrDefault("type")
      if t == "" or t == "text/css":
        rules.add(parseCss(e.text)))
  if rules.len > maxRules:
    rules.setLen(maxRules)
  ## Rules are filed under their id, first class or type, so that an
  ## element is matched against the rules it may match only.
  var byID = initTable[string, seq[int]]()
  var byClass = initTable[string, seq[int]]()
  var byTag = initTable[string, seq[int]]()
  var anyElem: seq[int]
  for i in 0 ..< rules.len:
    let s = rules[i].sel
    if s.id != "":
      byID.mgetOrPut(s.id, @[]).add(i)
    elif s.classes.len > 0:
      byClass.mgetOrPut(s.classes[0], @[]).add(i)
    elif s.tag != "":
      byTag.mgetOrPut(s.tag, @[]).add(i)
    else:
      anyElem.add(i)
  var matched: seq[int]
  walk(root, proc(e: elem) =
    for name, v in e.attrs:
      if name in properties:
        e.props.add(decl(name: name, value: v.strip()))
    matched.setLen(0)
    template match(candidates: seq[int]) =
      for i in candidates:
        if rules[i].sel.match(e):
          matched.add(i)
    match(anyElem)
    match(byTag.getOrDefault(e.name))
    let id = e.attrs.getOrDefault("id")
    if id != "":
      match(byID.getOrDefault(id))
    for c in e.attrs.getOrDefault("class").splitWhiteSpace():
      match(byClass.getOrDefault(c))
    ## By specificity, then in order.
    matched.sort(proc(a, b: int): int =
      let d = rules[a].sel.spec - rules[b].sel.spec
      if d != 0: d else: a - b)
    for i in deduplicate(matched):
      e.props.add(rules[i].decls)
    let s = e.attrs.getOrDefault("style", "")
    if s != "":
      e.props.add(parseDecls(s)))

proc parseXml(data: string): tuple[root: elem, err: string] =
  ## Parses the document's elements.
  var data = data
  ## Single-byte encodings are decoded up front, as Go's CharsetReader
  ## does.
  if data.startsWith("<?xml"):
    let e = data.find("?>")
    if e > 0:
      let decl0 = data[0 ..< e]
      var i = decl0.find("encoding")
      if i >= 0:
        i += 8
        while i < decl0.len and decl0[i] in {' ', '\t', '='}:
          inc i
        if i < decl0.len and (decl0[i] == '"' or decl0[i] == '\''):
          let q = decl0[i]
          inc i
          var j = i
          while j < decl0.len and decl0[j] != q:
            inc j
          case decl0[i ..< j].toLower()
          of "iso-8859-1", "latin1", "latin-1", "windows-1252", "cp1252":
            data = latin1(data)
          else:
            discard
  var root: elem
  var stack: seq[elem]
  var count = 0
  var skip = 0
  var p: XmlParser
  p.open(newStringStream(data), "")
  template err(): untyped =
    return (nil, "svg: " & p.errorMsg())
  while true:
    p.next()
    case p.kind
    of xmlError:
      err()
    of xmlElementStart, xmlElementOpen:
      if skip > 0 or stack.len >= maxDepth:
        inc skip
        continue
      inc count
      if count > maxElems:
        return (nil, "svg: too many elements")
      let e = elem(name: localName(p.elementName))
      e.attrs = initTable[string, string]()
      if p.kind == xmlElementOpen:
        while true:
          p.next()
          if p.kind == xmlAttribute:
            ## Namespaced attributes belong to editors, but for
            ## xlink:href, which href takes precedence over.
            let raw = p.attrKey
            let c = raw.find(':')
            let space = c >= 0
            let local = if space: raw[c + 1 ..< raw.len] else: raw
            if space and local != "href":
              continue
            if e.attrs.hasKey(local) and space:
              continue
            e.attrs[local] = p.attrValue
          elif p.kind == xmlElementClose:
            break
          elif p.kind == xmlError:
            err()
          else:
            discard
      if stack.len > 0:
        e.parent = stack[^1]
        e.parent.kids.add(e)
      else:
        root = e
      stack.add(e)
    of xmlElementEnd:
      if skip > 0:
        dec skip
        continue
      if stack.len > 0:
        stack.setLen(stack.len - 1)
      if stack.len == 0:
        if root.isNil or root.name != "svg":
          return (nil, "svg: no svg element")
        cascade(root)
        return (root, "")
    of xmlCharData, xmlCData, xmlWhitespace:
      if skip == 0 and stack.len > 0 and stack[^1].name == "style":
        stack[^1].text.add(p.charData)
    of xmlEof:
      break
    else:
      discard
  if root.isNil or root.name != "svg":
    return (nil, "svg: no svg element")
  cascade(root)
  (root, "")

