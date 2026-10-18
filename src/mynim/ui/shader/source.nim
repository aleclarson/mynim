## Source-level shader declarations shared by the shader compiler frontend.

import mynim/internal/shader/lexer
import mynim/internal/shader/parser

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
  ## Type checking and full Kage grammar validation remain compiler work.
  let parsed = parseShaderFile(source)
  if parsed.error.message.len > 0:
    result.error = "shader: " & parsed.error.message & " at line " &
      $parsed.error.line & ", column " & $parsed.error.column
    return
  var entries: seq[ShaderEntryKind]
  for function in parsed.file.functions:
    var kind: ShaderEntryKind
    if not function.receiver and entryKind(function.name, kind):
      entries.add kind

  if entries.len == 0:
    return
  if entries.len > 1:
    result.error = "shader: " & entryName(entries[0]) & " and " &
      entryName(entries[1]) & ": a shader has one entry point"
    return

  result.kind = entries[0]
  result.found = true
  if result.kind != sekFragment:
    for token in parsed.file.tokens:
      if token.kind == stkIdentifier and
          token.text in ["image3At", "image3Sample", "image3Size"]:
        result.error = "shader: an effect's shader reads image0 to image2: " &
          "image3 is its content (layerAt, layerSample)"
        return
