## Check the ARB-style message catalogs configured by a nim-xplat project.

import std/[algorithm, json, os, parsejson, sequtils, streams, strutils,
  tables]
import ../mynim/i18n as localeI18n
import ../mynim/i18n/message as messageFormat

type
  Argument = object
    name, kind: string

  ParsedMessage = object
    args: seq[Argument]
    tree: messageFormat.Message

  Message = object
    parsed: ParsedMessage
    valid: bool

  Catalog = object
    path, tag: string
    order: seq[string]
    messages: Table[string, Message]
    lines: Table[string, int]
    metadata: Table[string, JsonNode]
    paramTypes: Table[string, Table[string, string]]

  Diagnostic = object
    path, message: string
    warning: bool

const usageI18n = """Usage: nim-xplat i18n check [dir]

Check the catalogs configured by i18n in mygo.json.
Errors exit with status 1; missing translations are warnings.
"""

const frameworkCatalogSource = staticRead("../mynim/internal/l10n/en.json")

proc parseMessage(source: string): ParsedMessage =
  result.tree = messageFormat.parseMessage(source)
  for arg in result.tree.args:
    result.args.add Argument(name: arg.name, kind: arg.kind)

proc topLevelKeys(source: string): seq[tuple[key: string, line: int]] =
  var parser: JsonParser
  parser.open(newStringStream(source), "catalog.json")
  defer: parser.close()
  parser.next()
  if parser.kind != jsonObjectStart:
    return
  var depth = 1
  var expectingKey = true
  parser.next()
  while parser.kind notin {jsonEof, jsonError}:
    if depth == 1 and expectingKey:
      if parser.kind == jsonObjectEnd:
        break
      if parser.kind == jsonString:
        result.add (parser.str, parser.getLine())
        expectingKey = false
    elif depth == 1:
      if parser.kind in {jsonArrayStart, jsonObjectStart}:
        depth = 2
      else:
        expectingKey = true
    elif parser.kind in {jsonArrayStart, jsonObjectStart}:
      inc depth
    elif parser.kind in {jsonArrayEnd, jsonObjectEnd}:
      dec depth
      if depth == 1:
        expectingKey = true
    parser.next()

proc location(catalog: Catalog; key: string): string =
  if catalog.lines.hasKey(key):
    catalog.path & ":" & $catalog.lines[key]
  else:
    catalog.path

proc addDiagnostic(diagnostics: var seq[Diagnostic]; path, message: string;
    warning = false) =
  diagnostics.add Diagnostic(path: path, message: message, warning: warning)

proc printDiagnostics(diagnostics: seq[Diagnostic]): int =
  for diagnostic in diagnostics:
    let level = if diagnostic.warning: "warning: " else: ""
    stderr.writeLine(diagnostic.path & ": " & level & diagnostic.message)
    if not diagnostic.warning:
      inc result

proc loadCatalogText(source, path, tag: string;
    diagnostics: var seq[Diagnostic]): Catalog =
  result = Catalog(path: path, tag: tag,
    messages: initTable[string, Message](),
    lines: initTable[string, int](),
    metadata: initTable[string, JsonNode](),
    paramTypes: initTable[string, Table[string, string]]())
  var data: JsonNode
  try:
    data = parseJson(source)
  except JsonParsingError as error:
    diagnostics.addDiagnostic(path, error.msg)
    return
  if data.kind != JObject:
    diagnostics.addDiagnostic(path, "not a JSON object of messages")
    return

  for item in topLevelKeys(source):
    if result.lines.hasKey(item.key):
      diagnostics.addDiagnostic(path & ":" & $item.line,
        "key " & item.key & " comes twice")
    else:
      result.lines[item.key] = item.line

  for key, value in data.pairs:
    if key == "@@locale":
      if value.kind != JString or localeI18n.normalize(value.getStr()) != tag:
        diagnostics.addDiagnostic(result.location(key),
          "@@locale does not match " & tag & ".json")
    elif key.startsWith("@@"):
      discard
    elif key.startsWith("@"):
      let metaName = if key.len > 1: key[1 .. ^1] else: ""
      result.metadata[metaName] = value
    elif value.kind != JString:
      diagnostics.addDiagnostic(result.location(key),
        "message " & key & " is not a string")
    else:
      result.order.add key
      result.messages[key] = Message()
      try:
        result.messages[key] = Message(parsed: parseMessage(value.getStr()),
          valid: true)
      except ValueError as error:
        diagnostics.addDiagnostic(result.location(key),
          "message " & key & " does not parse: " & error.msg)

