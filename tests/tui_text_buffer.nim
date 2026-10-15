import std/assertions

include "../src/mynim.nim"
import mynim/internal/platform as platform
import mynim/ui as ui

let empty = ui.newTextBuffer()
doAssert empty.len() == 0
doAssert empty.byteLen() == 0
doAssert empty.utf16Len() == 0
doAssert empty.lineCount() == 1
empty.set("ready")
doAssert $empty == "ready"
let missing: ui.TextBuffer = nil
var nilRejected = false
try:
  missing.set("cannot initialize through nil")
except ValueError:
  nilRejected = true
doAssert nilRejected

let buffer = ui.newTextBuffer("A😀\nB")
doAssert buffer.len() == 4
doAssert buffer.byteLen() == 7
doAssert buffer.utf16Len() == 5
doAssert buffer.lineCount() == 2
doAssert buffer.slice(1, 2) == "😀"
doAssert buffer.slice(2, 0) == "A😀"
doAssert buffer.line(0) == "A😀"
doAssert buffer.line(1) == "B"
doAssert buffer.lineRange(0) == (0, 2)
doAssert buffer.lineRange(1) == (3, 4)
doAssert buffer.lineAt(3) == 1
doAssert buffer.utf16Offset(2) == 3
doAssert buffer.runeOffset(2) == 1

let (selected, actual) = buffer.textForRange(platform.TextRange(
  start: 1, `end`: 3))
doAssert selected == "😀"
doAssert actual == platform.TextRange(start: 1, `end`: 3)

let before = buffer.snapshot()
buffer.replace(1, 2, "👍")
doAssert $buffer == "A👍\nB"
doAssert $before == "A😀\nB"
doAssert before.version() == 0
doAssert buffer.version() == 1

let adjusted = buffer.replaceUtf16(platform.TextRange(start: 2, `end`: 2), "x")
doAssert adjusted == platform.TextRange(start: 1, `end`: 1)
doAssert $buffer == "Ax👍\nB"
doAssert buffer.version() == 2

buffer.restore(before)
doAssert $buffer == "A😀\nB"
doAssert buffer.version() == 3

var output = ""
let written = before.writeTo(proc(chunk: string): int =
  output.add(chunk)
  chunk.len)
doAssert written == 7
doAssert output == "A😀\nB"

var partialOutput = ""
let partialWritten = before.writeTo(proc(chunk: string): int =
  let count = min(2, chunk.len)
  partialOutput.add(chunk[0 ..< count])
  count)
doAssert partialWritten == 7
doAssert partialOutput == "A😀\nB"

var rejectedWrite = false
try:
  discard before.writeTo(proc(chunk: string): int = 0)
except IOError:
  rejectedWrite = true
doAssert rejectedWrite

buffer.set("tail\n")
doAssert buffer.lineCount() == 2
doAssert buffer.line(1) == ""
doAssert buffer.slice(-5, 100) == "tail\n"
