## Runtime loader for Ghostty's libghostty-vt C API.
##
## The library reports its ABI as JSON. Validate the layouts used by this
## binding before exposing the packed-cell offsets or calling into Ghostty.

import std/[dynlib, json, strformat, tables]

type
  GhosttyCellField* = object
    lsb*, width*: int

  GhosttyCellLayout* = object
    contentTag*, styleId*, wide*, hyperlink*: GhosttyCellField
    codepoint*, paletteIndex*, red*, green*, blue*: GhosttyCellField

  GhosttyManifest* = object
    pointerSize*: int
    cell*: GhosttyCellLayout

  GhosttyVT* = ref object
    handle: LibHandle
    symbols: Table[string, pointer]
    manifest*: GhosttyManifest

  TypeJsonProc = proc(): cstring {.cdecl.}

  GhosttyString = object
    data: pointer
    len: csize_t

const TypeJsonSymbol = "ghostty_type_json"

proc intField(node: JsonNode; key, context: string): int =
  if node.kind != JObject or not node.hasKey(key) or
      node[key].kind != JInt:
    raise newException(ValueError, context & " has no integer " & key)
  node[key].getInt()

proc typeNode(types: JsonNode; name: string): JsonNode =
  if types.kind != JObject or not types.hasKey(name) or
      types[name].kind != JObject:
    raise newException(ValueError, "Ghostty manifest has no type " & name)
  types[name]

proc requireLayout(types: JsonNode; name: string; size: int;
                   fields: openArray[(string, int)]) =
  let node = typeNode(types, name)
  let actualSize = intField(node, "size", name)
  if actualSize != size:
    raise newException(ValueError,
      &"Ghostty {name} is {actualSize} bytes, expected {size}")
  if not node.hasKey("fields") or node["fields"].kind != JObject:
    raise newException(ValueError, "Ghostty " & name & " has no fields")
  for (field, offset) in fields:
    if not node["fields"].hasKey(field):
      raise newException(ValueError,
        "Ghostty " & name & " has no field " & field)
    let actualOffset = intField(node["fields"][field], "offset",
      name & "." & field)
    if actualOffset != offset:
      raise newException(ValueError,
        &"Ghostty {name}.{field} is at {actualOffset}, expected {offset}")

proc requireEnumValue(types: JsonNode; typeName, field: string;
                      expected: int) =
  let node = typeNode(types, typeName)
  if not node.hasKey("kind") or node["kind"].kind != JString or
      node["kind"].getStr() != "enum" or not node.hasKey("values") or
      node["values"].kind != JObject or not node["values"].hasKey(field) or
      node["values"][field].kind != JInt:
    raise newException(ValueError,
      "Ghostty " & typeName & " has no enum value " & field)
  let actual = node["values"][field].getInt()
  if actual != expected:
    raise newException(ValueError,
      &"Ghostty {typeName}.{field} is {actual}, expected {expected}")

proc bitField(node: JsonNode; name, context: string): GhosttyCellField =
  if node.kind != JObject or not node.hasKey(name):
    raise newException(ValueError, context & " has no bit field " & name)
  let field = node[name]
  result.lsb = intField(field, "lsb", context & "." & name)
  result.width = intField(field, "width", context & "." & name)
  if result.lsb < 0 or result.width <= 0 or result.width > 64 or
      result.lsb + result.width > 64:
    raise newException(ValueError,
      &"Ghostty {context}.{name} has invalid bit range")

proc requireWidth(field: GhosttyCellField; width: int; name: string) =
  if field.width != width:
    raise newException(ValueError,
      "GhosttyCell " & name & " is " & $field.width & " bits, expected " &
      $width)

