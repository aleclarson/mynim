## Package svg parses SVG documents and draws them into pixels, for
## the icons and pictures of package ui, in Nim alone (internal/svg).
##
## It draws paths and the basic shapes, groups, nested svg elements,
## use and symbol elements, transforms, fills and strokes (with joins,
## caps and dashes) of colors, currentColor and linear and radial
## gradients, opacity, clip paths and masks, and style sheets of
## simple selectors (type, class and id). Text, embedded images,
## patterns, markers and filters are not drawn.

import std/[math, strutils, tables, sets, sequtils, locks, algorithm,
            parsexml, streams, hashes]
import ../image
import vec

## Limits on what a document may hold.
const
  maxElems = 1 shl 18
  maxDepth = 256

## elem is an element of the document.
type
  decl = object
    name, value: string
  elem = ref object
    name: string
    attrs: Table[string, string]
    kids: seq[elem]
    parent: elem
    text: string ## of a style element
    ## props are the declarations of its properties, in the order they
    ## apply: attributes, style sheets, then the style attribute.
    props: seq[decl]

include svg/geom
include svg/colors
include svg/stroke
include svg/style
include svg/dom
include svg/compile
include svg/render

## renderers keeps renderers and their memory between drawings, as
## Go's sync.Pool does.
var renderersLock: Lock
var renderers: seq[renderer]
initLock(renderersLock)

proc renderersGet(): renderer =
  withLock(renderersLock):
    if renderers.len > 0:
      result = renderers[^1]
      renderers.setLen(renderers.len - 1)
      return
  new(result)

proc renderersPut(r: renderer) =
  withLock(renderersLock):
    renderers.add(r)

## Parse parses an SVG document.
proc parse*(data: openArray[byte] | string): tuple[d: Doc, err: string] =
  when data is string:
    let s = data
  else:
    var s = newString(data.len)
    if data.len > 0:
      copyMem(addr s[0], unsafeAddr data[0], data.len)
  let (root, err) = parseXml(s)
  if err != "":
    return (nil, err)
  var c = newCompiler(root)
  (c.doc(), "")

## Size returns the document's size in pixels: its width and height, or
## those of its viewBox.
proc size*(d: Doc): tuple[w, h: float64] = (d.w, d.h)

## UsesCurrentColor reports whether the color Draw takes for
## currentColor changes what it draws.
proc usesCurrentColor*(d: Doc): bool = d.current

proc draw(d: Doc; dst: RgbaImage; current: rgba; m: matrix) =
  let b = dst.bounds
  let
    w = b.dx
    h = b.dy
  if w <= 0 or h <= 0 or d.root.isNil:
    return
  let r = renderersGet()
  defer: renderersPut(r)
  if r.w != w or r.h != h:
    r.w = w
    r.h = h
    r.free.setLen(0)
  r.current = current
  let l = r.getLayer()
  defer: r.release(l)
  r.drawNode(d.root, m, l, 1)
  let dr = l.dirty
  for y in dr.min.y ..< dr.max.y:
    for i in countup(0, (dr.max.x - dr.min.x) * 4 - 1, 4):
      let src = (y * w + dr.min.x) * 4 + i
      let o = dst.pixOffset(b.min.x + dr.min.x, b.min.y + y) + i
      if l.pix[src + 3] == 255:
        dst.pix[o] = l.pix[src]
        dst.pix[o + 1] = l.pix[src + 1]
        dst.pix[o + 2] = l.pix[src + 2]
        dst.pix[o + 3] = l.pix[src + 3]
      elif l.pix[src + 3] > 0:
        over(addr dst.pix[o], uint32(l.pix[src]), uint32(l.pix[src + 1]),
             uint32(l.pix[src + 2]), uint32(l.pix[src + 3]))

## Draw draws the document over the pixels of dst, fitting its viewBox
## in them as its preserveAspectRatio says, or stretched to them with
## stretch. currentColor is current where the document does not set
## the color property.
proc draw*(d: Doc; dst: RgbaImage; current: Nrgba; stretch: bool) =
  let b = dst.bounds
  var a = d.par
  if stretch:
    a = aspect(none: true)
  d.draw(dst, rgba(r: float64(current.r) / 255,
                   g: float64(current.g) / 255,
                   b: float64(current.b) / 255,
                   a: float64(current.a) / 255),
         viewBoxTransform(d.view, a, float64(b.dx), float64(b.dy)))

## DrawRotated draws the document as Draw does in a box w×h pixels at
## the center of dst, turned by degrees clockwise around it.
proc drawRotated*(d: Doc; dst: RgbaImage; current: Nrgba;
                  w, h, degrees: float64) =
  let b = dst.bounds
  let m = translate(float64(b.dx) / 2, float64(b.dy) / 2).mul(
      rotation(degrees)).mul(translate(-w / 2, -h / 2))
  d.draw(dst, rgba(r: float64(current.r) / 255,
                   g: float64(current.g) / 255,
                   b: float64(current.b) / 255,
                   a: float64(current.a) / 255),
         m.mul(viewBoxTransform(d.view, d.par, w, h)))
