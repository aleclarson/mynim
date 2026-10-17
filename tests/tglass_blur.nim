import std/[assertions, options]

import mynim/image as image
import mynim/plugins/glass as glass
import mynim/ui as ui

proc stripeContrast(frame: image.RgbaImage; y, x0, x1: int): int =
  var low = 255
  var high = 0
  for x in x0 ..< x1:
    let value = frame.at(x, y).r.int
    low = min(low, value)
    high = max(high, value)
  high - low

proc drawStripes(painter: var ui.Painter; rect: ui.Rect; period: float32) =
  var x = 0'f32
  while x < rect.w:
    painter.fill(ui.Rect(x: rect.x + x, y: rect.y,
      w: period / 2, h: rect.h), ui.rgb(0, 0, 0), 0)
    x += period

proc drawHorizontalStripes(painter: var ui.Painter; rect: ui.Rect;
                           period: float32) =
  var y = 0'f32
  while y < rect.h:
    painter.fill(ui.Rect(x: rect.x, y: rect.y + y,
      w: rect.w, h: period / 2), ui.rgb(0, 0, 0), 0)
    y += period

proc columnContrast(frame: image.RgbaImage; x, y0, y1: int): int =
  var low = 255
  var high = 0
  for y in y0 ..< y1:
    let value = frame.at(x, y).r.int
    low = min(low, value)
    high = max(high, value)
  high - low

block uniform_blur_only_changes_its_material_bounds:
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().fill().children(proc() =
      discard ctx.box().fill().background(ui.rgb(255, 255, 255)).draw(
        proc(painter: var ui.Painter; rect: ui.Rect) =
          painter.drawStripes(rect, 2)
      )
      discard ctx.box().absolute().left(0).top(0).size(200, 30)
        .material(glass.Blur(radius: 4))
    )
  , 200, 60)
  defer: tester.close()

  let frame = tester.image()
  doAssert stripeContrast(frame, 15, 20, 180) < 10
  doAssert stripeContrast(frame, 45, 20, 180) == 255

block gradient_mask_fades_the_blur:
  let mask = ui.LinearGradient(fromColor: ui.rgb(0, 0, 0),
    toColor: ui.transparent, angle: 180)
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().fill().children(proc() =
      discard ctx.box().fill().background(ui.rgb(255, 255, 255)).draw(
        proc(painter: var ui.Painter; rect: ui.Rect) =
          painter.drawStripes(rect, 8)
      )
      discard ctx.box().absolute().left(0).top(10).right(0).height(80)
        .material(glass.Blur(radius: 6, mask: some(mask)))
    )
  , 100, 100)
  defer: tester.close()
  tester.setScale(2)

  let frame = tester.image()
  let top = stripeContrast(frame, 22, 40, 160)
  let middle = stripeContrast(frame, 100, 40, 160)
  let bottom = stripeContrast(frame, 176, 40, 160)
  doAssert top < 4
  doAssert middle > 8 and middle < 60
  doAssert bottom > 180
  doAssert stripeContrast(frame, 182, 40, 160) == 255

block angled_mask_can_increase_blur_across_its_bounds:
  let mask = ui.LinearGradient(fromColor: ui.transparent,
    toColor: ui.rgb(0, 0, 0), angle: 90)
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().fill().children(proc() =
      discard ctx.box().fill().background(ui.rgb(255, 255, 255)).draw(
        proc(painter: var ui.Painter; rect: ui.Rect) =
          painter.drawHorizontalStripes(rect, 8)
      )
      discard ctx.box().absolute().left(0).top(0).size(100, 100)
        .material(glass.Blur(radius: 6, mask: some(mask)))
    )
  , 100, 100)
  defer: tester.close()
  tester.setScale(2)

  let frame = tester.image()
  let
    left = columnContrast(frame, 4, 20, 180)
    middle = columnContrast(frame, 100, 20, 180)
    right = columnContrast(frame, 196, 20, 180)
  doAssert left == 255
  doAssert middle > 8 and middle < 60
  doAssert right < middle and right < 20

block describes_blur_and_mask:
  doAssert $glass.Blur(radius: 12) == "blur(12)"
  let mask = ui.LinearGradient(fromColor: ui.rgb(0, 0, 0),
    toColor: ui.transparent, angle: 180)
  doAssert $glass.Blur(radius: 8, mask: some(mask)) ==
    "blur(8) mask(100%→0% 180°)"
