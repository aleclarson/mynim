## Generated port of internal/l10n (MyGo's own strings). The Go original
## embeds JSON catalogs parsed by i18n.Catalog; here the catalogs are
## embedded as JSON and formatted by a small ICU-subset formatter, which
## the port of the full i18n package replaces when it lands.

import std/[strutils, tables, json, math, sequtils]

## The namespace of the keys with which apps change MyNim's strings:
## "mygo.<key>".
const namespace* = "mygo"

## The languages MyNim's own strings are translated to besides English.
const languages* = @["zh-Hans", "zh-Hant"]


const enCatalog = staticRead("l10n/en.json")
const zhHansCatalog = staticRead("l10n/zh-Hans.json")
const zhHantCatalog = staticRead("l10n/zh-Hant.json")

proc flattenCatalog(src: string): Table[string, string] =
  ## Reads "<key>": "<message>" entries (keys without a @ prefix).
  let j = parseJson(src)
  for k, v in j.pairs:
    if k.startsWith("@"): continue
    if v.kind == JString:
      result[k] = v.getStr()

var catalogs: Table[string, Table[string, string]]
var catalogsInit: bool

proc initCatalogs() =
  if catalogsInit: return
  catalogsInit = true
  catalogs["en"] = flattenCatalog(enCatalog)
  catalogs["zh-Hans"] = flattenCatalog(zhHansCatalog)
  catalogs["zh-Hant"] = flattenCatalog(zhHantCatalog)

proc catalogLanguages*(): seq[string] =
  ## The languages MyNim's own strings are translated to, English
  ## first (i18n.Catalog.Languages of MyGo's catalog).
  initCatalogs()
  result = @["en"] & toSeq(catalogs.keys).filterIt(it != "en")

proc icuFormat(msg: string; args: Table[string, string]): string =
  ## Enough of ICU MessageFormat for MyNim's own strings: {name}
  ## substitution, {name, plural, one{..} other{..}} with # for the
  ## number, {name, select, key{..} other{..}}, {n, number, ::group-off}
  ## (ungrouped integer) and {v, number, percent}.
  proc parseBody(s: string; i: var int): string
  proc parseArg(s: string; i: var int): string =
    inc i # at '{'
    var name = ""
    while i < s.len and s[i] notin {'}', ',', ' '}:
      name.add s[i]; inc i
    while i < s.len and s[i] == ' ': inc i
    if i < s.len and s[i] == '}':
      inc i
      return args.getOrDefault(name, "{" & name & "}")
    if i < s.len and s[i] == ',': inc i
    while i < s.len and s[i] == ' ': inc i
    var kind = ""
    while i < s.len and s[i] notin {'}', ',', ' '}:
      kind.add s[i]; inc i
    while i < s.len and s[i] == ' ': inc i
    if i < s.len and s[i] == ',': inc i
    while i < s.len and s[i] == ' ': inc i
    case kind
    of "plural", "select":
      var opts: seq[tuple[key, body: string]]
      while i < s.len:
        while i < s.len and s[i] == ' ': inc i
        if i >= s.len or s[i] == '}': break
        var k = ""
        while i < s.len and s[i] notin {'{', ' ', '='}:
          k.add s[i]; inc i
        while i < s.len and s[i] == ' ': inc i
        if i < s.len and s[i] == '=':
          inc i
          while i < s.len and s[i] in {'0'..'9'}: k.add s[i]; inc i
          k = "=" & k
          while i < s.len and s[i] == ' ': inc i
          while i < s.len and s[i] notin {'{', ' '}:
            # skipped: digits already read; allow forms like "one"
            k.add s[i]; inc i
          while i < s.len and s[i] == ' ': inc i
        if i < s.len and s[i] == '{':
          inc i
          opts.add (k, parseBody(s, i))
      let val = args.getOrDefault(name)
      if kind == "plural":
        for o in opts:
          if o.key == "=" & val:
            return o.body.replace("#", val)
        for o in opts:
          if o.key == "one" and val == "1":
            return o.body.replace("#", val)
        for o in opts:
          if o.key == "other":
            return o.body.replace("#", val)
        ""
      else:
        for o in opts:
          if o.key == val: return o.body
        for o in opts:
          if o.key == "other": return o.body
        ""
    of "number":
      var skel = ""
      while i < s.len and s[i] != '}':
        skel.add s[i]; inc i
      if i < s.len: inc i
      skel = skel.strip()
      let v = args.getOrDefault(name)
      try:
        if skel == "percent":
          let f = parseFloat(v) * 100
          if f == floor(f): return $int64(f) & "%"
          return formatFloat(f, ffDecimal, 1) & "%"
        let f = parseFloat(v)
        if f == floor(f): return $int64(f)
        return formatFloat(f, ffDecimal, 2)
      except ValueError:
        v
    else:
      while i < s.len and s[i] != '}': inc i
      if i < s.len: inc i
      args.getOrDefault(name, "{" & name & "}")
  proc parseBody(s: string; i: var int): string =
    while i < s.len and s[i] != '}':
      if s[i] == '{':
        result.add parseArg(s, i)
      else:
        result.add s[i]; inc i
    if i < s.len: inc i
  var i = 0
  while i < msg.len:
    if msg[i] == '{':
      result.add parseArg(msg, i)
    else:
      result.add msg[i]; inc i