proc armBit(content: JsonNode; arm, field: string): GhosttyCellField =
  if content.kind != JObject or not content.hasKey("content") or
      content["content"].kind != JObject or
      not content["content"].hasKey("arms") or
      content["content"]["arms"].kind != JObject or
      not content["content"]["arms"].hasKey(arm):
    raise newException(ValueError, "GhosttyCell content has no arm " & arm)
  let armNode = content["content"]["arms"][arm]
  if armNode.kind != JObject or not armNode.hasKey("bits"):
    raise newException(ValueError, "GhosttyCell arm " & arm & " has no bits")
  let parent = bitField(content, "content", "GhosttyCell")
  let child = bitField(armNode["bits"], field, "GhosttyCell." & arm)
  if child.lsb + child.width > parent.width:
    raise newException(ValueError,
      "GhosttyCell." & arm & "." & field & " exceeds its content arm")
  result = GhosttyCellField(lsb: parent.lsb + child.lsb, width: child.width)
  if result.lsb + result.width > 64:
    raise newException(ValueError,
      "GhosttyCell." & arm & "." & field & " exceeds the packed cell")

proc parseManifest*(data: string): GhosttyManifest =
  ## Parses and checks the ABI layouts passed across this binding.
  var root: JsonNode
  try:
    root = parseJson(data)
  except JsonParsingError as error:
    raise newException(ValueError, "Ghostty type manifest: " & error.msg)
  if root.kind != JObject or not root.hasKey("abi"):
    raise newException(ValueError, "Ghostty type manifest has no ABI section")
  result.pointerSize = intField(root["abi"], "pointer_size", "ABI")
  if result.pointerSize != sizeof(pointer):
    raise newException(ValueError,
      &"Ghostty manifest uses {result.pointerSize}-byte pointers; " &
      &"this build uses {sizeof(pointer)}-byte pointers")

  if not root.hasKey("types"):
    raise newException(ValueError, "Ghostty type manifest has no types")
  let types = root["types"]
  requireLayout(types, "GhosttyString", sizeof(GhosttyString), [
    ("ptr", offsetOf(GhosttyString, data)),
    ("len", offsetOf(GhosttyString, len))])

  requireLayout(types, "GhosttyColorRgb", 3, [
    ("r", 0), ("g", 1), ("b", 2)])
  requireLayout(types, "GhosttyStyleColor", 16, [
    ("tag", 0), ("value", 8)])
  requireLayout(types, "GhosttyStyle", 72, [
    ("size", 0), ("fg_color", 8), ("bg_color", 24),
    ("underline_color", 40), ("bold", 56), ("italic", 57),
    ("faint", 58), ("blink", 59), ("inverse", 60),
    ("invisible", 61), ("strikethrough", 62), ("overline", 63),
    ("underline", 64)])
  requireLayout(types, "GhosttyStyleColor", 16, [
    ("tag", 0), ("value", 8)])
  requireLayout(types, "GhosttyStyle", 72, [
    ("size", 0), ("fg_color", 8), ("bg_color", 24),
    ("underline_color", 40), ("bold", 56), ("italic", 57),
    ("faint", 58), ("blink", 59), ("inverse", 60),
    ("invisible", 61), ("strikethrough", 62), ("overline", 63),
    ("underline", 64)])
  requireLayout(types, "GhosttyRenderStateCursor", 24, [
    ("size", 0), ("viewport_has_value", 8), ("viewport_x", 10),
    ("viewport_y", 12), ("wide_tail", 14), ("visible", 15),
    ("blinking", 16), ("password_input", 17), ("visual_style", 20)])
  requireLayout(types, "GhosttyRenderStateColors", 792, [
    ("size", 0), ("background", 8), ("foreground", 11), ("cursor", 14),
    ("cursor_has_value", 17), ("palette", 18)])
  requireLayout(types, "GhosttyRenderStateRowSelection", 16, [
    ("size", 0), ("start_x", 8), ("end_x", 10)])
  requireLayout(types, "GhosttyRenderStateRowId", 16, [("bits", 0)])
  requireLayout(types, "GhosttyCellsView", 16, [
    ("ptr", 0), ("len", 8)])

  let cell = typeNode(types, "GhosttyCell")
  if not cell.hasKey("kind") or cell["kind"].kind != JString or
      cell["kind"].getStr() != "packed" or
      intField(cell, "size", "GhosttyCell") != sizeof(uint64):
    raise newException(ValueError,
      "GhosttyCell is not a packed 64-bit value")
  if not cell.hasKey("bits") or cell["bits"].kind != JObject:
    raise newException(ValueError, "GhosttyCell has no bit layout")
  let bits = cell["bits"]
  result.cell.contentTag = bitField(bits, "content_tag", "GhosttyCell")
  result.cell.styleId = bitField(bits, "style_id", "GhosttyCell")
  result.cell.wide = bitField(bits, "wide", "GhosttyCell")
  result.cell.hyperlink = bitField(bits, "hyperlink", "GhosttyCell")
  result.cell.codepoint = armBit(bits, "CODEPOINT", "codepoint")
  result.cell.paletteIndex = armBit(bits, "BG_COLOR_PALETTE", "index")
  result.cell.red = armBit(bits, "BG_COLOR_RGB", "r")
  result.cell.green = armBit(bits, "BG_COLOR_RGB", "g")
  result.cell.blue = armBit(bits, "BG_COLOR_RGB", "b")
  requireWidth(result.cell.contentTag, 2, "content tag")
  requireWidth(result.cell.styleId, 16, "style id")
  requireWidth(result.cell.wide, 2, "wide marker")
  requireWidth(result.cell.hyperlink, 1, "hyperlink marker")
  requireWidth(result.cell.codepoint, 21, "codepoint")
  requireWidth(result.cell.paletteIndex, 8, "palette index")
  requireWidth(result.cell.red, 8, "red channel")
  requireWidth(result.cell.green, 8, "green channel")
  requireWidth(result.cell.blue, 8, "blue channel")
  requireEnumValue(types, "GhosttyCellContentTag", "CODEPOINT", 0)
  requireEnumValue(types, "GhosttyCellContentTag", "CODEPOINT_GRAPHEME", 1)
  requireEnumValue(types, "GhosttyCellContentTag", "BG_COLOR_PALETTE", 2)
  requireEnumValue(types, "GhosttyCellContentTag", "BG_COLOR_RGB", 3)
  requireEnumValue(types, "GhosttyCellWide", "NARROW", 0)
  requireEnumValue(types, "GhosttyCellWide", "WIDE", 1)
  requireEnumValue(types, "GhosttyCellWide", "SPACER_TAIL", 2)
  requireEnumValue(types, "GhosttyCellWide", "SPACER_HEAD", 3)
  requireEnumValue(types, "GhosttyStyleColorTag", "NONE", 0)
  requireEnumValue(types, "GhosttyStyleColorTag", "PALETTE", 1)
  requireEnumValue(types, "GhosttyStyleColorTag", "RGB", 2)

