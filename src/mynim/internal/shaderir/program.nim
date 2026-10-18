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

import std/strutils

import ./types

type
  ShaderConstantKind* = enum
    sckInvalid
    sckBool
    sckInt
    sckFloat

  ShaderConstant* = object
    ## A compile-time value; numeric text stays exact until it is evaluated.
    kind*: ShaderConstantKind
    text*: string
    boolValue*: bool

  ShaderStmtKind* = enum
    ## Keep the ordering aligned with upstream `shaderir.StmtType`.
    sskExprStmt
    sskBlockStmt
    sskAssign
    sskInit
    sskIf
    sskFor
    sskContinue
    sskBreak
    sskReturn
    sskDiscard

  ShaderExprKind* = enum
    ## Keep the ordering aligned with upstream `shaderir.ExprType`.
    sexBlank
    sexNumber
    sexUniformVariable
    sexTextureVariable
    sexLocalVariable
    sexStructMember
    sexBuiltinFunc
    sexSwizzling
    sexFunction
    sexUnary
    sexBinary
    sexSelection
    sexCall
    sexFieldSelector
    sexIndex

  ShaderOp* = enum
    ## Keep the ordering aligned with upstream `shaderir.Op`.
    sopAdd
    sopSub
    sopNot
    sopComplement
    sopComponentWiseMul
    sopMatrixMul
    sopDiv
    sopMod
    sopLeftShift
    sopRightShift
    sopLessThan
    sopLessThanEqual
    sopGreaterThan
    sopGreaterThanEqual
    sopEqual
    sopNotEqual
    sopVectorEqual
    sopVectorNotEqual
    sopAnd
    sopAndNot
    sopXor
    sopOr
    sopAndAnd
    sopOrOr

  ShaderBuiltinFunc* = enum
    ## Keep this order aligned with upstream `shaderir.BuiltinFunc`.
    sbfLen
    sbfCap
    sbfBool
    sbfInt
    sbfFloat
    sbfVec2
    sbfVec3
    sbfVec4
    sbfIVec2
    sbfIVec3
    sbfIVec4
    sbfUint
    sbfUVec2
    sbfUVec3
    sbfUVec4
    sbfMat2
    sbfMat3
    sbfMat4
    sbfRadians
    sbfDegrees
    sbfSin
    sbfCos
    sbfTan
    sbfAsin
    sbfAcos
    sbfAtan
    sbfAtan2
    sbfPow
    sbfExp
    sbfLog
    sbfExp2
    sbfLog2
    sbfSqrt
    sbfInverseSqrt
    sbfAbs
    sbfSign
    sbfFloor
    sbfCeil
    sbfFract
    sbfMod
    sbfMin
    sbfMax
    sbfClamp
    sbfMix
    sbfStep
    sbfSmoothstep
    sbfLength
    sbfDistance
    sbfDot
    sbfCross
    sbfNormalize
    sbfFaceForward
    sbfReflect
    sbfRefract
    sbfTranspose
    sbfDfdx
    sbfDfdy
    sbfFwidth
    sbfDiscard
    sbfTexelAt
    sbfFrontFacing

  ShaderSwizzlingSet* = enum
    ## The spelling alphabet used by a shader swizzle.
    sssXYZW
    sssRGBA
    sssSTPQ

  ShaderBlock* = ref object
    ## A block's local variables use absolute indices within their function.
    localVars*: seq[ShaderType]
    localVarIndexOffset*: int
    statements*: seq[ShaderStmt]

  ShaderStmt* = object
    kind*: ShaderStmtKind
    exprs*: seq[ShaderExpr]
    blocks*: seq[ShaderBlock]
    forVarType*: ShaderType
    forVarIndex*: int
    forInit*: ShaderConstant
    forEnd*: ShaderConstant
    forOp*: ShaderOp
    forDelta*: ShaderConstant
    initIndex*: int

  ShaderExpr* = object
    kind*: ShaderExprKind
    exprs*: seq[ShaderExpr]
    constant*: ShaderConstant
    builtinFunc*: ShaderBuiltinFunc
    swizzling*: string
    swizzlingSet*: ShaderSwizzlingSet
    index*: int
    op*: ShaderOp
    unsigned*: bool
    untyped*: bool

  ShaderFunction* = object
    index*: int
    inParams*: seq[ShaderType]
    outParams*: seq[ShaderType]
    returnType*: ShaderType
    body*: ShaderBlock

  ShaderVertexFunction* = object
    ## The block uses attribute, position, and varying pseudo-parameters.
    body*: ShaderBlock

  ShaderFragmentFunction* = object
    ## The block uses fragment-position and varying pseudo-parameters.
    body*: ShaderBlock

  ShaderSourceId* = array[16, byte]

  ShaderProgram* = ref object
    uniformNames*: seq[string]
    uniforms*: seq[ShaderType]
    textureCount*: int
    attributes*: seq[ShaderType]
    varyings*: seq[ShaderType]
    functions*: seq[ShaderFunction]
    vertexFunc*: ShaderVertexFunction
    fragmentFunc*: ShaderFragmentFunction
    sourceId*: ShaderSourceId
    fragmentSource*: string
    uniformFactors: seq[uint32]

