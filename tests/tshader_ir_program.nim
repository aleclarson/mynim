import std/unittest

import mynim/internal/shaderir/program
import mynim/internal/shaderir/types

suite "shader IR program model":
  test "statement, expression, and operator ordinals match upstream":
    check ord(sskExprStmt) == 0
    check ord(sskDiscard) == 9
    check ord(sexBlank) == 0
    check ord(sexIndex) == 14
    check ord(sopAdd) == 0
    check ord(sopOrOr) == 23

  test "programs hold typed entry blocks and exact numeric literals":
    let literal = ShaderExpr(
      kind: sexNumber,
      constant: ShaderConstant(kind: sckInt, text: "0x1_0000_0001")
    )
    let body = ShaderBlock(statements: @[
      ShaderStmt(kind: sskReturn, exprs: @[literal])
    ])
    let program = ShaderProgram(
      uniforms: @[ShaderType(main: btFloat)],
      fragmentFunc: ShaderFragmentFunction(body: body),
      fragmentSource: "func Fragment() int { return 1 }"
    )
    check program.fragmentFunc.body.statements[0].exprs[0].constant.text ==
      "0x1_0000_0001"
    check program.uniforms[0].main == btFloat

  test "operators select matrix multiply and vector comparisons":
    var op: ShaderOp
    check shaderOpFromToken("*", ShaderType(main: btMat2),
      ShaderType(main: btVec2), op)
    check op == sopMatrixMul
    check shaderOpFromToken("*", ShaderType(main: btVec3),
      ShaderType(main: btFloat), op)
    check op == sopComponentWiseMul
    check shaderOpFromToken("==", ShaderType(main: btUVec4),
      ShaderType(main: btUVec4), op)
    check op == sopVectorEqual
    check shaderOpFromToken("&^", ShaderType(main: btUint),
      ShaderType(main: btUint), op)
    check op == sopAndNot
    check not shaderOpFromToken("=", ShaderType(main: btInt),
      ShaderType(main: btInt), op)

  test "built-in names preserve upstream spelling and unsupported aliases":
    var builtin: ShaderBuiltinFunc
    check parseBuiltinFunc("inversesqrt", builtin)
    check builtin == sbfInverseSqrt
    check builtinSourceName(sbfTexelAt) == "__texelAt"
    check builtinSourceName(sbfFrontFacing) == "frontfacing"
    check not parseBuiltinFunc("radians", builtin)
    check not parseBuiltinFunc("unknown", builtin)

  test "swizzles map alphabets and reject mixed or oversized selections":
    let rgba = ShaderExpr(kind: sexSwizzling, swizzling: "xw",
      swizzlingSet: sssRGBA)
    let stpq = ShaderExpr(kind: sexSwizzling, swizzling: "zw",
      swizzlingSet: sssSTPQ)
    check sourceSwizzling(rgba) == "ra"
    check sourceSwizzling(stpq) == "pq"
    check isValidSwizzling("xyzw")
    check isValidSwizzling("rgba")
    check isValidSwizzling("stp")
    check not isValidSwizzling("xga")
    check not isValidSwizzling("xyzwx")
    check not isValidSwizzling("")
