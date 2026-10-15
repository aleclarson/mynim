## Regenerates the checked-in Direct3D bytecode from shader.hlsl on Windows.
## Run with: nim c -r --os:windows --cpu:amd64 gen_shaders.nim

import std/os
import ./shader

when isMainModule:
  let (code, error) = shaderCode(forceCompile = true)
  if error.len > 0:
    quit error
  let dir = currentSourcePath().parentDir
  writeFile(dir / "vertex.cso", code.vertex)
  writeFile(dir / "pixel.cso", code.pixel)
  writeFile(dir / "pass-vertex.cso", code.passVertex)
  writeFile(dir / "down.cso", code.down)
  writeFile(dir / "blur.cso", code.blur)
