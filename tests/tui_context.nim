import std/assertions

import mynim/ui

block checked_element_lifetime:
  let c = newContext()
  doAssertRaises ValueError:
    discard c.box()
  var outer, child: Element
  var builtChild = false
  c.build(proc(ctx: Context) =
    outer = ctx.row()
    doAssert outer.valid
    discard outer.children(proc() =
      child = ctx.box()
      doAssert child.valid
      builtChild = true
    )
    doAssert outer.valid
  )
  doAssert builtChild
  doAssert not outer.valid
  doAssert not child.valid

  c.build(proc(ctx: Context) =
    let current = ctx.column()
    doAssert current.valid
    doAssert not outer.valid
  )
  doAssert not outer.valid
  c.close()
  doAssert not outer.valid
  doAssertRaises ValueError:
    c.build(proc(ctx: Context) = discard)

block handle_after_context_drop:
  var escaped: Element
  block:
    let c = newContext()
    c.build(proc(ctx: Context) = escaped = ctx.box())
  doAssert not escaped.valid

block handle_size:
  when sizeof(pointer) == 8:
    doAssert sizeof(Element) == 16
