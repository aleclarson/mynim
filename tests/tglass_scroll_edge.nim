import std/assertions

import mynim/image as image
import mynim/plugins/glass as glass
import mynim/ui as ui

proc edgeTester(edge: glass.ScrollEdge; background: ui.Color): ui.Tester =
  result = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().fill().background(background).children(proc() =
      if edge.bottom:
        discard ctx.box().absolute().left(0).right(0).bottom(0).height(40)
          .material(edge)
      else:
        discard ctx.box().absolute().left(0).right(0).top(0).height(40)
          .material(edge)
    )
  , 200, 100)
  result.setScale(2)

proc redAt(frame: image.RgbaImage; y: int): int =
  frame.at(100, y).r.int

block soft_edge_fades_the_background_over_content:
  let tester = edgeTester(glass.ScrollEdge(), ui.rgb(0, 0, 0))
  defer: tester.close()
  let frame = tester.image()
  doAssert redAt(frame, 0) in 210 .. 220
  doAssert redAt(frame, 40) in 100 .. 116
  doAssert redAt(frame, 79) < 8
  doAssert redAt(frame, 90) == 0

block soft_edge_can_rise_from_bottom_and_use_its_own_background:
  let bottom = edgeTester(glass.ScrollEdge(bottom: true), ui.rgb(0, 0, 0))
  defer: bottom.close()
  let frame = bottom.image()
  doAssert redAt(frame, 121) < 8
  doAssert redAt(frame, 199) in 210 .. 220

  let blue = edgeTester(glass.ScrollEdge(background: ui.rgb(0, 0, 200)),
    ui.rgb(0, 0, 0))
  defer: blue.close()
  let pixel = blue.image().at(100, 0)
  doAssert pixel.r == 0 and pixel.g == 0
  doAssert pixel.b.int in 165 .. 172

block soft_edge_preserves_individual_corner_radii:
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().fill().background(ui.rgb(0, 0, 0)).children(proc() =
      discard ctx.box().absolute().left(0).right(0).top(0).height(40)
        .radius(20, 0, 40, 0).material(glass.ScrollEdge())
    )
  , 200, 100)
  defer: tester.close()
  tester.setScale(2)

  let frame = tester.image()
  doAssert frame.at(0, 0).r.int == 0
  doAssert redAt(frame, 0) in 210 .. 220

block hard_edge_blurs_tones_and_draws_a_hairline:
  let black = edgeTester(glass.ScrollEdge(hard: true), ui.rgb(0, 0, 0))
  defer: black.close()
  let blackFrame = black.image()
  doAssert redAt(blackFrame, 40) in 205 .. 220
  doAssert redAt(blackFrame, 80) == 0

  let white = edgeTester(glass.ScrollEdge(hard: true), ui.rgb(255, 255, 255))
  defer: white.close()
  doAssert redAt(white.image(), 80) in 225 .. 235
  doAssert redAt(white.image(), 81) == 255

  white.setDark(true)
  let dark = white.image()
  doAssert redAt(dark, 40) < 100
  doAssert redAt(dark, 80) == 255

block describes_edge_style_and_orientation:
  doAssert $glass.ScrollEdge() == "scroll-edge soft"
  doAssert $glass.ScrollEdge(hard: true, bottom: true) ==
    "scroll-edge hard bottom"
