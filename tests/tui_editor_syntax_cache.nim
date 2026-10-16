import std/assertions

include "../src/mynim/ui/editor.nim"

var tokenizerCalls = 0
let countingLanguage = syntax.Language(name: "Counting",
  tokenizer: proc(line: string; state: uint64;
                  tokens: var seq[syntax.Token]): uint64 =
    inc tokenizerCalls
    if line.len > 0:
      tokens.add(syntax.Token(pastLast: line.len, kind: syntax.tokenText))
    if state != 0:
      if line.contains("*/"): 0'u64 else: 1'u64
    elif line.contains("/*"):
      1'u64
    else:
      0'u64)

proc verifyStates(state: State; language: syntax.Language;
                  snapshot: Snapshot; upTo: int) =
  var expected = 0'u64
  var scratch: seq[syntax.Token]
  for i in 0 .. upTo:
    doAssert state.syntaxStates[i] == expected
    scratch.setLen(0)
    expected = language.tokenizer(snapshot.line(i), expected, scratch)

var lines: seq[string]
for i in 0 ..< 300:
  lines.add("line " & $i)
lines[50] = "close */"

let state = newState(lines.join("\n"))
state.buffer.setLanguage(countingLanguage)
var textSnapshot = state.buffer.snapshot()
discard state.cachedTokens(textSnapshot, countingLanguage, 250)
doAssert tokenizerCalls == 251
state.verifyStates(countingLanguage, textSnapshot, 250)

let bufferSnapshot = state.buffer.snapshot()
let editStart = bufferSnapshot.offset(Pos(line: 20, column: 0))
let editEnd = bufferSnapshot.offset(Pos(line: 20,
  column: bufferSnapshot.line(20).len))
state.buffer.edit(Edit(start: editStart, pastLast: editEnd, text: "/* open"))
tokenizerCalls = 0
textSnapshot = state.buffer.snapshot()
discard state.cachedTokens(textSnapshot, countingLanguage, 250)
doAssert tokenizerCalls == 32
state.verifyStates(countingLanguage, textSnapshot, 250)

let insertAt = state.buffer.offset(Pos(line: 2, column: 0))
state.buffer.edit(Edit(start: insertAt, pastLast: insertAt, text: "new\n"))
tokenizerCalls = 0
textSnapshot = state.buffer.snapshot()
discard state.cachedTokens(textSnapshot, countingLanguage, 250)
doAssert tokenizerCalls == 251
state.verifyStates(countingLanguage, textSnapshot, 250)
