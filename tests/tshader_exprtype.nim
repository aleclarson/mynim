import std/unittest

import mynim/internal/shaderir/exprtype
import mynim/internal/shaderir/program
import mynim/internal/shaderir/types

proc literal(kind: ShaderConstantKind; value: string = "1";
             unsigned = false): ShaderExpr =
  ShaderExpr(
    kind: sexNumber,
    constant: ShaderConstant(kind: kind, text: value),
    unsigned: unsigned
  )

proc binary(op: ShaderOp; left, right: ShaderExpr): ShaderExpr =
  ShaderExpr(kind: sexBinary, op: op, exprs: @[left, right])

proc call(builtin: ShaderBuiltinFunc; args: varargs[ShaderExpr]): ShaderExpr =
  var exprs = @[ShaderExpr(kind: sexBuiltinFunc, builtinFunc: builtin)]
  exprs.add args
  ShaderExpr(kind: sexCall, exprs: exprs)

proc inferredMain(expr: ShaderExpr; env: ShaderTypeEnv): BasicType =
  shaderTypeOf(expr, env).main

suite "shader IR expression types":
  test "constants and indexed variables take their declared types":
    let env = ShaderTypeEnv(
      localTypes: @[ShaderType(main: btVec3)],
      uniformTypes: @[ShaderType(main: btUint)],
      functionReturns: @[ShaderType(main: btMat2)]
    )
    let constantTypes = @[
      inferredMain(literal(sckBool, "true"), env),
      inferredMain(literal(sckFloat, "1.25"), env),
      inferredMain(literal(sckInt), env),
      inferredMain(literal(sckInt, unsigned = true), env)
    ]
    check constantTypes == @[btBool, btFloat, btInt, btUint]
    let valueTypes = @[
      inferredMain(ShaderExpr(kind: sexLocalVariable, index: 0), env),
      inferredMain(ShaderExpr(kind: sexUniformVariable, index: 0), env),
      inferredMain(ShaderExpr(kind: sexTextureVariable), env)
    ]
    check valueTypes == @[btVec3, btUint, btTexture]
    let function = ShaderExpr(kind: sexFunction, index: 0)
    let functionType = inferredMain(ShaderExpr(kind: sexCall, exprs: @[function]), env)
    check functionType == btMat2

  test "binary expressions resolve comparisons, shifts, and mixed dimensions":
    let env = ShaderTypeEnv()
    let vector = ShaderExpr(kind: sexLocalVariable, index: 0)
    let scalar = literal(sckFloat)
    let matrix = ShaderExpr(kind: sexLocalVariable, index: 1)
    let typedEnv = ShaderTypeEnv(localTypes: @[
      ShaderType(main: btVec3), ShaderType(main: btMat3)
    ])
    let actual = @[
      inferredMain(binary(sopVectorEqual, vector, vector), typedEnv),
      inferredMain(binary(sopComponentWiseMul, scalar, vector), typedEnv),
      inferredMain(binary(sopLeftShift, vector, scalar), typedEnv),
      inferredMain(binary(sopMatrixMul, matrix, vector), typedEnv),
      inferredMain(binary(sopMatrixMul, vector, matrix), typedEnv),
      inferredMain(binary(sopAdd, scalar, scalar), env)
    ]
    check actual == @[btBool, btVec3, btVec3, btVec3, btVec3, btFloat]

  test "built-in calls use their result and operand types":
    let env = ShaderTypeEnv()
    let scalar = literal(sckFloat)
    let vector = ShaderExpr(kind: sexLocalVariable, index: 0)
    let typedEnv = ShaderTypeEnv(localTypes: @[ShaderType(main: btVec4)])
    let actual = @[
      inferredMain(call(sbfBool, scalar), env),
      inferredMain(call(sbfDot, vector, vector), typedEnv),
      inferredMain(call(sbfStep, scalar, vector), typedEnv),
      inferredMain(call(sbfSmoothstep, scalar, scalar, vector), typedEnv),
      inferredMain(call(sbfMin, vector, scalar), typedEnv)
    ]
    check actual == @[btBool, btFloat, btVec4, btVec4, btVec4]

  test "field selection and indexing resolve vectors, arrays, and matrices":
    let env = ShaderTypeEnv(localTypes: @[
      ShaderType(main: btUVec4),
      ShaderType(main: btArray, sub: @[ShaderType(main: btFloat)], length: 3),
      ShaderType(main: btMat2),
      ShaderType(main: btStruct, sub: @[ShaderType(main: btUint)])
    ])
    let vector = ShaderExpr(kind: sexLocalVariable, index: 0)
    let swizzle = ShaderExpr(kind: sexSwizzling, swizzling: "xyz")
    let field = ShaderExpr(kind: sexFieldSelector, exprs: @[vector, swizzle])
    let fieldType = inferredMain(field, env)
    check fieldType == btUVec3
    let array = ShaderExpr(kind: sexLocalVariable, index: 1)
    let arrayType = inferredMain(
      ShaderExpr(kind: sexIndex, exprs: @[array, literal(sckInt)]), env)
    check arrayType == btFloat
    let matrix = ShaderExpr(kind: sexLocalVariable, index: 2)
    let matrixType = inferredMain(
      ShaderExpr(kind: sexIndex, exprs: @[matrix, literal(sckInt)]), env)
    check matrixType == btVec2
    let struct = ShaderExpr(kind: sexLocalVariable, index: 3)
    let member = ShaderExpr(kind: sexStructMember, index: 0)
    let memberType = inferredMain(
      ShaderExpr(kind: sexFieldSelector, exprs: @[struct, member]), env)
    check memberType == btUint