type Messages* = object
  ## Says the messages in one language.
  locale: string

proc `in`*(locale: string): Messages = Messages(locale: locale)
  ## The messages in the language of locale, as "de" or
  ## "zh-Hant", or of the catalog's language that suits it
  ## best, "" for the source language.

proc format*(msgs: Messages; key: string; args: Table[string, string]): string =
  ## The message in the messages' language.
  initCatalogs()
  for tag in [msgs.locale, "", "en"]:
    let cat = catalogs.getOrDefault(tag)
    if cat.len == 0: continue
    if key in cat:
      return icuFormat(cat[key], args)
  key

proc previousMonth*(msgs: Messages): string =
  msgs.format("previousMonth", initTable[string, string]())

proc previousMonth*(): string =
  `in`("").previousMonth()

proc nextMonth*(msgs: Messages): string =
  msgs.format("nextMonth", initTable[string, string]())

proc nextMonth*(): string =
  `in`("").nextMonth()

proc undo*(msgs: Messages): string =
  msgs.format("undo", initTable[string, string]())

proc undo*(): string =
  `in`("").undo()

proc cut*(msgs: Messages): string =
  msgs.format("cut", initTable[string, string]())

proc cut*(): string =
  `in`("").cut()

proc copy*(msgs: Messages): string =
  msgs.format("copy", initTable[string, string]())

proc copy*(): string =
  `in`("").copy()

proc paste*(msgs: Messages): string =
  msgs.format("paste", initTable[string, string]())

proc paste*(): string =
  `in`("").paste()

proc delete*(msgs: Messages): string =
  msgs.format("delete", initTable[string, string]())

proc delete*(): string =
  `in`("").delete()

proc selectAll*(msgs: Messages): string =
  msgs.format("selectAll", initTable[string, string]())

proc selectAll*(): string =
  `in`("").selectAll()

proc find*(msgs: Messages): string =
  msgs.format("find", initTable[string, string]())

proc find*(): string =
  `in`("").find()

proc search*(msgs: Messages): string =
  msgs.format("search", initTable[string, string]())

proc search*(): string =
  `in`("").search()

proc clear*(msgs: Messages): string =
  msgs.format("clear", initTable[string, string]())

proc clear*(): string =
  `in`("").clear()

proc removeToken*(msgs: Messages; token: string): string =
  msgs.format("removeToken", {"token": token}.toTable)

proc removeToken*(token: string): string =
  `in`("").removeToken(token)

proc saturation*(msgs: Messages): string =
  msgs.format("saturation", initTable[string, string]())

proc saturation*(): string =
  `in`("").saturation()

proc hex*(msgs: Messages): string =
  msgs.format("hex", initTable[string, string]())

proc hex*(): string =
  `in`("").hex()

proc divider*(msgs: Messages): string =
  msgs.format("divider", initTable[string, string]())

proc divider*(): string =
  `in`("").divider()

proc developerTools*(msgs: Messages): string =
  msgs.format("developerTools", initTable[string, string]())

proc developerTools*(): string =
  `in`("").developerTools()

proc elements*(msgs: Messages): string =
  msgs.format("elements", initTable[string, string]())

proc elements*(): string =
  `in`("").elements()

proc more*(msgs: Messages): string =
  msgs.format("more", initTable[string, string]())

proc more*(): string =
  `in`("").more()

proc codeEditor*(msgs: Messages): string =
  msgs.format("codeEditor", initTable[string, string]())

proc codeEditor*(): string =
  `in`("").codeEditor()

proc goToDefinition*(msgs: Messages): string =
  msgs.format("goToDefinition", initTable[string, string]())

proc goToDefinition*(): string =
  `in`("").goToDefinition()

proc toggleComment*(msgs: Messages): string =
  msgs.format("toggleComment", initTable[string, string]())

proc toggleComment*(): string =
  `in`("").toggleComment()

proc selection*(msgs: Messages): string =
  msgs.format("selection", initTable[string, string]())

proc selection*(): string =
  `in`("").selection()

proc transform*(msgs: Messages): string =
  msgs.format("transform", initTable[string, string]())

