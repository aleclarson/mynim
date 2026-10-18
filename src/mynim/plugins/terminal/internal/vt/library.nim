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
  ## Parses and checks the subset of the ABI this binding currently uses.
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