proc loadCatalog(path, tag: string; diagnostics: var seq[Diagnostic]): Catalog =
  loadCatalogText(readFile(path), path, tag, diagnostics)

proc validMessageKey(key: string): bool =
  if key.len == 0 or key[0] notin {'A'..'Z', 'a'..'z'}:
    return false
  for ch in key:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '_'}:
      return false
  true

proc libraryKey(key: string): tuple[namespace, name: string] =
  let separator = key.find('.')
  if separator > 0 and validMessageKey(key[0 ..< separator]):
    result.namespace = key[0 ..< separator]
    result.name = if separator + 1 < key.len:
      key[separator + 1 .. ^1] else: ""

proc accessorName(key: string): string =
  for word in key.split('_'):
    if word.len > 0:
      result.add word[0].toUpperAscii()
      if word.len > 1:
        result.add word[1 .. ^1]

proc checkSourceKeys(source: Catalog; diagnostics: var seq[Diagnostic]) =
  var taken = initTable[string, string]()
  for reserved in ["In", "Messages", "Catalog"]:
    taken[reserved] = ""
  for key in source.order:
    if libraryKey(key).namespace.len > 0:
      continue
    if not validMessageKey(key):
      diagnostics.addDiagnostic(source.location(key),
        "message key " & key & " is not a valid catalog key")
      continue
    let generatedName = accessorName(key)
    if taken.hasKey(generatedName):
      let previous = taken[generatedName]
      if previous.len == 0:
        diagnostics.addDiagnostic(source.location(key),
          "message key " & key & " would generate reserved accessor " &
          generatedName)
      else:
        diagnostics.addDiagnostic(source.location(key),
          "message keys " & previous & " and " & key &
          " would both generate accessor " & generatedName)
    else:
      taken[generatedName] = key

proc inferredType(kind: string): string =
  case kind
  of "plural", "selectordinal", "number": "int"
  of "date", "time": "DateTime"
  else: "String"

proc compatibleType(sourceType, translatedKind: string): bool =
  case translatedKind
  of "plural", "selectordinal", "number":
    sourceType in ["int", "double", "num", "Object"]
  of "date", "time": sourceType in ["DateTime", "Object"]
  of "select": sourceType in ["String", "Object"]
  else: true

proc pluralWord(count: int; one, other: string): string =
  if count == 1: one else: other

proc pluralNames(categories: openArray[localeI18n.Plural]): string =
  var names: seq[string]
  for category in categories:
    names.add localeI18n.pluralName(category)
  names.join(", ")

proc checkPlurals(catalog: Catalog; key: string; message: ParsedMessage;
    diagnostics: var seq[Diagnostic]) =
  for arg in message.args:
    if arg.kind notin ["plural", "selectordinal"]:
      continue
    let ordinal = arg.kind == "selectordinal"
    let kind = if ordinal: "ordinal" else: "plural"
    let available = if ordinal:
      localeI18n.ordinalCategories(catalog.tag)
    else:
      localeI18n.pluralCategories(catalog.tag)
    let cases = message.tree.cases(arg.name)
    var extra, lacking: seq[string]
    for caseName in cases:
      let category = localeI18n.parsePlural(caseName)
      if category.ok and category.value notin available:
        extra.add caseName
    for category in available:
      let name = localeI18n.pluralName(category)
      if name notin cases:
        lacking.add name
    if extra.len > 0:
      diagnostics.addDiagnostic(catalog.location(key),
        "message " & key & ": " & catalog.tag & " has no " & kind & " " &
        pluralWord(extra.len, "category", "categories") & " of " &
        extra.join(", ") & " (its " & kind & " categories are " &
        pluralNames(available) & ")", warning = true)
    if lacking.len > 0:
      diagnostics.addDiagnostic(catalog.location(key),
        "message " & key & ": the " & arg.kind & " argument " & arg.name &
        " lacks " & lacking.join(", ") & ", a " & kind &
        " category of " & catalog.tag & ", which says other in its place",
        warning = true)