proc transform*(): string =
  `in`("").transform()

proc folding*(msgs: Messages): string =
  msgs.format("folding", initTable[string, string]())

proc folding*(): string =
  `in`("").folding()

proc selectNextOccurrence*(msgs: Messages): string =
  msgs.format("selectNextOccurrence", initTable[string, string]())

proc selectNextOccurrence*(): string =
  `in`("").selectNextOccurrence()

proc selectAllOccurrences*(msgs: Messages): string =
  msgs.format("selectAllOccurrences", initTable[string, string]())

proc selectAllOccurrences*(): string =
  `in`("").selectAllOccurrences()

proc expandSelection*(msgs: Messages): string =
  msgs.format("expandSelection", initTable[string, string]())

proc expandSelection*(): string =
  `in`("").expandSelection()

proc splitIntoLines*(msgs: Messages): string =
  msgs.format("splitIntoLines", initTable[string, string]())

proc splitIntoLines*(): string =
  `in`("").splitIntoLines()

proc upperCase*(msgs: Messages): string =
  msgs.format("upperCase", initTable[string, string]())

proc upperCase*(): string =
  `in`("").upperCase()

proc lowerCase*(msgs: Messages): string =
  msgs.format("lowerCase", initTable[string, string]())

proc lowerCase*(): string =
  `in`("").lowerCase()

proc titleCase*(msgs: Messages): string =
  msgs.format("titleCase", initTable[string, string]())

proc titleCase*(): string =
  `in`("").titleCase()

proc snakeCase*(msgs: Messages): string =
  msgs.format("snakeCase", initTable[string, string]())

proc snakeCase*(): string =
  `in`("").snakeCase()

proc kebabCase*(msgs: Messages): string =
  msgs.format("kebabCase", initTable[string, string]())

proc kebabCase*(): string =
  `in`("").kebabCase()

proc camelCase*(msgs: Messages): string =
  msgs.format("camelCase", initTable[string, string]())

proc camelCase*(): string =
  `in`("").camelCase()

proc pascalCase*(msgs: Messages): string =
  msgs.format("pascalCase", initTable[string, string]())

proc pascalCase*(): string =
  `in`("").pascalCase()

proc sortLines*(msgs: Messages): string =
  msgs.format("sortLines", initTable[string, string]())

proc sortLines*(): string =
  `in`("").sortLines()

proc reverseLines*(msgs: Messages): string =
  msgs.format("reverseLines", initTable[string, string]())

proc reverseLines*(): string =
  `in`("").reverseLines()

proc uniqueLines*(msgs: Messages): string =
  msgs.format("uniqueLines", initTable[string, string]())

proc uniqueLines*(): string =
  `in`("").uniqueLines()

proc joinLines*(msgs: Messages): string =
  msgs.format("joinLines", initTable[string, string]())

proc joinLines*(): string =
  `in`("").joinLines()

proc trimTrailingWhitespace*(msgs: Messages): string =
  msgs.format("trimTrailingWhitespace", initTable[string, string]())

proc trimTrailingWhitespace*(): string =
  `in`("").trimTrailingWhitespace()

proc fold*(msgs: Messages): string =
  msgs.format("fold", initTable[string, string]())

proc fold*(): string =
  `in`("").fold()

proc unfold*(msgs: Messages): string =
  msgs.format("unfold", initTable[string, string]())

proc unfold*(): string =
  `in`("").unfold()

proc foldAll*(msgs: Messages): string =
  msgs.format("foldAll", initTable[string, string]())

proc foldAll*(): string =
  `in`("").foldAll()

proc unfoldAll*(msgs: Messages): string =
  msgs.format("unfoldAll", initTable[string, string]())

proc unfoldAll*(): string =
  `in`("").unfoldAll()

proc expandUp*(msgs: Messages): string =
  msgs.format("expandUp", initTable[string, string]())

proc expandUp*(): string =
  `in`("").expandUp()

proc expandDown*(msgs: Messages): string =
  msgs.format("expandDown", initTable[string, string]())

proc expandDown*(): string =
  `in`("").expandDown()

proc expandAll*(msgs: Messages): string =
  msgs.format("expandAll", initTable[string, string]())

proc expandAll*(): string =
  `in`("").expandAll()

proc expand*(msgs: Messages; what: string): string =
  msgs.format("expand", {"what": what}.toTable)

proc expand*(what: string): string =
  `in`("").expand(what)

proc unmodifiedLines*(msgs: Messages; n: string): string =
  msgs.format("unmodifiedLines", {"n": n}.toTable)

proc unmodifiedLines*(n: string): string =
  `in`("").unmodifiedLines(n)

proc revert*(msgs: Messages): string =
  msgs.format("revert", initTable[string, string]())

