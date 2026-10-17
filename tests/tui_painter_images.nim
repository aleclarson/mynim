import std/assertions

import mynim/internal/scene as scene
import mynim/image as sourceImage
import mynim/ui as ui

block painter_images:
  let pixels = sourceImage.newRgba(sourceImage.rect(0, 0, 2, 2))
  pixels.set(0, 0, sourceImage.Rgba(r: 255, g: 0, b: 0, a: 255))
  pixels.set(1, 0, sourceImage.Rgba(r: 0, g: 255, b: 0, a: 255))
  pixels.set(0, 1, sourceImage.Rgba(r: 0, g: 0, b: 255, a: 255))
  pixels.set(1, 1, sourceImage.Rgba(r: 255, g: 255, b: 255, a: 255))
  let bitmap = ui.newBitmap(pixels).pixelated()
  let (vector, svgError) = ui.parseSvg("""
    <svg xmlns="http://www.w3.org/2000/svg" width="2" height="1">
      <rect width="2" height="1" fill="currentColor"/>
    </svg>
  """)
  doAssert svgError.len == 0 and vector != nil

  let context = ui.newContext()
  let tint = ui.rgb(240, 20, 30)
  let theme = ui.darkTheme()
  context.build(proc(ctx: ui.Context) =
    ctx.setTheme(theme)
    discard ctx.box().size(40, 20).opacity(0.5'f32)
      .draw(proc(p: var ui.Painter; r: ui.Rect) =
        p.image(bitmap, ui.Rect(x: r.x + 1, y: r.y + 2, w: 8, h: 4),
          ui.Fit.FillBox)
        p.imageRegion(bitmap, ui.Rect(x: 1, y: 0, w: 1, h: 2),
          ui.Rect(x: r.x + 20, y: r.y + 2, w: 6, h: 8),
          ui.ImageOptions(flipX: true, flipY: true, tint: tint))
        p.image(vector, ui.Rect(x: r.x + 30, y: r.y + 2, w: 8, h: 4),
          ui.Fit.FillBox)
        p.icon(vector, ui.Rect(x: r.x + 30, y: r.y + 8, w: 8, h: 4), tint)
        p.focusRing(ui.Rect(x: r.x + 5, y: r.y + 10, w: 10, h: 8),
          [2'f32, 3, 4, 5])
      )
  )

  let frame = context.layout(ui.Rect(x: 12, y: 20, w: 40, h: 20))
    .paintScene(2)
  doAssert frame.ops.len == 6

  let bitmapOp = frame.ops[1]
  doAssert bitmapOp.kind == scene.opImage
  doAssert bitmapOp.rect == scene.Rect(x: 2, y: 4, w: 16, h: 8)
  doAssert bitmapOp.src == scene.Rect(x: 0, y: 0, w: 2, h: 2)
  doAssert bitmapOp.image != nil
  doAssert bitmapOp.pixelated
  doAssert bitmapOp.opacity == 0.5'f32

  let regionOp = frame.ops[2]
  doAssert regionOp.rect == scene.Rect(x: 40, y: 4, w: 12, h: 16)
  doAssert regionOp.src == scene.Rect(x: 2, y: 2, w: -1, h: -2)
  doAssert regionOp.color == scene.Color(r: 240, g: 20, b: 30, a: 255)
  doAssert regionOp.pixelated
  doAssert regionOp.opacity == 0.5'f32

  let svgOp = frame.ops[3]
  doAssert svgOp.kind == scene.opImage
  doAssert svgOp.rect == scene.Rect(x: 60, y: 4, w: 16, h: 8)
  doAssert svgOp.image != nil
  doAssert svgOp.opacity == 0.5'f32

  let iconOp = frame.ops[4]
  doAssert iconOp.kind == scene.opImage
  doAssert iconOp.rect == scene.Rect(x: 60, y: 16, w: 16, h: 8)
  doAssert iconOp.image != nil and iconOp.image != svgOp.image

  let focusOp = frame.ops[5]
  doAssert focusOp.kind == scene.opFill
  doAssert focusOp.rect == scene.Rect(x: 4, y: 14, w: 32, h: 28)
  doAssert focusOp.radii == [10'f32, 12, 14, 16]
  doAssert focusOp.border == [4'f32, 4, 4, 4]
  doAssert focusOp.borderColor == scene.Color(r: theme.focus.r,
    g: theme.focus.g, b: theme.focus.b, a: theme.focus.a)
  doAssert focusOp.opacity == 0.5'f32
  context.close()
