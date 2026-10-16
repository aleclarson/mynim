import std/[assertions, strutils]
import mynim/ui/editor as editor

let forward = editor.Selection(anchor: 2, head: 7)
doAssert forward.start() == 2 and forward.pastLast() == 7
doAssert not forward.empty()
let backward = editor.Selection(anchor: 7, head: 2)
doAssert backward.start() == 2 and backward.pastLast() == 7
doAssert not backward.empty()
let caret = editor.Selection(anchor: 4, head: 4)
doAssert caret.start() == 4 and caret.pastLast() == 4 and caret.empty()

let buffer = editor.newBuffer("a😀\r\nsecond\n")
doAssert $buffer == "a😀\nsecond\n"
doAssert buffer.len() == "a😀\nsecond\n".len
doAssert buffer.lineCount() == 3
doAssert buffer.line(0) == "a😀"
doAssert buffer.line(1) == "second"
doAssert buffer.line(2) == ""
doAssert buffer.lineEnding() == "\r\n"
doAssert buffer.pos(5) == editor.Pos(line: 0, column: 5)
doAssert buffer.pos(6) == editor.Pos(line: 1, column: 0)
doAssert buffer.offset(editor.Pos(line: 1, column: 100)) == 12
doAssert buffer.offset(editor.Pos(line: 0, column: 3)) == 1,
  "byte columns inside a UTF-8 rune should round down to its start"

let partialRune = editor.newBuffer("a😀b")
partialRune.edit(editor.Edit(start: 2, pastLast: 3, text: "x"))
doAssert $partialRune == "ax😀b",
  "a byte range inside one rune should round to a zero-width insertion"
partialRune.edit(editor.Edit(start: 2, pastLast: 6, text: "y"))
doAssert $partialRune == "axyb",
  "a byte range spanning the rest of a rune should replace the whole rune"

let large = editor.newBuffer(repeat("a", 4096) & "😀z")
doAssert large.pos(4098).column == 4096,
  "byte offsets should map correctly across rope chunks"
doAssert large.offset(editor.Pos(line: 0, column: 4098)) == 4096
large.edit(editor.Edit(start: 4096, pastLast: 4100, text: "Q"))
doAssert large.slice(4094, 4100) == "aaQz"

let original = buffer.snapshot()
doAssert original.slice(5, 1) == "",
  "a reversed slice should be empty"
buffer.edit(editor.Edit(start: 1, pastLast: 5, text: "x"))
doAssert $buffer == "ax\nsecond\n"
doAssert $original == "a😀\nsecond\n",
  "a snapshot should retain its text after a later edit"
doAssert buffer.modified()
doAssert buffer.canUndo() and not buffer.canRedo()
doAssert buffer.undo()
doAssert $buffer == "a😀\nsecond\n"
doAssert not buffer.modified(), "undo should return to the saved document root"
doAssert buffer.redo()
doAssert $buffer == "ax\nsecond\n"
doAssert buffer.modified()

var written = ""
let writtenBytes = original.writeTo(proc(chunk: string): int =
  let count = min(2, chunk.len)
  written.add(chunk[0 ..< count])
  count
)
doAssert writtenBytes == int64("a😀\r\nsecond\r\n".len)
doAssert written == "a😀\r\nsecond\r\n",
  "writeTo should preserve the selected line ending and retry short writes"
doAssertRaises IOError:
  discard original.writeTo(proc(chunk: string): int = 0)

let multiple = editor.newBuffer("abcdef")
multiple.edit(
  editor.Edit(start: 4, pastLast: 5, text: "E"),
  editor.Edit(start: 1, pastLast: 2, text: "B"))
doAssert $multiple == "aBcdEf"
doAssert multiple.undo()
doAssert $multiple == "abcdef",
  "a batch of non-overlapping edits should undo as one step"

let overlaps = editor.newBuffer("abcd")
overlaps.edit(
  editor.Edit(start: 0, pastLast: 3, text: "X"),
  editor.Edit(start: 1, pastLast: 4, text: "Y"))
doAssert $overlaps == "XY",
  "overlapping ranges should be clipped after the preceding edit"

let sameOffset = editor.newBuffer("abc")
sameOffset.edit(
  editor.Edit(start: 1, pastLast: 1, text: "A"),
  editor.Edit(start: 1, pastLast: 1, text: "B"))
doAssert $sameOffset == "aABbc",
  "same-offset insertions should keep their input order"

let transaction = editor.newBuffer("abc")
transaction.transact(proc() =
  transaction.edit(editor.Edit(start: 1, pastLast: 1, text: "x"))
  transaction.transact(proc() =
    transaction.edit(editor.Edit(start: 2, pastLast: 2, text: "y"))
  )
)
doAssert $transaction == "axybc"
doAssert transaction.undo()
doAssert $transaction == "abc",
  "nested transactions should commit as one undo step"
doAssert transaction.redo()
doAssert $transaction == "axybc"

transaction.markSaved()
doAssert not transaction.modified()
transaction.set("new\r\ntext")
doAssert $transaction == "new\ntext"
doAssert transaction.modified()
doAssert transaction.lineEnding() == "\n",
  "Set should preserve the buffer's selected line ending"
doAssert transaction.undo()
doAssert $transaction == "axybc"
doAssert transaction.redo()
doAssert $transaction == "new\ntext"
transaction.reset("loaded\r\nfile")
doAssert $transaction == "loaded\nfile"
doAssert transaction.lineEnding() == "\r\n"
doAssert not transaction.modified()
doAssert not transaction.canUndo() and not transaction.canRedo(),
  "Reset should establish a clean document without undo history"

let restoredText = editor.newBuffer("abc")
restoredText.edit(editor.Edit(start: 1, pastLast: 2, text: "x"))
restoredText.edit(editor.Edit(start: 1, pastLast: 2, text: "b"))
doAssert $restoredText == "abc"
doAssert not restoredText.modified(),
  "returning to saved content should clear the modified state"

echo "editor buffer tests passed"
