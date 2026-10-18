import std/unittest

import mynim/internal/shader/lexer
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

  test "parses grouped parameters and named result types":
    let parsed = parseShaderFile("""
      package main
      func Fragment(dst vec4, pos vec2, x, y float, points []vec2) (color vec4) {}
    """)
    check parsed.error.message.len == 0
    let function = parsed.file.functions[0]
    check function.parameters.len == 4
    check function.parameters[0].names == @["dst"]
    check function.parameters[0].typeExpr.name == "vec4"
    check function.parameters[1].names == @["pos"]
    check function.parameters[2].names == @["x", "y"]
    check function.parameters[2].typeExpr.name == "float"
    check function.parameters[3].typeExpr.kind == saekArrayType
    check function.parameters[3].typeExpr.operator == "slice"
    check function.results.len == 1
    check function.results[0].names == @["color"]
    check function.results[0].typeExpr.name == "vec4"

  test "parses assignments, conditionals, loops, range, and return":
    let parsed = parseShaderFile("""
      package main
      func Fragment(pos vec2) vec4 {
        value := 1
        value += 2
        if value > 0 { value++ } else { value-- }
        for i := 0; i < 3; i++ { value += i }
        for _, point := range points { value += int(point.x) }
        return vec4(float(value))
      }
    """)
    check parsed.error.message.len == 0
    let body = parsed.file.functions[0].body
    check parsed.file.functions[0].hasBody
    check body.kind == saskBlock
    check body.statements.len == 6
    check body.statements[0].kind == saskAssignment
    check body.statements[0].operator == ":="
    check body.statements[1].operator == "+="
    let conditional = body.statements[2]
    check conditional.kind == saskIf
    check conditional.statements.len == 2
    check conditional.statements[0].statements[0].kind == saskIncDec
    let loop = body.statements[3]
    check loop.kind == saskFor
    check loop.statements.len == 3
    check loop.expressions.len == 1
    let range = body.statements[4]
    check range.kind == saskRange
    check range.operator == ":="
    check range.expressions.len == 3
    check body.statements[5].kind == saskReturn

  test "reports invalid statements at their token location":
    let tokens = lexShaderSource("return )").tokens
    let body = parseShaderStatements(tokens)
    check body.statement == nil
    check body.error.message == "expected expression, got ')'"
    check body.error.line == 1
    check body.error.column == 8

    let invalidFunction = parseShaderFile(
      "package main\nfunc Fragment() vec4 { return ) }")
    check invalidFunction.error.message == "expected expression, got ')'"
    check invalidFunction.error.line == 2
