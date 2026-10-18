import std/[assertions, strutils]
import mynim/internal/gpu as gpu
import mynim/internal/gpu/d3d11/shader
import mynim/internal/gpu/d3d11/shaders

let (code, error) = shaderCode()
if gpu.sourceSum(shaderSource) == shaderSum:
  doAssert error.len == 0, error
  doAssert code.vertex.len == 3664
  doAssert code.pixel.len == 77612
  doAssert code.passVertex.len == 604
  doAssert code.down.len == 1528
  doAssert code.blur.len == 1620
else:
  when defined(windows):
    doAssert error.len == 0, error
    doAssert code.vertex.len > 0
    doAssert code.pixel.len > 0
    doAssert code.passVertex.len > 0
    doAssert code.down.len > 0
    doAssert code.blur.len > 0
  else:
    doAssert error.contains("shader compilation is available only on Windows")

let effect = effectSource("float3 testEffect() { return float3(1, 0, 0); }")
doAssert effect.startsWith("#define EFFECT\n")
doAssert "float3 testEffect()" in effect
doAssert "PSOut effectps(VSOut i)" in effect