proc revert*(): string =
  `in`("").revert()

proc keep*(msgs: Messages): string =
  msgs.format("keep", initTable[string, string]())

proc keep*(): string =
  `in`("").keep()

proc hunkAction*(msgs: Messages; action: string): string =
  msgs.format("hunkAction", {"action": action}.toTable)

proc hunkAction*(action: string): string =
  `in`("").hunkAction(action)

proc line*(msgs: Messages; n: string): string =
  msgs.format("line", {"n": n}.toTable)

proc line*(n: string): string =
  `in`("").line(n)

proc newText*(msgs: Messages): string =
  msgs.format("newText", initTable[string, string]())

proc newText*(): string =
  `in`("").newText()

proc oldText*(msgs: Messages): string =
  msgs.format("oldText", initTable[string, string]())

proc oldText*(): string =
  `in`("").oldText()

proc invalid*(msgs: Messages): string =
  msgs.format("invalid", initTable[string, string]())

proc invalid*(): string =
  `in`("").invalid()

proc noResults*(msgs: Messages): string =
  msgs.format("noResults", initTable[string, string]())

proc noResults*(): string =
  `in`("").noResults()

proc matches*(msgs: Messages; current: string, total: string): string =
  msgs.format("matches", {"current": current, "total": total}.toTable)

proc matches*(current: string, total: string): string =
  `in`("").matches(current, total)

proc matchesMore*(msgs: Messages; current: string, total: string): string =
  msgs.format("matchesMore", {"current": current, "total": total}.toTable)

proc matchesMore*(current: string, total: string): string =
  `in`("").matchesMore(current, total)

proc matchCase*(msgs: Messages): string =
  msgs.format("matchCase", initTable[string, string]())

proc matchCase*(): string =
  `in`("").matchCase()

proc matchWholeWord*(msgs: Messages): string =
  msgs.format("matchWholeWord", initTable[string, string]())

proc matchWholeWord*(): string =
  `in`("").matchWholeWord()

proc useRegularExpression*(msgs: Messages): string =
  msgs.format("useRegularExpression", initTable[string, string]())

proc useRegularExpression*(): string =
  `in`("").useRegularExpression()

proc findInSelection*(msgs: Messages): string =
  msgs.format("findInSelection", initTable[string, string]())

proc findInSelection*(): string =
  `in`("").findInSelection()

proc previousMatch*(msgs: Messages): string =
  msgs.format("previousMatch", initTable[string, string]())

proc previousMatch*(): string =
  `in`("").previousMatch()

proc nextMatch*(msgs: Messages): string =
  msgs.format("nextMatch", initTable[string, string]())

proc nextMatch*(): string =
  `in`("").nextMatch()

proc replace*(msgs: Messages): string =
  msgs.format("replace", initTable[string, string]())

proc replace*(): string =
  `in`("").replace()

proc replaceAll*(msgs: Messages): string =
  msgs.format("replaceAll", initTable[string, string]())

proc replaceAll*(): string =
  `in`("").replaceAll()

proc close*(msgs: Messages): string =
  msgs.format("close", initTable[string, string]())

proc close*(): string =
  `in`("").close()

proc goToLine*(msgs: Messages): string =
  msgs.format("goToLine", initTable[string, string]())

proc goToLine*(): string =
  `in`("").goToLine()

proc lineRange*(msgs: Messages; lines: string): string =
  msgs.format("lineRange", {"lines": lines}.toTable)

proc lineRange*(lines: string): string =
  `in`("").lineRange(lines)

proc currentLine*(msgs: Messages; line: string, lines: string, column: string): string =
  msgs.format("currentLine", {"line": line, "lines": lines, "column": column}.toTable)

proc currentLine*(line: string, lines: string, column: string): string =
  `in`("").currentLine(line, lines, column)

proc completions*(msgs: Messages): string =
  msgs.format("completions", initTable[string, string]())

proc completions*(): string =
  `in`("").completions()

proc menuUndo*(msgs: Messages): string =
  msgs.format("menuUndo", initTable[string, string]())

proc menuUndo*(): string =
  `in`("").menuUndo()

proc menuRedo*(msgs: Messages): string =
  msgs.format("menuRedo", initTable[string, string]())

proc menuRedo*(): string =
  `in`("").menuRedo()

proc menuCut*(msgs: Messages): string =
  msgs.format("menuCut", initTable[string, string]())

proc menuCut*(): string =
  `in`("").menuCut()

proc menuCopy*(msgs: Messages): string =
  msgs.format("menuCopy", initTable[string, string]())

proc menuCopy*(): string =
  `in`("").menuCopy()

proc menuPaste*(msgs: Messages): string =
  msgs.format("menuPaste", initTable[string, string]())

