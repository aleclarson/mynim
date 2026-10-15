import std/assertions
import mynim/internal/scene as sceneTypes
import mynim/ui

block scroll_state_tracks_and_clamps_content:
  let c = newContext()
  let state = newScrollState()
  let innerState = newScrollState()
  var outer, inner, content, tail: Element
  c.build(proc(ctx: Context) =
    outer = ctx.scroll(state).size(30, 30)
    discard outer.children(proc() =
      inner = ctx.scroll(innerState).size(30, 20)
      discard inner.children(proc() =
        content = ctx.box().size(30, 40).shrink(0)
      )
      tail = ctx.box().size(30, 40).shrink(0)
    )
  )
  var layout = c.layout(40, 40)
  doAssert state.maxOffset() == (x: 0'f32, y: 30'f32)
  doAssert innerState.maxOffset() == (x: 0'f32, y: 20'f32)
  doAssert layout.bounds(content).y == 0
  doAssert layout.bounds(tail).y == 20

  state.scrollTo(0, 100)
  layout = c.layout(40, 40)
  doAssert state.offset().y == 30
  doAssert layout.bounds(inner).y == -30
  doAssert layout.bounds(content).y == -30
  doAssert layout.bounds(tail).y == -10

  innerState.scrollTo(0, 10)
  layout = c.layout(40, 40)
  doAssert layout.bounds(content).y == -40

block scroll_both_axes:
  let c = newContext()
  let state = newScrollState()
  var content: Element
  c.build(proc(ctx: Context) =
    let viewport = ctx.scrollBoth(state).size(100, 100)
    discard viewport.children(proc() =
      content = ctx.box().size(400, 300).shrink(0)
    )
  )
  state.scrollTo(25, 40)
  let layout = c.layout(100, 100)
  doAssert state.maxOffset() == (x: 300'f32, y: 200'f32)
  doAssert layout.bounds(content).x == -25
  doAssert layout.bounds(content).y == -40

block scroll_paint_clips_descendants:
  let c = newContext()
  let state = newScrollState()
  var viewport: Element
  c.build(proc(ctx: Context) =
    viewport = ctx.scroll(state).size(20, 20).radius(4)
    discard viewport.children(proc() =
      discard ctx.box().size(20, 40).shrink(0).background(rgb(255, 0, 0))
    )
  )
  let frame = c.layout(20, 20).paintScene()
  var pushes, pops: int
  for op in frame.ops:
    if op.kind == sceneTypes.opPushClip:
      inc pushes
    elif op.kind == sceneTypes.opPopClip:
      inc pops
  doAssert pushes == 1
  doAssert pops == 1
