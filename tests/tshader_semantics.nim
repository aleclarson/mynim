import std/unittest

import mynim/internal/shader/parser
import mynim/internal/shader/semantics
import mynim/internal/shaderir/types

suite "shader type semantics":
  test "resolves scalar vector and matrix types":
    for entry in [("bool", btBool), ("uint", btUint), ("vec3", btVec3),
                  ("uvec4", btUVec4), ("mat2", btMat2)]:
      let name = entry[0]
      let expected = entry[1]
      let parsed = parseShaderExpression(name)
      check parsed.error.message.len == 0
      let resolved = resolveShaderType(parsed.expr)
      check resolved.error.message.len == 0
      check resolved.shaderType == ShaderType(main: expected)

  test "resolves fixed arrays and parenthesized types":
    let parsed = parseShaderExpression("([3]vec2)")
    check parsed.error.message.len == 0
    let resolved = resolveShaderType(parsed.expr)
    check resolved.error.message.len == 0
    check resolved.shaderType.main == btArray
    check resolved.shaderType.length == 3
    check resolved.shaderType.sub == @[ShaderType(main: btVec2)]

    let hexadecimal = parseShaderExpression("[0x4]float")
    check hexadecimal.error.message.len == 0
    check resolveShaderType(hexadecimal.expr).shaderType.length == 4

  test "reports unsupported type forms with source locations":
    let unknown = parseShaderExpression("namedType")
    let unknownType = resolveShaderType(unknown.expr)
    check unknownType.error.message == "unknown shader type 'namedType'"
    check unknownType.error.column == 1

    let slice = parseShaderExpression("[]vec4")
    let sliceType = resolveShaderType(slice.expr)
    check sliceType.error.message == "slice types are not supported by shader IR"

    let fractionalLength = parseShaderExpression("[2.5]vec4")
    let invalidLength = resolveShaderType(fractionalLength.expr)
    check invalidLength.error.message ==
      "array length must be a nonnegative integer literal"