proc checkSourceMetadata(source: var Catalog;
    diagnostics: var seq[Diagnostic]) =
  var metadataNames = toSeq(source.metadata.keys)
  metadataNames.sort()
  for name in metadataNames:
    if not source.messages.hasKey(name):
      diagnostics.addDiagnostic(source.location("@" & name),
        "@" & name & " describes no message", warning = true)

  for key in source.order:
    if libraryKey(key).namespace.len > 0:
      continue
    var declared = initTable[string, string]()
    let metadataKey = "@" & key
    if source.metadata.hasKey(key):
      let metadata = source.metadata[key]
      if metadata.kind notin [JObject, JNull]:
        diagnostics.addDiagnostic(source.location(metadataKey),
          metadataKey & " must be an object")
      elif metadata.kind == JObject:
        if metadata.hasKey("description") and
            metadata["description"].kind != JString:
          diagnostics.addDiagnostic(source.location(metadataKey),
            metadataKey & ".description must be a string")
        if metadata.hasKey("placeholders"):
          let placeholders = metadata["placeholders"]
          if placeholders.kind notin [JObject, JNull]:
            diagnostics.addDiagnostic(source.location(metadataKey),
              metadataKey & ".placeholders must be an object")
          elif placeholders.kind == JObject:
            for name, placeholder in placeholders.pairs:
              if placeholder.kind != JObject:
                diagnostics.addDiagnostic(source.location(metadataKey),
                  metadataKey & ".placeholders." & name & " must be an object")
                continue
              var typ = ""
              if placeholder.hasKey("type"):
                if placeholder["type"].kind != JString:
                  diagnostics.addDiagnostic(source.location(metadataKey),
                    metadataKey & ".placeholders." & name &
                    ".type must be a string")
                else:
                  typ = placeholder["type"].getStr()
                  if typ notin ["String", "int", "double", "num", "DateTime", "Object"]:
                    diagnostics.addDiagnostic(source.location(metadataKey),
                      metadataKey & ".placeholders." & name &
                      ".type must be String, int, double, num, DateTime or Object")
                    typ = ""
              declared[name] = typ

    var declaredNames = toSeq(declared.keys)
    declaredNames.sort()
    var paramTypes = initTable[string, string]()
    let message = source.messages[key]
    for name in declaredNames:
      let typ = declared[name]
      var used = false
      var kind = ""
      if message.valid:
        for arg in message.parsed.args:
          if arg.name == name:
            used = true
            kind = arg.kind
            break
      if message.valid and not used:
        diagnostics.addDiagnostic(source.location(metadataKey),
          metadataKey & " declares unused placeholder " & name,
          warning = true)
      if used and typ.len > 0 and not compatibleType(typ, kind):
        diagnostics.addDiagnostic(source.location(key),
          "message " & key & " uses " & name & " as an incompatible argument type")
      paramTypes[name] = if typ.len > 0: typ
        elif used: inferredType(kind) else: "String"
    if message.valid:
      for arg in message.parsed.args:
        if not paramTypes.hasKey(arg.name):
          paramTypes[arg.name] = inferredType(arg.kind)
    source.paramTypes[key] = paramTypes
    if message.valid:
      checkPlurals(source, key, message.parsed, diagnostics)

proc checkOverride(framework, catalog: Catalog; key: string;
    diagnostics: var seq[Diagnostic]) =
  let library = libraryKey(key)
  if library.namespace != "mygo":
    diagnostics.addDiagnostic(catalog.location(key),
      "message " & key & ": no library has the namespace " &
      library.namespace)
    return

  var sourceArgs: seq[Argument]
  var paramTypes = initTable[string, string]()
  if library.name notin ["appName", "appDescription"]:
    if not framework.messages.hasKey(library.name):
      diagnostics.addDiagnostic(catalog.location(key),
        "message " & key & ": mygo has no message " & library.name)
      return
    let source = framework.messages[library.name]
    if not source.valid:
      return
    sourceArgs = source.parsed.args
    paramTypes = framework.paramTypes.getOrDefault(library.name,
      initTable[string, string]())

  if not catalog.messages[key].valid:
    return
  let translated = catalog.messages[key].parsed
  for arg in translated.args:
    var found = false
    for sourceArg in sourceArgs:
      if sourceArg.name == arg.name:
        found = true
        let paramType = paramTypes.getOrDefault(arg.name,
          inferredType(sourceArg.kind))
        if not compatibleType(paramType, arg.kind):
          diagnostics.addDiagnostic(catalog.location(key),
            "message " & key & " uses " & arg.name &
            " as an incompatible argument")
        break
    if not found:
      diagnostics.addDiagnostic(catalog.location(key),
        "message " & key & " uses argument " & arg.name &
        ", which the MyGo message does not have")
  for sourceArg in sourceArgs:
    var found = false
    for arg in translated.args:
      if sourceArg.name == arg.name:
        found = true
        break
    if not found:
      diagnostics.addDiagnostic(catalog.location(key),
        "message " & key & " does not use argument " & sourceArg.name,
        warning = true)
  checkPlurals(catalog, key, translated, diagnostics)

