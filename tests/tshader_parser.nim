import std/unittest

import mynim/internal/shader/parser

suite "shader expression parser":
  test "uses Go operator precedence and left associativity":
    let parsed = parseShaderExpression("1 + 2*3 == 7 || false")
    check parsed.error.message.len == 0
    check parsed.expr.kind == saekBinary
    check parsed.expr.operator == "||"
    let equality = parsed.expr.children[0]
    check equality.operator == "=="
    check equality.children[0].operator == "+"
    check equality.children[0].children[1].operator == "*"
    check equality.children[1].kind == saekLiteral

    let leftAssoc = parseShaderExpression("a-b-c")
    check leftAssoc.error.message.len == 0
    check leftAssoc.expr.operator == "-"
    check leftAssoc.expr.children[0].operator == "-"

  test "parses calls, selectors, indexes, and unary operations":
    let parsed = parseShaderExpression("!mix(a+b, pixels[i].xy)")
    check parsed.error.message.len == 0
    check parsed.expr.kind == saekUnary
    let call = parsed.expr.children[0]
    check call.kind == saekCall
    check call.children.len == 3
    check call.children[1].operator == "+"
    let selector = call.children[2]
    check selector.kind == saekSelector
    check selector.name == "xy"
    check selector.children[0].kind == saekIndex

  test "parses fixed array composite literals and elided elements":
    let parsed = parseShaderExpression("[3]vec2{vec2(0), vec2(1), vec2(2),}")
    check parsed.error.message.len == 0
    check parsed.expr.kind == saekComposite
    check parsed.expr.children.len == 4
    let arrayType = parsed.expr.children[0]
    check arrayType.kind == saekArrayType
    check arrayType.operator == "array"
    check arrayType.children[0].name == "3"
    check arrayType.children[1].name == "vec2"

  test "parses slices and keyed composite elements":
    let sliced = parseShaderExpression("image0[low:high:limit]")
    check sliced.error.message.len == 0
    check sliced.expr.kind == saekSlice
    check sliced.expr.children.len == 4
    check sliced.expr.children[3].name == "limit"

    let keyed = parseShaderExpression("[2]vec2{0: vec2(1)}")
    check keyed.error.message.len == 0
    check keyed.expr.children[1].kind == saekKeyValue

  test "reports malformed expressions with byte locations":
    let parsed = parseShaderExpression("value + )")
    check parsed.expr == nil
    check parsed.error.message == "expected expression, got ')'"
    check parsed.error.line == 1
    check parsed.error.column == 9

    let invalid = parseShaderExpression("x := 1")
    check invalid.error.message == "unexpected token ':=' after expression"

suite "shader file parser":
  test "collects package functions and skips other declarations":
    let parsed = parseShaderFile("""
      package main
      import (
        "math"
      )
      const size = 2
      type T struct { value vec4 }
      var palette = [2]vec4{vec4(0), vec4(1)}
      func helper(pos vec2) vec4 {
        if pos.x > 0 { return vec4(1) }
        return vec4(0)
      }
      func (T) Fragment() vec4 { return vec4(0) }
      func Fragment(pos vec2) vec4 {
        note := `func ColorEffect() {}`
        _ = note
        return helper(pos)
      }
    """)
    check parsed.error.message.len == 0
    check parsed.file.packageName == "main"
    check parsed.file.functions.len == 3
    check parsed.file.functions[0].name == "helper"
    check parsed.file.functions[1].name == "Fragment"
    check parsed.file.functions[1].receiver
    check parsed.file.functions[2].name == "Fragment"
    check not parsed.file.functions[2].receiver
    check parsed.file.functions[2].bodyTokens.len > 0

  test "reports package and function syntax errors with positions":
    let noPackage = parseShaderFile("func Fragment() vec4 { return vec4(1) }")
    check noPackage.error.message == "expected a package clause"
    check noPackage.error.line == 1
    check noPackage.error.column == 1

    let malformed = parseShaderFile("package main\nfunc Fragment vec4")
    check malformed.error.message == "expected a parameter list after function name"
    check malformed.error.line == 2
