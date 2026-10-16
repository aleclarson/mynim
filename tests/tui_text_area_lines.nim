import std/[assertions, strutils]
import mynim/ui as ui

block text_area_lines_follow_wrapped_text:
  var draft = ""
  let buffer = ui.newTextBuffer()
  var minLines = 1
  var fixedHeight = false
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.column().width(200).children(proc() =
      var area = ctx.textAreaBase(draft).lines(minLines, 4)
      if fixedHeight:
        area = area.height(90)
      discard area.label("Draft")
      discard ctx.textAreaBufferBase(buffer).lines(1, 4).label("Buffer")
    )
  , 400, 600)
  defer: tester.close()

  let (empty, foundEmpty) = tester.find("Draft")
  doAssert foundEmpty and empty.h > 0
  let (emptyBuffer, foundEmptyBuffer) = tester.find("Buffer")
  doAssert foundEmptyBuffer and emptyBuffer.h == empty.h

  draft = "one line"
  tester.frame()
  let (short, foundShort) = tester.find("Draft")
  doAssert foundShort and short.h == empty.h

  draft = repeat("word ", 12)
  tester.frame()
  let (wrapped, foundWrapped) = tester.find("Draft")
  doAssert foundWrapped and wrapped.h > empty.h * 1.5'f32

  draft = repeat("word ", 400)
  tester.frame()
  let (long, foundLong) = tester.find("Draft")
  doAssert foundLong and abs(long.h - 4 * empty.h) <= 1

  buffer.set(repeat("word ", 400))
  tester.frame()
  let (longBuffer, foundLongBuffer) = tester.find("Buffer")
  doAssert foundLongBuffer and abs(longBuffer.h - 4 * empty.h) <= 1

  minLines = 3
  draft = ""
  tester.frame()
  let (threeLines, foundThreeLines) = tester.find("Draft")
  doAssert foundThreeLines and abs(threeLines.h - 3 * empty.h) <= 1

  fixedHeight = true
  tester.frame()
  let (fixed, foundFixed) = tester.find("Draft")
  doAssert foundFixed and fixed.h == 90