proc checkTranslation(source, translation, framework: Catalog;
    diagnostics: var seq[Diagnostic]) =
  for key in translation.order:
    if libraryKey(key).namespace.len > 0:
      checkOverride(framework, translation, key, diagnostics)
      continue
    if key.contains('.'):
      diagnostics.addDiagnostic(translation.location(key),
        "message " & key & " has no library namespace")
      continue
    if not source.messages.hasKey(key):
      diagnostics.addDiagnostic(translation.location(key),
        "message " & key & " is not in " & source.path)
      continue
    if not translation.messages.hasKey(key) or
        not translation.messages[key].valid or
        not source.messages[key].valid:
      continue
    let translated = translation.messages[key].parsed
    let original = source.messages[key].parsed
    for arg in translated.args:
      var found = false
      for sourceArg in original.args:
        if sourceArg.name == arg.name:
          found = true
          let paramType = source.paramTypes[key].getOrDefault(arg.name,
            inferredType(sourceArg.kind))
          if not compatibleType(paramType, arg.kind):
            diagnostics.addDiagnostic(translation.location(key),
              "message " & key & " uses " & arg.name & " as an incompatible argument")
          break
      if not found:
        diagnostics.addDiagnostic(translation.location(key),
          "message " & key & " uses argument " & arg.name &
          ", which the source message does not have")
    for sourceArg in original.args:
      var found = false
      for arg in translated.args:
        if sourceArg.name == arg.name:
          found = true
          break
      if not found:
        diagnostics.addDiagnostic(translation.location(key),
          "message " & key & " does not use argument " & sourceArg.name,
          warning = true)
    checkPlurals(translation, key, translated, diagnostics)

  var missing: seq[string]
  for key in source.order:
    if libraryKey(key).namespace.len > 0:
      continue
    if not translation.messages.hasKey(key):
      missing.add key
  if missing.len > 0:
    var shown = missing
    if shown.len > 8:
      shown = shown[0 ..< 8]
      shown.add "and " & $(missing.len - 8) & " more"
    diagnostics.addDiagnostic(translation.path,
      $missing.len & " of " & $source.order.len &
      " messages missing: " & shown.join(", "), warning = true)

proc readConfigString(config: JsonNode; key, fallback: string): string =
  if not config.hasKey(key):
    return fallback
  if config[key].kind != JString:
    raise newException(ValueError, "mygo.json: " & key & " must be a string")
  config[key].getStr()

proc isMygoPseudoLocale(tag: string): bool =
  let normalized = localeI18n.normalize(tag)
  normalized in ["en-XA", "ar-XB"]

proc insideProject(path: string): bool =
  if isAbsolute(path):
    return false
  var depth = 0
  for part in path.split({'/', '\\'}):
    if part == "" or part == ".":
      continue
    if part == "..":
      dec depth
      if depth < 0:
        return false
    else:
      inc depth
  depth > 0