proc menuPaste*(): string =
  `in`("").menuPaste()

proc menuPasteAndMatchStyle*(msgs: Messages): string =
  msgs.format("menuPasteAndMatchStyle", initTable[string, string]())

proc menuPasteAndMatchStyle*(): string =
  `in`("").menuPasteAndMatchStyle()

proc menuDelete*(msgs: Messages): string =
  msgs.format("menuDelete", initTable[string, string]())

proc menuDelete*(): string =
  `in`("").menuDelete()

proc menuSelectAll*(msgs: Messages): string =
  msgs.format("menuSelectAll", initTable[string, string]())

proc menuSelectAll*(): string =
  `in`("").menuSelectAll()

proc menuReload*(msgs: Messages): string =
  msgs.format("menuReload", initTable[string, string]())

proc menuReload*(): string =
  `in`("").menuReload()

proc menuForceReload*(msgs: Messages): string =
  msgs.format("menuForceReload", initTable[string, string]())

proc menuForceReload*(): string =
  `in`("").menuForceReload()

proc menuToggleDevTools*(msgs: Messages): string =
  msgs.format("menuToggleDevTools", initTable[string, string]())

proc menuToggleDevTools*(): string =
  `in`("").menuToggleDevTools()

proc menuActualSize*(msgs: Messages): string =
  msgs.format("menuActualSize", initTable[string, string]())

proc menuActualSize*(): string =
  `in`("").menuActualSize()

proc menuZoomIn*(msgs: Messages): string =
  msgs.format("menuZoomIn", initTable[string, string]())

proc menuZoomIn*(): string =
  `in`("").menuZoomIn()

proc menuZoomOut*(msgs: Messages): string =
  msgs.format("menuZoomOut", initTable[string, string]())

proc menuZoomOut*(): string =
  `in`("").menuZoomOut()

proc menuToggleFullScreen*(msgs: Messages): string =
  msgs.format("menuToggleFullScreen", initTable[string, string]())

proc menuToggleFullScreen*(): string =
  `in`("").menuToggleFullScreen()

proc menuMinimize*(msgs: Messages): string =
  msgs.format("menuMinimize", initTable[string, string]())

proc menuMinimize*(): string =
  `in`("").menuMinimize()

proc menuZoom*(msgs: Messages): string =
  msgs.format("menuZoom", initTable[string, string]())

proc menuZoom*(): string =
  `in`("").menuZoom()

proc menuBringAllToFront*(msgs: Messages): string =
  msgs.format("menuBringAllToFront", initTable[string, string]())

proc menuBringAllToFront*(): string =
  `in`("").menuBringAllToFront()

proc menuClose*(msgs: Messages): string =
  msgs.format("menuClose", initTable[string, string]())

proc menuClose*(): string =
  `in`("").menuClose()

proc menuCloseWindow*(msgs: Messages): string =
  msgs.format("menuCloseWindow", initTable[string, string]())

proc menuCloseWindow*(): string =
  `in`("").menuCloseWindow()

proc menuNew*(msgs: Messages): string =
  msgs.format("menuNew", initTable[string, string]())

proc menuNew*(): string =
  `in`("").menuNew()

proc menuOpen*(msgs: Messages): string =
  msgs.format("menuOpen", initTable[string, string]())

proc menuOpen*(): string =
  `in`("").menuOpen()

proc menuOpenRecent*(msgs: Messages): string =
  msgs.format("menuOpenRecent", initTable[string, string]())

proc menuOpenRecent*(): string =
  `in`("").menuOpenRecent()

proc menuSave*(msgs: Messages): string =
  msgs.format("menuSave", initTable[string, string]())

proc menuSave*(): string =
  `in`("").menuSave()

proc menuSaveAs*(msgs: Messages): string =
  msgs.format("menuSaveAs", initTable[string, string]())

proc menuSaveAs*(): string =
  `in`("").menuSaveAs()

proc menuDuplicate*(msgs: Messages): string =
  msgs.format("menuDuplicate", initTable[string, string]())

proc menuDuplicate*(): string =
  `in`("").menuDuplicate()

proc menuRename*(msgs: Messages): string =
  msgs.format("menuRename", initTable[string, string]())

proc menuRename*(): string =
  `in`("").menuRename()

proc menuMoveTo*(msgs: Messages): string =
  msgs.format("menuMoveTo", initTable[string, string]())

proc menuMoveTo*(): string =
  `in`("").menuMoveTo()

proc menuRevert*(msgs: Messages): string =
  msgs.format("menuRevert", initTable[string, string]())

proc menuRevert*(): string =
  `in`("").menuRevert()

proc menuRevertToSaved*(msgs: Messages): string =
  msgs.format("menuRevertToSaved", initTable[string, string]())

