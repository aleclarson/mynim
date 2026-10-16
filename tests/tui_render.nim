import std/assertions

include "../src/mynim.nim"
import mynim/ui as ui

var built = false
let rendered = ui.render(proc(c: ui.Context) =
  built = true
  discard c.text("Rendered")
, 32, 16, 2)

doAssert built
doAssert rendered.rect.min.x == 0 and rendered.rect.min.y == 0
doAssert rendered.rect.dx == 64 and rendered.rect.dy == 32
doAssert rendered.stride == 64 * 4
doAssert rendered.pix.len == 64 * 32 * 4
