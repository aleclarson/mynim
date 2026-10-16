import std/assertions
import mynim/ui/paragraph_heights

var index: ParagraphHeightIndex
index.reset([0'f32, 10, 0, 20])
index.setEstimate(5)

doAssert index.len() == 4
doAssert index.estimate() == 5
doAssert index.totals() == ParagraphHeightTotals(measured: 30, unknown: 2)
doAssert index.top(0) == 0
doAssert index.top(1) == 5
doAssert index.top(2) == 15
doAssert index.top(3) == 20
doAssert index.top(100) == 40
doAssert index.at(-1) == 0
doAssert index.at(4.9) == 0
doAssert index.at(5) == 1
doAssert index.at(15) == 2
doAssert index.at(20) == 3
doAssert index.at(100) == 3

index.add(2, 8, -1)
doAssert index.top(3) == 23
doAssert index.totals() == ParagraphHeightTotals(measured: 38, unknown: 1)
doAssert index.at(23) == 3

index.setEstimate(7)
doAssert index.top(1) == 7
doAssert index.top(3) == 25

index.reset([])
doAssert index.len() == 0
doAssert index.top(0) == 0
doAssert index.at(0) == 0
doAssert index.totals() == ParagraphHeightTotals()