proc menuRevertToSaved*(): string =
  `in`("").menuRevertToSaved()

proc menuQuitApp*(msgs: Messages; app: string): string =
  msgs.format("menuQuitApp", {"app": app}.toTable)

proc menuQuitApp*(app: string): string =
  `in`("").menuQuitApp(app)

proc menuAbout*(msgs: Messages; app: string): string =
  msgs.format("menuAbout", {"app": app}.toTable)

proc menuAbout*(app: string): string =
  `in`("").menuAbout(app)

proc menuHide*(msgs: Messages; app: string): string =
  msgs.format("menuHide", {"app": app}.toTable)

proc menuHide*(app: string): string =
  `in`("").menuHide(app)

proc menuQuit*(msgs: Messages): string =
  msgs.format("menuQuit", initTable[string, string]())

proc menuQuit*(): string =
  `in`("").menuQuit()

proc menuExit*(msgs: Messages): string =
  msgs.format("menuExit", initTable[string, string]())

proc menuExit*(): string =
  `in`("").menuExit()

proc menuHideOthers*(msgs: Messages): string =
  msgs.format("menuHideOthers", initTable[string, string]())

proc menuHideOthers*(): string =
  `in`("").menuHideOthers()

proc menuShowAll*(msgs: Messages): string =
  msgs.format("menuShowAll", initTable[string, string]())

proc menuShowAll*(): string =
  `in`("").menuShowAll()

proc menuServices*(msgs: Messages): string =
  msgs.format("menuServices", initTable[string, string]())

proc menuServices*(): string =
  `in`("").menuServices()

proc menuStartSpeaking*(msgs: Messages): string =
  msgs.format("menuStartSpeaking", initTable[string, string]())

proc menuStartSpeaking*(): string =
  `in`("").menuStartSpeaking()

proc menuStopSpeaking*(msgs: Messages): string =
  msgs.format("menuStopSpeaking", initTable[string, string]())

proc menuStopSpeaking*(): string =
  `in`("").menuStopSpeaking()

proc menuFile*(msgs: Messages): string =
  msgs.format("menuFile", initTable[string, string]())

proc menuFile*(): string =
  `in`("").menuFile()

proc menuEdit*(msgs: Messages): string =
  msgs.format("menuEdit", initTable[string, string]())

proc menuEdit*(): string =
  `in`("").menuEdit()

proc menuView*(msgs: Messages): string =
  msgs.format("menuView", initTable[string, string]())

proc menuView*(): string =
  `in`("").menuView()

proc menuFormat*(msgs: Messages): string =
  msgs.format("menuFormat", initTable[string, string]())

proc menuFormat*(): string =
  `in`("").menuFormat()

proc menuWindow*(msgs: Messages): string =
  msgs.format("menuWindow", initTable[string, string]())

proc menuWindow*(): string =
  `in`("").menuWindow()

proc menuHelp*(msgs: Messages): string =
  msgs.format("menuHelp", initTable[string, string]())

proc menuHelp*(): string =
  `in`("").menuHelp()

proc menuBold*(msgs: Messages): string =
  msgs.format("menuBold", initTable[string, string]())

proc menuBold*(): string =
  `in`("").menuBold()

proc menuItalic*(msgs: Messages): string =
  msgs.format("menuItalic", initTable[string, string]())

proc menuItalic*(): string =
  `in`("").menuItalic()

proc menuUnderline*(msgs: Messages): string =
  msgs.format("menuUnderline", initTable[string, string]())

proc menuUnderline*(): string =
  `in`("").menuUnderline()

proc menuStrikethrough*(msgs: Messages): string =
  msgs.format("menuStrikethrough", initTable[string, string]())

proc menuStrikethrough*(): string =
  `in`("").menuStrikethrough()

proc menuAlignLeft*(msgs: Messages): string =
  msgs.format("menuAlignLeft", initTable[string, string]())

proc menuAlignLeft*(): string =
  `in`("").menuAlignLeft()

proc menuCenter*(msgs: Messages): string =
  msgs.format("menuCenter", initTable[string, string]())

proc menuCenter*(): string =
  `in`("").menuCenter()

proc menuAlignRight*(msgs: Messages): string =
  msgs.format("menuAlignRight", initTable[string, string]())

proc menuAlignRight*(): string =
  `in`("").menuAlignRight()

proc noMatches*(msgs: Messages): string =
  msgs.format("noMatches", initTable[string, string]())

proc noMatches*(): string =
  `in`("").noMatches()

proc previous*(msgs: Messages): string =
  msgs.format("previous", initTable[string, string]())

proc previous*(): string =
  `in`("").previous()

proc next*(msgs: Messages): string =
  msgs.format("next", initTable[string, string]())

