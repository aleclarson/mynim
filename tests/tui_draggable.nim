import std/[assertions, options]
import mynim/ui as ui

let snap = ui.nearest(ui.Point(), ui.Point(x: 100, y: 0))
doAssert snap(ui.Point(x: 95, y: 0)) == ui.Point(x: 100, y: 0)
doAssertRaises ValueError:
  discard ui.nearest()

var offset = ui.Point()
var isDragging = false
var shown = ui.Point()
var clicks = 0
let tester = ui.newTester(proc(ctx: ui.Context) =
  let card = ctx.box().size(40, 40).label("card")
    .onClick(proc() = inc clicks)
    .draggable(offset, ui.DraggableOptions(
      axis: {ui.DragAxis.Vertical},
      bounds: some(ui.Rect(w: 80, h: 15)),
      rigid: true))
  discard card.children(proc() =
    discard ctx.box().size(10, 10).label("inside"))
  isDragging = card.dragging()
  shown = card.dragOffset(), 160, 100)

let (initial, initialFound) = tester.find("card")
doAssert initialFound and initial.x == 0 and initial.y == 0
let (insideInitial, insideInitialFound) = tester.find("inside")
doAssert insideInitialFound
tester.press(10, 10)
tester.release(10, 10)
doAssert clicks == 1
clicks = 0
tester.press(10, 10)
tester.move(40, 50)
doAssert isDragging
doAssert offset.x == 0 and offset.y == 15
doAssert shown == ui.Point(x: 0, y: 15)
let (moved, movedFound) = tester.find("card")
doAssert movedFound and moved.x == 0 and moved.y == 15
let (insideMoved, insideMovedFound) = tester.find("inside")
doAssert insideMovedFound
doAssert insideMoved.x == insideInitial.x and
  insideMoved.y == insideInitial.y + 15
tester.release(40, 50)
doAssert not isDragging
doAssert clicks == 0
doAssert offset == ui.Point(x: 0, y: 15)
tester.close()

var internalShown = ui.Point()
let internalTester = ui.newTester(proc(ctx: ui.Context) =
  let card = ctx.box().size(20, 20).draggable()
  internalShown = card.dragOffset(), 100, 100)
internalTester.press(10, 10)
internalTester.move(25, 30)
doAssert internalShown == ui.Point(x: 15, y: 20)
internalTester.close()

var snappedOffset = ui.Point()
var snapInput = ui.Point()
let snapTester = ui.newTester(proc(ctx: ui.Context) =
  discard ctx.box().size(20, 20).draggable(snappedOffset,
    ui.DraggableOptions(
      axis: {ui.DragAxis.Horizontal},
      snap: proc(point: ui.Point): ui.Point =
        snapInput = point
        ui.Point(x: 80, y: 0))), 120, 80)
snapTester.setPreferences(ui.Preferences(reduceMotion: true, textScale: 1))
snapTester.press(10, 10)
snapTester.move(40, 10)
snapTester.release(40, 10)
doAssert snapInput.x >= 0 and snapInput.y == 0
doAssert snappedOffset == ui.Point(x: 80, y: 0)
snapTester.close()

var rubberbandOffset = ui.Point()
let rubberbandTester = ui.newTester(proc(ctx: ui.Context) =
  discard ctx.box().size(20, 20).draggable(rubberbandOffset,
    ui.DraggableOptions(
      axis: {ui.DragAxis.Horizontal},
      bounds: some(ui.Rect(w: 40, h: 20)))), 120, 80)
rubberbandTester.press(10, 10)
rubberbandTester.move(100, 10)
doAssert rubberbandOffset.x > 40 and rubberbandOffset.x < 120
doAssert rubberbandOffset.y == 0
rubberbandTester.close()
