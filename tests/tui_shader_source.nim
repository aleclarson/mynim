import std/unittest

import mynim/ui/shader/source

suite "shader source inspection":
  test "finds only top-level entry point declarations":
    let info = inspectShaderSource("""
      package main
      // func Fragment(dst vec4, pos vec2) vec4 { return vec4(1) }
      var example = `func LayerEffect(pos vec2) vec4 {}`
      func Fragment(dst vec4, pos vec2) vec4 {
        message := "func ColorEffect(pos vec2, color vec4) vec4 {}"
        _ = message
        return vec4(1)
      }
    """)
    check info.found
    check info.kind == sekFragment
    check info.error.len == 0

  test "ignores receiver methods as entry points":
    let info = inspectShaderSource("package main\ntype T int\nfunc (T) Fragment() {}")
    check not info.found

  test "rejects multiple entry points":
    let info = inspectShaderSource("""
      package main
      func ColorEffect(pos vec2, color vec4) vec4 { return color }
      func LayerEffect(pos vec2) vec4 { return vec4(0) }
    """)
    check not info.found
    check info.error == "shader: ColorEffect and LayerEffect: a shader has one entry point"

  test "reserves image3 for effect content":
    let info = inspectShaderSource("""
      package main
      func LayerEffect(pos vec2) vec4 {
        return image3Sample(pos)
      }
    """)
    check info.found
    check info.error == "shader: an effect's shader reads image0 to image2: image3 is its content (layerAt, layerSample)"

  test "does not treat comments or strings as image reads":
    let info = inspectShaderSource("""
      package main
      // image3At(pos)
      func ColorEffect(pos vec2, color vec4) vec4 {
        note := "image3Sample(pos)"
        _ = note
        return color
      }
    """)
    check info.found
    check info.error.len == 0
