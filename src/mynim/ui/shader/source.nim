## Source-level shader declarations shared by the shader compiler frontend.

import mynim/internal/shader/lexer

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
  let lexed = lexShaderSource(source)
  if lexed.error.message.len > 0:
    return
  let tokens = lexed.tokens
  var entries: seq[ShaderEntryKind]
  var braceDepth = 0
  for i, token in tokens:
    if braceDepth == 0 and token.kind == stkKeyword and token.text == "func" and
        i + 1 < tokens.len and tokens[i + 1].kind == stkIdentifier:
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
      if token.kind == stkIdentifier and
          token.text in ["image3At", "image3Sample", "image3Size"]:
        result.error = "shader: an effect's shader reads image0 to image2: " &
          "image3 is its content (layerAt, layerSample)"
        return
