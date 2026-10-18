import std/unittest

import mynim/internal/shaderir/types

suite "shader IR types":
  test "basic type ordinals match the upstream shader IR":
    check ord(btNone) == 0
    check ord(btTexture) == 13
    check ord(btArray) == 14
    check ord(btStruct) == 15
    check ord(btUint) == 16
    check ord(btUVec4) == 19

  test "types compare recursively and render their structure":
    let vector = ShaderType(main: btVec3)
    let array = ShaderType(main: btArray, sub: @[vector], length: 2)
    let sameArray = ShaderType(main: btArray, sub: @[ShaderType(main: btVec3)], length: 2)
    let struct = ShaderType(main: btStruct, sub: @[ShaderType(main: btFloat), array])
    check array == sameArray
    check array != ShaderType(main: btArray, sub: @[vector], length: 3)
    check $array == "[2]vec3"
    check $struct == "struct{float,[2]vec3}"

  test "component counts account for arrays and matrices":
    check ShaderType(main: btBool).dwordCount == 1
    check ShaderType(main: btMat3).dwordCount == 9
    check ShaderType(main: btArray, sub: @[ShaderType(main: btVec4)], length: 3).dwordCount == 12
    check ShaderType(main: btStruct).dwordCount == -1

  test "scalar, vector, and matrix helpers preserve component kinds":
    check ShaderType(main: btUVec3).scalarType == btUint
    check ShaderType(main: btMat4).scalarType == btFloat
    check ShaderType(main: btUVec3).vectorElementCount == 3
    check ShaderType(main: btMat2).vectorElementCount == -1
    check vectorOf(btInt, 4) == btIVec4
    check vectorOf(btUint, 3) == btUVec3
    check vectorOf(btBool, 2) == btNone
    check ShaderType(main: btMat3).matrixSize == 3
    check ShaderType(main: btVec3).matrixSize == -1
