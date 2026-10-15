## The HLSL compiler and the precompiled shader code used by the D3D11
## renderer. The checked-in bytecode is used when its source checksum matches;
## custom effects and changed HLSL are compiled with d3dcompiler_47.dll.

import std/strutils
import ../../gpu as gpu
import ./com
import ./shaders

export shaders.shaderSum

when defined(windows):
  import std/dynlib
  import ./device

type
  ShaderCode* = object
    vertex*, pixel*, passVertex*, down*, blur*: string

when defined(windows):
  type D3DCompileProc = proc(source: pointer; sourceSize: csize_t;
      sourceName: cstring; defines, includes: pointer;
      entry, target: cstring; flags, effectFlags: uint32;
      code, errors: ptr uint): int32 {.stdcall.}

when defined(windows):
  var
    compilerLib: LibHandle
    procD3DCompile: D3DCompileProc

proc effectSource*(source: string): string =
  ## Wraps an effect body in the common shader declarations and epilogue.
  let marker = "\n// effect\n"
  let cut = effectSourceTemplate.find(marker)
  if cut < 0:
    raise newException(ValueError, "d3d11: effect shader template has no marker")
  result = "#define EFFECT\n" & shaderSource & "\n" &
    effectSourceTemplate[0 ..< cut] & "\n" & source & "\n" &
    effectSourceTemplate[cut + marker.len .. ^1]

proc bindCompiler(): bool =
  when defined(windows):
    if procD3DCompile != nil:
      return true
    compilerLib = loadLib(device.systemDir() & "\\d3dcompiler_47.dll")
    if compilerLib.isNil:
      return false
    let address = symAddr(compilerLib, "D3DCompile")
    if address.isNil:
      unloadLib(compilerLib)
      compilerLib = nil
      return false
    procD3DCompile = cast[D3DCompileProc](address)
    true
  else:
    false

proc blobBytes(blob: uint): string =
  if blob == 0:
    return
  let data = call(blob, 3)
  let size = call(blob, 4)
  if data == 0 or size == 0 or size > uint(high(int)):
    return
  result = newString(int(size))
  copyMem(addr result[0], cast[pointer](data), result.len)

proc compile(source, entry, target: string): tuple[code, error: string] =
  when defined(windows):
    if not bindCompiler():
      return ("", "d3d11: no shader compiler (d3dcompiler_47.dll)")
    var codeBlob, errorBlob: uint
    let
      sourceName = "shader.hlsl"
      entryName = entry.cstring
      targetName = target.cstring
      sourceData = if source.len == 0: nil else: unsafeAddr source[0]
    ## IEEE strictness avoids an optimizer stack overflow in transformed
    ## coverage sampling while retaining optimization level 3.
    const optimize3Ieee = (1'u32 shl 15) or (1'u32 shl 13)
    let hr = procD3DCompile(sourceData, csize_t(source.len),
      sourceName.cstring, nil, nil, entryName, targetName,
      optimize3Ieee, 0, addr codeBlob, addr errorBlob)
    defer:
      if codeBlob != 0:
        release(codeBlob)
      if errorBlob != 0:
        release(errorBlob)
    if hr < 0 or codeBlob == 0:
      var message = blobBytes(errorBlob)
      let nul = message.find('\0')
      if nul >= 0:
        message.setLen(nul)
      if message.len == 0:
        message = "unknown error"
      return ("", "d3d11: cannot compile the " & entry & " shader: " & message)
    (blobBytes(codeBlob), "")
  else:
    ("", "d3d11: shader compilation is available only on Windows")

proc compileEffect*(source: string): tuple[code, error: string] =
  ## Compiles an effect pixel shader against the common D3D11 shader helpers.
  compile(effectSource(source), "effectps", "ps_4_0")

proc compileEntry(entry, target: string): tuple[code, error: string] =
  compile(shaderSource, entry, target)

proc shaderCode*(forceCompile = false): tuple[code: ShaderCode, error: string] =
  ## Returns the checked-in bytecode when it matches shader.hlsl, or compiles
  ## all five entry points from the local source when it does not.
  if not forceCompile and gpu.sourceSum(shaderSource) == shaderSum:
    return (ShaderCode(vertex: vertexShader, pixel: pixelShader,
      passVertex: passVertexShader, down: downShader, blur: blurShader), "")

  for spec in [("vs", "vs_4_0"), ("ps", "ps_4_0"),
               ("passvs", "vs_4_0"), ("downps", "ps_4_0"),
               ("blurps", "ps_4_0")]:
    let (code, error) = compileEntry(spec[0], spec[1])
    if error.len > 0:
      return (ShaderCode(), error)
    case spec[0]
    of "vs": result.code.vertex = code
    of "ps": result.code.pixel = code
    of "passvs": result.code.passVertex = code
    of "downps": result.code.down = code
    of "blurps": result.code.blur = code
    else: discard