proc next*(): string =
  `in`("").next()

proc done*(msgs: Messages): string =
  msgs.format("done", initTable[string, string]())

proc done*(): string =
  `in`("").done()

proc colorValue*(msgs: Messages; saturation: string, brightness: string): string =
  msgs.format("colorValue", {"saturation": saturation, "brightness": brightness}.toTable)

proc colorValue*(saturation: string, brightness: string): string =
  `in`("").colorValue(saturation, brightness)

proc hours*(msgs: Messages): string =
  msgs.format("hours", initTable[string, string]())

proc hours*(): string =
  `in`("").hours()

proc minutes*(msgs: Messages): string =
  msgs.format("minutes", initTable[string, string]())

proc minutes*(): string =
  `in`("").minutes()

proc dayPeriod*(msgs: Messages): string =
  msgs.format("dayPeriod", initTable[string, string]())

proc dayPeriod*(): string =
  `in`("").dayPeriod()

proc richText*(msgs: Messages): string =
  msgs.format("richText", initTable[string, string]())

proc richText*(): string =
  `in`("").richText()

proc copyCode*(msgs: Messages): string =
  msgs.format("copyCode", initTable[string, string]())

proc copyCode*(): string =
  `in`("").copyCode()

proc copied*(msgs: Messages): string =
  msgs.format("copied", initTable[string, string]())

proc copied*(): string =
  `in`("").copied()

proc copyAsMarkdown*(msgs: Messages): string =
  msgs.format("copyAsMarkdown", initTable[string, string]())

proc copyAsMarkdown*(): string =
  `in`("").copyAsMarkdown()

proc image*(msgs: Messages): string =
  msgs.format("image", initTable[string, string]())

proc image*(): string =
  `in`("").image()

proc menuSpeech*(msgs: Messages): string =
  msgs.format("menuSpeech", initTable[string, string]())

proc menuSpeech*(): string =
  `in`("").menuSpeech()

proc menuClearRecent*(msgs: Messages): string =
  msgs.format("menuClearRecent", initTable[string, string]())

proc menuClearRecent*(): string =
  `in`("").menuClearRecent()

proc untitled*(msgs: Messages): string =
  msgs.format("untitled", initTable[string, string]())

proc untitled*(): string =
  `in`("").untitled()

proc untitledNumbered*(msgs: Messages; n: string): string =
  msgs.format("untitledNumbered", {"n": n}.toTable)

proc untitledNumbered*(n: string): string =
  `in`("").untitledNumbered(n)

proc cancel*(msgs: Messages): string =
  msgs.format("cancel", initTable[string, string]())

proc cancel*(): string =
  `in`("").cancel()

proc save*(msgs: Messages): string =
  msgs.format("save", initTable[string, string]())

proc save*(): string =
  `in`("").save()

proc saveEllipsis*(msgs: Messages): string =
  msgs.format("saveEllipsis", initTable[string, string]())

proc saveEllipsis*(): string =
  `in`("").saveEllipsis()

proc saveAs*(msgs: Messages): string =
  msgs.format("saveAs", initTable[string, string]())

proc saveAs*(): string =
  `in`("").saveAs()

proc saveAnyway*(msgs: Messages): string =
  msgs.format("saveAnyway", initTable[string, string]())

proc saveAnyway*(): string =
  `in`("").saveAnyway()

proc saveAll*(msgs: Messages): string =
  msgs.format("saveAll", initTable[string, string]())

proc saveAll*(): string =
  `in`("").saveAll()

proc dontSave*(msgs: Messages): string =
  msgs.format("dontSave", initTable[string, string]())

proc dontSave*(): string =
  `in`("").dontSave()

proc deleteDocument*(msgs: Messages): string =
  msgs.format("deleteDocument", initTable[string, string]())

proc deleteDocument*(): string =
  `in`("").deleteDocument()

proc revertDocument*(msgs: Messages): string =
  msgs.format("revertDocument", initTable[string, string]())

proc revertDocument*(): string =
  `in`("").revertDocument()

proc replaceFile*(msgs: Messages): string =
  msgs.format("replaceFile", initTable[string, string]())

proc replaceFile*(): string =
  `in`("").replaceFile()

proc rename*(msgs: Messages): string =
  msgs.format("rename", initTable[string, string]())

proc rename*(): string =
  `in`("").rename()

proc renameTo*(msgs: Messages): string =
  msgs.format("renameTo", initTable[string, string]())

proc renameTo*(): string =
  `in`("").renameTo()

proc moveTo*(msgs: Messages): string =
  msgs.format("moveTo", initTable[string, string]())

proc moveTo*(): string =
  `in`("").moveTo()

proc move*(msgs: Messages): string =
  msgs.format("move", initTable[string, string]())

