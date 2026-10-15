## Precompiled Direct3D shader bytecode from the pinned Mygo reference.
## Regenerate from the adjacent HLSL sources with the Windows SDK shader
## compiler when shader.hlsl changes.

const
  shaderSum* = "88bb64068ae4165f139d87a7b9ce763ea38c450fd8635f33a5f2c35c701addc8"
  vertexShader* = staticRead("vertex.cso")
  pixelShader* = staticRead("pixel.cso")
  passVertexShader* = staticRead("pass-vertex.cso")
  downShader* = staticRead("down.cso")
  blurShader* = staticRead("blur.cso")
  shaderSource* = staticRead("shader.hlsl")
  effectSourceTemplate* = staticRead("effect.hlsl")
