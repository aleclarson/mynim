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

## Shader language types and their component layout.

import std/strutils

type
  BasicType* = enum
    ## Keep this order aligned with upstream `shaderir.BasicType`.
    btNone
    btBool
    btInt
    btFloat
    btVec2
    btVec3
    btVec4
    btIVec2
    btIVec3
    btIVec4
    btMat2
    btMat3
    btMat4
    btTexture
    btArray
    btStruct
    btUint
    btUVec2
    btUVec3
    btUVec4

  ShaderType* = object
    ## A scalar, vector, matrix, texture, array, or struct shader type.
    main*: BasicType
    sub*: seq[ShaderType]
    length*: int

proc `==`*(left, right: ShaderType): bool =
  if left.main != right.main or left.length != right.length or
      left.sub.len != right.sub.len:
    return false
  for i in 0 ..< left.sub.len:
    if left.sub[i] != right.sub[i]:
      return false
  true

proc `$`*(t: ShaderType): string =
  case t.main
  of btNone: "none"
  of btBool: "bool"
  of btInt: "int"
  of btFloat: "float"
  of btVec2: "vec2"
  of btVec3: "vec3"
  of btVec4: "vec4"
  of btIVec2: "ivec2"
  of btIVec3: "ivec3"
  of btIVec4: "ivec4"
  of btMat2: "mat2"
  of btMat3: "mat3"
  of btMat4: "mat4"
  of btTexture: "texture"
  of btArray:
    if t.sub.len == 0:
      "[" & $t.length & "]<invalid>"
    else:
      "[" & $t.length & "]" & $t.sub[0]
  of btStruct:
    var members: seq[string]
    for member in t.sub:
      members.add $member
    "struct{" & members.join(",") & "}"
  of btUint: "uint"
  of btUVec2: "uvec2"
  of btUVec3: "uvec3"
  of btUVec4: "uvec4"

proc dwordCount*(t: ShaderType): int =
  ## Returns the component count used for packed shader words, or -1 if unknown.
  case t.main
  of btBool, btInt, btFloat, btUint: 1
  of btVec2, btIVec2, btUVec2: 2
  of btVec3, btIVec3, btUVec3: 3
  of btVec4, btIVec4, btUVec4: 4
  of btMat2: 4
  of btMat3: 9
  of btMat4: 16
  of btArray:
    if t.sub.len == 0: -1 else: t.length * dwordCount(t.sub[0])
  of btNone, btTexture, btStruct: -1

proc isFloatVector*(t: ShaderType): bool {.inline.} =
  t.main in {btVec2, btVec3, btVec4}

proc isIntVector*(t: ShaderType): bool {.inline.} =
  t.main in {btIVec2, btIVec3, btIVec4}

proc isUintVector*(t: ShaderType): bool {.inline.} =
  t.main in {btUVec2, btUVec3, btUVec4}

proc isIntegerVector*(t: ShaderType): bool {.inline.} =
  t.isIntVector or t.isUintVector

proc isInteger*(t: ShaderType): bool {.inline.} =
  t.main in {btInt, btUint} or t.isIntegerVector

proc scalarType*(t: ShaderType): BasicType =
  ## Returns the component scalar for a vector or matrix, otherwise `main`.
  case t.main
  of btVec2, btVec3, btVec4, btMat2, btMat3, btMat4: btFloat
  of btIVec2, btIVec3, btIVec4: btInt
  of btUVec2, btUVec3, btUVec4: btUint
  else: t.main

proc vectorOf*(scalar: BasicType; count: int): BasicType =
  ## Returns a supported vector kind, or the scalar for a single component.
  if count == 1:
    return scalar
  if count < 2 or count > 4:
    return btNone
  case scalar
  of btFloat:
    [btNone, btNone, btVec2, btVec3, btVec4][count]
  of btInt:
    [btNone, btNone, btIVec2, btIVec3, btIVec4][count]
  of btUint:
    [btNone, btNone, btUVec2, btUVec3, btUVec4][count]
  else:
    btNone

proc vectorElementCount*(t: ShaderType): int =
  case t.main
  of btVec2, btIVec2, btUVec2: 2
  of btVec3, btIVec3, btUVec3: 3
  of btVec4, btIVec4, btUVec4: 4
  else: -1

proc isMatrix*(t: ShaderType): bool {.inline.} =
  t.main in {btMat2, btMat3, btMat4}

proc matrixSize*(t: ShaderType): int =
  case t.main
  of btMat2: 2
  of btMat3: 3
  of btMat4: 4
  else: -1