proc move*(): string =
  `in`("").move()

proc reviewChanges*(msgs: Messages): string =
  msgs.format("reviewChanges", initTable[string, string]())

proc reviewChanges*(): string =
  `in`("").reviewChanges()

proc discardChanges*(msgs: Messages): string =
  msgs.format("discardChanges", initTable[string, string]())

proc discardChanges*(): string =
  `in`("").discardChanges()

proc keepNewDocument*(msgs: Messages; name: string): string =
  msgs.format("keepNewDocument", {"name": name}.toTable)

proc keepNewDocument*(name: string): string =
  `in`("").keepNewDocument(name)

proc keepNewDocumentDetail*(msgs: Messages): string =
  msgs.format("keepNewDocumentDetail", initTable[string, string]())

proc keepNewDocumentDetail*(): string =
  `in`("").keepNewDocumentDetail()

proc saveChanges*(msgs: Messages; name: string): string =
  msgs.format("saveChanges", {"name": name}.toTable)

proc saveChanges*(name: string): string =
  `in`("").saveChanges(name)

proc changesLost*(msgs: Messages): string =
  msgs.format("changesLost", initTable[string, string]())

proc changesLost*(): string =
  `in`("").changesLost()

proc readOnly*(msgs: Messages; name: string): string =
  msgs.format("readOnly", {"name": name}.toTable)

proc readOnly*(name: string): string =
  `in`("").readOnly(name)

proc readOnlyDetail*(msgs: Messages): string =
  msgs.format("readOnlyDetail", initTable[string, string]())

proc readOnlyDetail*(): string =
  `in`("").readOnlyDetail()

proc changedOnDisk*(msgs: Messages; name: string): string =
  msgs.format("changedOnDisk", {"name": name}.toTable)

proc changedOnDisk*(name: string): string =
  `in`("").changedOnDisk(name)

proc changedOnDiskDetail*(msgs: Messages): string =
  msgs.format("changedOnDiskDetail", initTable[string, string]())

proc changedOnDiskDetail*(): string =
  `in`("").changedOnDiskDetail()

proc alreadyExists*(msgs: Messages; name: string): string =
  msgs.format("alreadyExists", {"name": name}.toTable)

proc alreadyExists*(name: string): string =
  `in`("").alreadyExists(name)

proc alreadyExistsDetail*(msgs: Messages): string =
  msgs.format("alreadyExistsDetail", initTable[string, string]())

proc alreadyExistsDetail*(): string =
  `in`("").alreadyExistsDetail()

proc revertQuestion*(msgs: Messages; name: string): string =
  msgs.format("revertQuestion", {"name": name}.toTable)

proc revertQuestion*(name: string): string =
  `in`("").revertQuestion(name)

proc revertDetail*(msgs: Messages): string =
  msgs.format("revertDetail", initTable[string, string]())

proc revertDetail*(): string =
  `in`("").revertDetail()

proc reviewBeforeQuitting*(msgs: Messages; n: string, app: string): string =
  msgs.format("reviewBeforeQuitting", {"n": n, "app": app}.toTable)

proc reviewBeforeQuitting*(n: string, app: string): string =
  `in`("").reviewBeforeQuitting(n, app)

proc reviewBeforeQuittingDetail*(msgs: Messages): string =
  msgs.format("reviewBeforeQuittingDetail", initTable[string, string]())

proc reviewBeforeQuittingDetail*(): string =
  `in`("").reviewBeforeQuittingDetail()

proc saveManyChanges*(msgs: Messages; n: string): string =
  msgs.format("saveManyChanges", {"n": n}.toTable)

proc saveManyChanges*(n: string): string =
  `in`("").saveManyChanges(n)

proc documentFailed*(msgs: Messages; action: string, name: string): string =
  msgs.format("documentFailed", {"action": action, "name": name}.toTable)

proc documentFailed*(action: string, name: string): string =
  `in`("").documentFailed(action, name)

proc colorName*(msgs: Messages; color: string): string =
  msgs.format("colorName", {"color": color}.toTable)

proc colorName*(color: string): string =
  `in`("").colorName(color)

proc ok*(msgs: Messages): string =
  msgs.format("ok", initTable[string, string]())

proc ok*(): string =
  `in`("").ok()

proc open*(msgs: Messages): string =
  msgs.format("open", initTable[string, string]())

proc open*(): string =
  `in`("").open()

proc selectFolder*(msgs: Messages): string =
  msgs.format("selectFolder", initTable[string, string]())

proc selectFolder*(): string =
  `in`("").selectFolder()

proc clearScrollback*(msgs: Messages): string =
  msgs.format("clearScrollback", initTable[string, string]())

proc clearScrollback*(): string =
  `in`("").clearScrollback()