proc openGhosttyVT*(path: string): GhosttyVT =
  ## Loads the shared library and verifies its reported ABI before use.
  if path.len == 0:
    raise newException(ValueError, "libghostty-vt path is empty")
  let handle = loadLib(path)
  if handle.isNil:
    raise newException(IOError, "cannot load libghostty-vt at " & path)

  var symbols = initTable[string, pointer]()
  let symbol = handle.symAddr(TypeJsonSymbol)
  if symbol.isNil:
    unloadLib(handle)
    raise newException(IOError,
      path & " is missing required symbol " & TypeJsonSymbol)
  let getManifest = cast[TypeJsonProc](symbol)
  let manifestData = getManifest()
  if manifestData.isNil:
    unloadLib(handle)
    raise newException(IOError,
      path & " returned no Ghostty type manifest")

  var manifest: GhosttyManifest
  try:
    manifest = parseManifest($manifestData)
  except CatchableError as error:
    unloadLib(handle)
    raise newException(ValueError,
      path & " is incompatible with this VT binding: " & error.msg)

  symbols[TypeJsonSymbol] = symbol
  new(result)
  result.handle = handle
  result.symbols = move(symbols)
  result.manifest = manifest

proc symbol*(library: GhosttyVT; name: string): pointer =
  ## Resolves a function address or returns nil when the symbol is absent.
  if library.isNil or library.handle.isNil:
    return nil
  result = library.symbols.getOrDefault(name)
  if result.isNil:
    result = library.handle.symAddr(name)

proc close*(library: GhosttyVT) =
  ## Releases the dynamic library. Call only after all Ghostty objects are freed.
  if not library.isNil and not library.handle.isNil:
    unloadLib(library.handle)
    library.handle = nil
    library.symbols.clear()
