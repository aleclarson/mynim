## Copyright 2020 The Ebiten Authors
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
## https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##
## Modified by the MyGo contributors: uint and uvecN, and dynamic loops.

## Expression type inference for checked shader IR.

import ./program
import ./types

type
  ShaderTypeEnv* = object
    ## Types addressed by the IR's local, uniform, and function indices.
    localTypes*: seq[ShaderType]
    uniformTypes*: seq[ShaderType]
    functionReturns*: seq[ShaderType]

proc shaderTypeOf*(expr: ShaderExpr; env: ShaderTypeEnv): ShaderType

proc operandType(exprs: openArray[ShaderExpr]; env: ShaderTypeEnv): ShaderType =
  for expr in exprs:
    if expr.kind != sexNumber:
      return shaderTypeOf(expr, env)
  if exprs.len > 0:
    return shaderTypeOf(exprs[0], env)

proc binaryType(expr: ShaderExpr; env: ShaderTypeEnv): ShaderType =
  let left = shaderTypeOf(expr.exprs[0], env)
  let right = shaderTypeOf(expr.exprs[1], env)
  case expr.op
  of sopLessThan, sopLessThanEqual, sopGreaterThan, sopGreaterThanEqual,
      sopEqual, sopNotEqual, sopVectorEqual, sopVectorNotEqual, sopAndAnd,
      sopOrOr:
    return ShaderType(main: btBool)
  of sopLeftShift, sopRightShift:
    return left
  of sopMatrixMul:
    if left.isMatrix and right.isMatrix:
      return left
    if left.isMatrix and right.isFloatVector:
      return right
    if left.isFloatVector and right.isMatrix:
      return left
    if right.isMatrix:
      return right
    return left
  else:
    discard

  let leftScalar = left.main in {btFloat, btInt, btUint, btBool}
  let rightScalar = right.main in {btFloat, btInt, btUint, btBool}
  if leftScalar and not rightScalar:
    return right
  if rightScalar and not leftScalar:
    return left
  if expr.exprs[0].kind == sexNumber and expr.exprs[1].kind != sexNumber:
    return right
  left

proc callType(expr: ShaderExpr; env: ShaderTypeEnv): ShaderType =
  let callee = expr.exprs[0]
  let args = if expr.exprs.len > 1: expr.exprs[1 .. ^1] else: @[]
  if callee.kind == sexFunction:
    return env.functionReturns[callee.index]
  case callee.builtinFunc
  of sbfBool, sbfFrontFacing:
    ShaderType(main: btBool)
  of sbfInt, sbfLen, sbfCap:
    ShaderType(main: btInt)
  of sbfUint:
    ShaderType(main: btUint)
  of sbfFloat, sbfLength, sbfDistance, sbfDot:
    ShaderType(main: btFloat)
  of sbfVec2:
    ShaderType(main: btVec2)
  of sbfVec3, sbfCross:
    ShaderType(main: btVec3)
  of sbfVec4, sbfTexelAt:
    ShaderType(main: btVec4)
  of sbfIVec2:
    ShaderType(main: btIVec2)
  of sbfIVec3:
    ShaderType(main: btIVec3)
  of sbfIVec4:
    ShaderType(main: btIVec4)
  of sbfUVec2:
    ShaderType(main: btUVec2)
  of sbfUVec3:
    ShaderType(main: btUVec3)
  of sbfUVec4:
    ShaderType(main: btUVec4)
  of sbfMat2:
    ShaderType(main: btMat2)
  of sbfMat3:
    ShaderType(main: btMat3)
  of sbfMat4:
    ShaderType(main: btMat4)
  of sbfStep:
    shaderTypeOf(args[1], env)
  of sbfSmoothstep:
    shaderTypeOf(args[2], env)
  of sbfMin, sbfMax:
    shaderTypeOf(args[0], env)
  else:
    operandType(args, env)

proc shaderTypeOf*(expr: ShaderExpr; env: ShaderTypeEnv): ShaderType =
  ## Infers the result type of an expression already checked by the compiler.
  case expr.kind
  of sexNumber:
    case expr.constant.kind
    of sckBool: ShaderType(main: btBool)
    of sckFloat: ShaderType(main: btFloat)
    of sckInt:
      if expr.unsigned: ShaderType(main: btUint) else: ShaderType(main: btInt)
    of sckInvalid: ShaderType()
  of sexUniformVariable:
    env.uniformTypes[expr.index]
  of sexTextureVariable:
    ShaderType(main: btTexture)
  of sexLocalVariable:
    env.localTypes[expr.index]
  of sexUnary:
    if expr.op == sopNot:
      ShaderType(main: btBool)
    else:
      shaderTypeOf(expr.exprs[0], env)
  of sexBinary:
    binaryType(expr, env)
  of sexSelection:
    if expr.exprs.len > 1:
      operandType(expr.exprs.toOpenArray(1, expr.exprs.high), env)
    else:
      ShaderType()
  of sexCall:
    callType(expr, env)
  of sexFieldSelector:
    let base = shaderTypeOf(expr.exprs[0], env)
    let selector = expr.exprs[1]
    case selector.kind
    of sexSwizzling:
      ShaderType(main: vectorOf(base.scalarType, selector.swizzling.len))
    of sexStructMember:
      base.sub[selector.index]
    else:
      ShaderType()
  of sexIndex:
    let base = shaderTypeOf(expr.exprs[0], env)
    if base.main == btArray:
      base.sub[0]
    elif base.isMatrix:
      ShaderType(main: vectorOf(btFloat, base.matrixSize))
    else:
      ShaderType(main: base.scalarType)
  of sexBlank, sexStructMember, sexBuiltinFunc, sexSwizzling, sexFunction:
    ShaderType()
