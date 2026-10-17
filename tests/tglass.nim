import std/assertions

import mynim/image as image
import mynim/internal/platform as platform
import mynim/plugins/glass as glass
import mynim/ui as ui

proc rgbAt(frame: image.RgbaImage; x, y: int): array[3, int] =
  let pixel = frame.at(x, y)
  [pixel.r.int, pixel.g.int, pixel.b.int]

block paints_material_over_its_backdrop:
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().fill().background(ui.rgb(20, 120, 220)).children(proc() =
      discard ctx.row().size(200, 44).radius(22).material(glass.Glass())
        .children(proc() = discard ctx.text("On glass"))
    )
  , 300, 100)
  defer: tester.close()

  doAssert tester.hasText("On glass")
  let light = rgbAt(tester.image(), 80, 22)
  doAssert light[0] > 100 and light[2] > light[0]

  tester.setDark(true)
  let dark = rgbAt(tester.image(), 80, 22)
  doAssert dark[0] < light[0]

  tester.setDark(false)
  let clearGlass = glass.Glass(style: glass.Clear)
  let clearTester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().fill().background(ui.rgb(20, 120, 220)).children(proc() =
      discard ctx.row().size(200, 44).radius(22).material(clearGlass)
    )
  , 300, 100)
  defer: clearTester.close()
  doAssert rgbAt(clearTester.image(), 80, 22)[0] < light[0]

block direct_painter_api:
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().fill().background(ui.rgb(0, 0, 0)).draw(
      proc(painter: var ui.Painter; rect: ui.Rect) =
        painter.paint(ui.Rect(x: 20, y: 20, w: 100, h: 60), 20, glass.Glass())
    )
  , 160, 100)
  defer: tester.close()
  let gray = rgbAt(tester.image(), 70, 50)[0]
  doAssert gray >= 100 and gray <= 180

block large_effect_scene:
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().fill().background(ui.rgb(20, 120, 220)).children(proc() =
      discard ctx.box().size(600, 600).radius(60).material(glass.Glass())
    )
  , 700, 700)
  defer: tester.close()
  doAssert rgbAt(tester.image(), 350, 350)[0] > 100

block interactive_material_grows_on_press:
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().fill().background(ui.rgb(0, 0, 0)).children(proc() =
      discard ctx.box().absolute().left(50).top(50).size(200, 100)
        .radius(20).material(glass.Glass(interactive: true))
    )
  , 300, 200)
  defer: tester.close()
  tester.setScale(2)
  tester.setPreferences(platform.Preferences(reduceMotion: true))
  let before = rgbAt(tester.image(), 99, 100)[0]
  tester.press(150, 100)
  tester.frame()
  let pressed = rgbAt(tester.image(), 99, 100)[0]
  doAssert pressed > before + 50
  tester.release(150, 100)
  tester.frame()
  doAssert rgbAt(tester.image(), 99, 100)[0] == before

block describes_material:
  let value = glass.Glass(style: glass.Clear, tint: ui.rgb(1, 2, 3),
    interactive: true)
  doAssert $value == "glass clear tint(#010203ff) interactive"
