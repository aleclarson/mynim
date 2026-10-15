import std/[assertions, math]

import mynim/ui

block alignment_and_fit_types:
  doAssert Align.Start != Align.Center
  doAssert Align.Stretch != Align.SpaceBetween
  doAssert Fit.Contain != Fit.Cover
  doAssert Fit.ScaleDown != Fit.NaturalSize
  doAssert BorderStyle.Solid != BorderStyle.Dashed

block rect_edges:
  let r = Rect(x: 2, y: 3, w: 10, h: 12)
  doAssert r.contains(2, 3)
  doAssert r.contains(11.99, 14.99)
  doAssert not r.contains(12, 10)
  doAssert not r.contains(4, 15)

block automatic_size:
  doAssert classify(Auto) == fcInf

block gradient_value:
  let gradient = LinearGradient(fromColor: rgb(0, 0, 0),
    toColor: rgb(255, 255, 255), angle: 90, oklab: true)
  doAssert gradient.fromColor == rgb(0, 0, 0)
  doAssert gradient.toColor == rgb(255, 255, 255)
  doAssert gradient.angle == 90
  doAssert gradient.oklab