proc checkProject(projectDir: string): int =
  var diagnostics: seq[Diagnostic]
  let configPath = projectDir / "mygo.json"
  if not fileExists(configPath):
    stderr.writeLine("nim-xplat i18n: expected mygo.json in " & projectDir)
    return 1

  var config: JsonNode
  try:
    config = parseFile(configPath)
  except JsonParsingError as error:
    stderr.writeLine("nim-xplat i18n: " & error.msg)
    return 1
  if config.kind != JObject:
    stderr.writeLine("nim-xplat i18n: mygo.json must contain a JSON object")
    return 1
  if not config.hasKey("i18n") or config["i18n"].kind == JNull:
    stderr.writeLine("nim-xplat i18n: the project has no catalogs; set i18n in mygo.json")
    return 1
  if config["i18n"].kind != JObject:
    stderr.writeLine("nim-xplat i18n: mygo.json: i18n must be an object")
    return 1

  try:
    let options = config["i18n"]
    let configuredSource = readConfigString(options, "source", "en")
    let sourceTag = if configuredSource.len == 0: "en" else: configuredSource
    if localeI18n.normalize(sourceTag) != sourceTag or
        isMygoPseudoLocale(sourceTag):
      raise newException(ValueError,
        "i18n.source " & sourceTag & " is not a canonical BCP 47 tag")
    let configuredDir = readConfigString(options, "dir", "locales")
    let relativeDir = if configuredDir.len == 0: "locales" else: configuredDir
    if not insideProject(relativeDir):
      raise newException(ValueError,
        "i18n.dir must be a directory inside the project")
    let catalogDir = projectDir / relativeDir
    if not dirExists(catalogDir):
      raise newException(ValueError,
        "i18n.dir " & relativeDir & " is not a directory")

    var files: Table[string, string]
    var catalogPaths: seq[string]
    for kind, path in walkDir(catalogDir):
      if kind == pcFile and path.endsWith(".json") and
          not path.lastPathPart().startsWith("."):
        catalogPaths.add path
    catalogPaths.sort()
    for path in catalogPaths:
      let name = path.lastPathPart()
      let tag = name[0 ..< name.len - 5]
      let normalized = localeI18n.normalize(tag)
      if normalized != tag or isMygoPseudoLocale(tag):
        diagnostics.addDiagnostic(path,
          "catalog filename must be a canonical BCP 47 language tag")
      elif files.hasKey(tag):
        diagnostics.addDiagnostic(path, "duplicate catalog for " & tag)
      else:
        files[tag] = path
    if not files.hasKey(sourceTag):
      diagnostics.addDiagnostic(catalogDir / (sourceTag & ".json"),
        "missing source language catalog " & sourceTag)
      discard printDiagnostics(diagnostics)
      return 1

    var tags = toSeq(files.keys)
    tags.sort()
    var orderedTags = @[sourceTag]
    for tag in tags:
      if tag != sourceTag:
        orderedTags.add tag
    tags = orderedTags
    var catalogs: seq[Catalog]
    for tag in tags:
      catalogs.add loadCatalog(files[tag], tag, diagnostics)

    var source = catalogs[0]
    var frameworkDiagnostics: seq[Diagnostic]
    var framework = loadCatalogText(frameworkCatalogSource,
      "MyGo's English catalog", "en", frameworkDiagnostics)
    checkSourceMetadata(framework, frameworkDiagnostics)
    for diagnostic in frameworkDiagnostics:
      if not diagnostic.warning:
        diagnostics.addDiagnostic(diagnostic.path,
          "MyGo's embedded catalog: " & diagnostic.message)

    checkSourceKeys(source, diagnostics)
    checkSourceMetadata(source, diagnostics)
    for key in source.order:
      if libraryKey(key).namespace.len > 0:
        checkOverride(framework, source, key, diagnostics)
    for i in 1 ..< catalogs.len:
      checkTranslation(source, catalogs[i], framework, diagnostics)

    let errors = printDiagnostics(diagnostics)
    if errors > 0:
      stderr.writeLine("nim-xplat i18n: " & $errors & " error" &
        (if errors == 1: "" else: "s") & " in the catalogs")
      return 1
    stdout.writeLine($source.order.len & " messages in " & tags.join(", "))
    return 0
  except CatchableError as error:
    stderr.writeLine("nim-xplat i18n: " & error.msg)
    return 1

proc runI18n*(args: seq[string]): int =
  if args.len == 0:
    stderr.write(usageI18n)
    stderr.writeLine("nim-xplat i18n: unknown subcommand; want check")
    return 1
  if args[0] in ["-h", "--help", "help"]:
    stdout.write(usageI18n)
    return 0
  if args[0] != "check":
    stderr.writeLine("nim-xplat i18n: unknown subcommand; want check")
    stderr.write(usageI18n)
    return 2
  var paths: seq[string]
  var i = 1
  while i < args.len:
    if args[i] == "--":
      for rest in i + 1 ..< args.len:
        paths.add args[rest]
      break
    if args[i] in ["-h", "--help"]:
      stdout.write(usageI18n)
      return 0
    if args[i].startsWith("-"):
      stderr.writeLine("nim-xplat i18n check: unknown flag " & args[i])
      stderr.write(usageI18n)
      return 2
    paths.add args[i]
    inc i
  if paths.len > 1:
    stderr.writeLine("nim-xplat i18n check: expected at most one project directory")
    stderr.write(usageI18n)
    return 2
  let projectDir = if paths.len == 0: getCurrentDir()
    else: absolutePath(paths[0])
  if not dirExists(projectDir):
    stderr.writeLine("nim-xplat i18n: " & projectDir & " is not a directory")
    return 1
  checkProject(projectDir)