const builtinNames: array[ShaderBuiltinFunc, string] = [
  "len", "cap", "bool", "int", "float", "vec2", "vec3", "vec4", "ivec2",
  "ivec3", "ivec4", "uint", "uvec2", "uvec3", "uvec4", "mat2", "mat3",
  "mat4", "radians", "degrees", "sin", "cos", "tan", "asin", "acos",
  "atan", "atan2", "pow", "exp", "log", "exp2", "log2", "sqrt",
  "inversesqrt", "abs", "sign", "floor", "ceil", "fract", "mod", "min",
  "max", "clamp", "mix", "step", "smoothstep", "length", "distance", "dot",
  "cross", "normalize", "faceforward", "reflect", "refract", "transpose",
  "dfdx", "dfdy", "fwidth", "discard", "__texelAt", "frontfacing"
]

proc builtinSourceName*(builtin: ShaderBuiltinFunc): string =
  ## Returns the source-level spelling of a shader built-in function.
  builtinNames[builtin]

proc parseBuiltinFunc*(name: string; builtin: var ShaderBuiltinFunc): bool =
  ## Parses built-ins accepted by the compiler; radians/degrees are reserved.
  if name in ["radians", "degrees"]:
    return false
  for i, candidate in builtinNames:
    if candidate == name:
      builtin = ShaderBuiltinFunc(i)
      return true

proc shaderOpFromToken*(text: string; left, right: ShaderType;
                        op: var ShaderOp): bool =
  ## Maps a source operator to the typed IR operation it represents.
  case text
  of "+": op = sopAdd
  of "-": op = sopSub
  of "!": op = sopNot
  of "~": op = sopComplement
  of "*":
    op = if left.isMatrix or right.isMatrix: sopMatrixMul else: sopComponentWiseMul
  of "/", "/=": op = sopDiv
  of "%": op = sopMod
  of "<<": op = sopLeftShift
  of ">>": op = sopRightShift
  of "<": op = sopLessThan
  of "<=": op = sopLessThanEqual
  of ">": op = sopGreaterThan
  of ">=": op = sopGreaterThanEqual
  of "==":
    op = if left.isFloatVector or left.isIntegerVector or
      right.isFloatVector or right.isIntegerVector: sopVectorEqual else: sopEqual
  of "!=":
    op = if left.isFloatVector or left.isIntegerVector or
      right.isFloatVector or right.isIntegerVector: sopVectorNotEqual else: sopNotEqual
  of "&": op = sopAnd
  of "&^": op = sopAndNot
  of "^": op = sopXor
  of "|": op = sopOr
  of "&&": op = sopAndAnd
  of "||": op = sopOrOr
  else: return false
  true

proc sourceSwizzling*(expr: ShaderExpr): string =
  ## Spells a swizzle in its original component alphabet.
  let names = case expr.swizzlingSet
    of sssRGBA: "rgba"
    of sssSTPQ: "stpq"
    else: return expr.swizzling
  for component in expr.swizzling:
    let index = "xyzw".find(component)
    if index >= 0:
      result.add names[index]
    else:
      result.add component

proc isValidSwizzling*(swizzling: string): bool =
  ## Reports whether a one-to-four component swizzle uses one alphabet.
  if swizzling.len < 1 or swizzling.len > 4:
    return false
  let alphabet =
    if swizzling[0] in {'x', 'y', 'z', 'w'}: "xyzw"
    elif swizzling[0] in {'r', 'g', 'b', 'a'}: "rgba"
    elif swizzling[0] in {'s', 't', 'p', 'q'}: "stpq"
    else: return false
  for component in swizzling:
    if component notin alphabet:
      return false
  true
