## Source-level shader declarations shared by the shader compiler frontend.

type
  ShaderEntryKind* = enum
    sekFragment
    sekColorEffect
    sekDistortionEffect
    sekLayerEffect

  ShaderSourceInfo* = object
    ## The shader entry point found in the source.
    kind*: ShaderEntryKind
    ## False when the source declares no supported entry point.
    found*: bool
    ## A source-level validation error, if one was found.
    error*: string

  LexToken = object
    text: string
    identifier: bool

proc isIdentifierStart(c: char): bool {.inline.} =
  c == '_' or c in {'a'..'z', 'A'..'Z'} or ord(c) >= 0x80

proc isIdentifierPart(c: char): bool {.inline.} =
  isIdentifierStart(c) or c in {'0'..'9'}

proc tokenize(source: string): seq[LexToken] =
  ## Tokenize enough of Go source to recognize top-level function declarations
  ## and built-in image references. String, rune, and comment contents vanish.
  var i = 0
  while i < source.len:
    let c = source[i]
    if c in {' ', '\t', '\r', '\n', '\f'}:
      inc i
    elif c == '/' and i + 1 < source.len and source[i + 1] == '/':
      i += 2
      while i < source.len and source[i] != '\n':
        inc i
    elif c == '/' and i + 1 < source.len and source[i + 1] == '*':
      i += 2
      while i + 1 < source.len and not (source[i] == '*' and source[i + 1] == '/'):
        inc i
      if i + 1 < source.len:
        i += 2
      else:
        i = source.len
    elif c in {'"', '\''}:
      let quote = c
      inc i
      while i < source.len:
        if source[i] == '\\':
          i = min(i + 2, source.len)
        elif source[i] == quote:
          inc i
          break
        else:
          inc i
    elif c == '`':
      inc i
      while i < source.len and source[i] != '`':
        inc i
      if i < source.len:
        inc i
    elif isIdentifierStart(c):
      let start = i
      inc i
      while i < source.len and isIdentifierPart(source[i]):
        inc i
      result.add LexToken(text: source[start ..< i], identifier: true)
    else:
      result.add LexToken(text: $c)
      inc i

proc entryKind(name: string; kind: var ShaderEntryKind): bool =
  case name
  of "Fragment":
    kind = sekFragment
    true
  of "ColorEffect":
    kind = sekColorEffect
    true
  of "DistortionEffect":
    kind = sekDistortionEffect
    true
  of "LayerEffect":
    kind = sekLayerEffect
    true
  else:
    false

proc entryName(kind: ShaderEntryKind): string =
  case kind
  of sekFragment: "Fragment"
  of sekColorEffect: "ColorEffect"
  of sekDistortionEffect: "DistortionEffect"
  of sekLayerEffect: "LayerEffect"

proc inspectShaderSource*(source: string): ShaderSourceInfo =
  ## Finds a supported package-level shader function and checks effect image use.
  ## Full syntax and type errors remain the compiler frontend's responsibility.
  let tokens = tokenize(source)
  var entries: seq[ShaderEntryKind]
  var braceDepth = 0
  for i, token in tokens:
    if braceDepth == 0 and token.identifier and token.text == "func" and
        i + 1 < tokens.len and tokens[i + 1].identifier:
      var kind: ShaderEntryKind
      if entryKind(tokens[i + 1].text, kind):
        entries.add kind
    if token.text == "{":
      inc braceDepth
    elif token.text == "}" and braceDepth > 0:
      dec braceDepth

  if entries.len == 0:
    return
  if entries.len > 1:
    result.error = "shader: " & entryName(entries[0]) & " and " &
      entryName(entries[1]) & ": a shader has one entry point"
    return

  result.kind = entries[0]
  result.found = true
  if result.kind != sekFragment:
    for token in tokens:
      if token.identifier and token.text in ["image3At", "image3Sample", "image3Size"]:
        result.error = "shader: an effect's shader reads image0 to image2: " &
          "image3 is its content (layerAt, layerSample)"
        return
