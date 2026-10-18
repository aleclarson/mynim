import std/assertions

import mynim/image as image
import mynim/internal/gpu as gpu
import mynim/internal/raster as raster
import mynim/internal/scene as scene

block image_blur_geometry:
  let area = scene.imageArea(scene.Rect(x: 2, y: 1, w: -4, h: 3), 5, 4)
  doAssert area == image.rect(0, 1, 2, 4)

  let blur = scene.imageBlur(image.rect(3, 4, 8, 7), 4)
  let source = blur.imageSrc(scene.Rect(x: 4, y: 5, w: -2, h: 1))
  doAssert source == scene.Rect(x: 0.5, y: 0.5, w: -1, h: 0.5)
  doAssert blur.size().w > 0 and blur.size().h > 0
  doAssert gpu.imageDownPass(blur).mode == gpu.passClear
  doAssert gpu.imageBlurPass(blur, [1'i32, 0]).mode == gpu.passClear

block gpu_builder_uses_blurred_texture_and_source:
  let source = scene.newImageRgba(4, 2, newSeq[byte](4 * 4 * 2))
  let s = scene.Scene(width: 4, height: 2,
    ops: @[scene.Op(kind: scene.opImage,
      rect: scene.Rect(x: 0, y: 0, w: 4, h: 2),
      image: source, src: scene.Rect(x: 1, y: 0, w: 2, h: 1), blur: 3)])
  var called = false
  var builder: gpu.Builder
  builder.blurredImage = proc(img: scene.Image;
                              bk: scene.Backdrop): uint =
    called = true
    doAssert img == source
    doAssert bk.area == image.rect(1, 0, 3, 1)
    77
  discard builder.build(s, proc(img: scene.Image): uint = 11)
  doAssert called
  doAssert builder.batches.len == 1 and builder.batches[0].image == 77
  doAssert builder.instances.len == 1
  doAssert builder.instances[0].uv == [0'f32, 0, 1, 1]

block raster_blur_treats_outside_as_transparent:
  var pixels = newSeq[byte](3 * 4)
  for x in 0 ..< 3:
    pixels[4 * x] = 255
    pixels[4 * x + 3] = 255
  let source = scene.newImageRgba(3, 1, pixels)
  let s = scene.Scene(width: 3, height: 1,
    ops: @[scene.Op(kind: scene.opImage,
      rect: scene.Rect(x: 0, y: 0, w: 3, h: 1),
      image: source, src: scene.Rect(x: 0, y: 0, w: 3, h: 1), blur: 1)])
  var output = raster.newImage(3, 1)
  output.render(s)
  doAssert output.pix[3] < output.pix[7]
