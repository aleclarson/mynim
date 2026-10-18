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
## Modified by the MyGo contributors: uint and uvecN.

## Resolves parsed Kage type expressions into the shared shader IR types.

import std/strutils

import ./lexer
import ./parser
import ../shaderir/types

type
  ShaderTypeResult* = object
    shaderType*: ShaderType
    error*: ShaderParseError

proc failType(expr: ShaderAstExpr; message: string): ShaderTypeResult =
  ShaderTypeResult(error: ShaderParseError(
    message: message,
    offset: expr.token.offset,
    line: expr.token.line,
    column: expr.token.column
  ))

proc integerLiteral(text: string): tuple[value: BiggestUInt, valid: bool] =
  if text.len == 0 or text.endsWith("i"):
    return
  var base = 10'u64
  var start = 0
  if text.len > 2 and text[0] == '0':
    case text[1]
    of 'b', 'B':
      base = 2
      start = 2
    of 'o', 'O':
      base = 8
      start = 2
    of 'x', 'X':
      base = 16
      start = 2
    else:
      base = 8
      start = 1
  let limit = BiggestUInt(high(int))
  var sawDigit = false
  for i in start ..< text.len:
    let c = text[i]
    if c == '_':
      continue
    var digit: int
    if c in {'0'..'9'}:
      digit = ord(c) - ord('0')
    elif c in {'a'..'f'}:
      digit = ord(c) - ord('a') + 10
    elif c in {'A'..'F'}:
      digit = ord(c) - ord('A') + 10
    else:
      return
    if BiggestUInt(digit) >= base or
        result.value > (limit - BiggestUInt(digit)) div base:
      return
    result.value = result.value * base + BiggestUInt(digit)
    sawDigit = true
  result.valid = sawDigit

proc arrayLength(expr: ShaderAstExpr): tuple[value: int, valid: bool] =
  if expr == nil:
    return
  case expr.kind
  of saekLiteral:
    if expr.token.kind != stkNumber:
      return
    let parsed = integerLiteral(expr.name)
    if parsed.valid:
      result.value = int(parsed.value)
      result.valid = true
  of saekParenthesized:
    if expr.children.len == 1:
      return arrayLength(expr.children[0])
  of saekUnary:
    if expr.children.len != 1 or expr.operator notin ["+", "-"]:
      return
    let inner = arrayLength(expr.children[0])
    if inner.valid and (expr.operator == "+" or inner.value == 0):
      result = inner
  else:
    discard

proc basicType(name: string; kind: var BasicType): bool =
  case name
  of "bool": kind = btBool
  of "int": kind = btInt
  of "uint": kind = btUint
  of "float": kind = btFloat
  of "vec2": kind = btVec2
  of "vec3": kind = btVec3
  of "vec4": kind = btVec4
  of "ivec2": kind = btIVec2
  of "ivec3": kind = btIVec3
  of "ivec4": kind = btIVec4
  of "uvec2": kind = btUVec2
  of "uvec3": kind = btUVec3
  of "uvec4": kind = btUVec4
  of "mat2": kind = btMat2
  of "mat3": kind = btMat3
  of "mat4": kind = btMat4
  of "texture": kind = btTexture
  else: return false
  true

proc resolveShaderType*(expr: ShaderAstExpr): ShaderTypeResult =
  ## Maps supported scalar/vector/matrix types and fixed arrays into shader IR.
  if expr == nil:
    return
  case expr.kind
  of saekIdentifier:
    var kind: BasicType
    if not basicType(expr.name, kind):
      return failType(expr, "unknown shader type '" & expr.name & "'")
    result.shaderType = ShaderType(main: kind)
  of saekParenthesized:
    if expr.children.len != 1:
      return failType(expr, "invalid parenthesized shader type")
    return resolveShaderType(expr.children[0])
  of saekArrayType:
    if expr.operator != "array":
      return failType(expr, "slice types are not supported by shader IR")
    if expr.children.len != 2:
      return failType(expr, "invalid array type")
    let count = arrayLength(expr.children[0])
    if not count.valid:
      return failType(expr, "array length must be a nonnegative integer literal")
    let element = resolveShaderType(expr.children[1])
    if element.error.message.len > 0:
      return element
    result.shaderType = ShaderType(
      main: btArray,
      sub: @[element.shaderType],
      length: count.value
    )
  else:
    return failType(expr, "unsupported shader type expression")
