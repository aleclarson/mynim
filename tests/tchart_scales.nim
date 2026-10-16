import std/[assertions, strutils]
import mynim/ui/chart

proc tickValues(ticks: seq[Tick]): seq[float64] =
  for tick in ticks:
    result.add tick.value

proc tickLabels(ticks: seq[Tick]): string =
  var labels: seq[string]
  for tick in ticks:
    labels.add tick.label
  labels.join(" ")

for (lo, hi, count, expected) in [
  (0.0, 1.0, 10, @[0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]),
  (0.0, 100.0, 5, @[0.0, 20.0, 40.0, 60.0, 80.0, 100.0]),
  (0.0, 87.0, 5, @[0.0, 20.0, 40.0, 60.0, 80.0]),
  (-3.2, 7.9, 6, @[-2.0, 0.0, 2.0, 4.0, 6.0]),
  (0.0012, 0.0047, 5, @[0.0015, 0.002, 0.0025, 0.003, 0.0035, 0.004, 0.0045]),
  (1e6, 3.4e6, 4, @[1e6, 1.5e6, 2e6, 2.5e6, 3e6]),
  (10.0, 0.0, 5, @[10.0, 8.0, 6.0, 4.0, 2.0, 0.0]),
  (0.1, 0.9, 3, @[0.2, 0.4, 0.6, 0.8]),
  (1.0, 1.0, 5, @[1.0]),
  (0.0, 1.0, 1, @[0.0, 1.0])
]:
  doAssert tickValues(newLinear(lo, hi).ticks(count)) == expected

for (lo, hi, count, expected) in [
  (0.0, 87.0, 5, (0.0, 100.0)),
  (0.0, 87.0, 10, (0.0, 90.0)),
  (0.0, 87.0, 2, (0.0, 100.0)),
  (-3.2, 7.9, 6, (-4.0, 8.0)),
  (0.0012, 0.0047, 5, (0.001, 0.005)),
  (13.0, 1042.0, 10, (0.0, 1100.0)),
  (90.0, 3.0, 5, (100.0, 0.0))
]:
  let scale = newLinear(lo, hi).nice(count)
  doAssert (scale.lo, scale.hi) == expected

doAssert newLinear(0, 1).ticks(5).tickLabels == "0.0 0.2 0.4 0.6 0.8 1.0"
doAssert newLinear(0, 100).ticks(5).tickLabels == "0 20 40 60 80 100"
doAssert newLinear(0.0012, 0.0047).ticks(5).tickLabels ==
  "0.0015 0.0020 0.0025 0.0030 0.0035 0.0040 0.0045"
doAssert newLinear(-1, 1).ticks(4).tickLabels == "-1.0 -0.5 0.0 0.5 1.0"
doAssert newLinear(0, 1).ticks(0).len == 0

let line = newLinear(-10, 30)
doAssert line.at(0) == 0.25
doAssert line.invert(0.75) == 20
doAssert line.span(0, 10) == Span(lo: 0.25, hi: 0.5)
var clamped = line
clamped.clamp = true
doAssert clamped.at(50) == 1
doAssert clamped.invert(-1) == -10
doAssert newLinear(3, 3).at(3) == 0.5
doAssert extent(4.0, NaN, -2.0, 9.0) == (lo: -2.0, hi: 9.0)
doAssert extent().lo == 0 and extent().hi == 1

let bandScale = newBand("a", "b", "c", "d").padding(0.2, 0.1)
let expectedStarts = [0.025'f32, 0.275'f32, 0.525'f32, 0.775'f32]
for i, expected in expectedStarts:
  doAssert abs(bandScale.band(i).lo - expected) < 1e-6
doAssert abs(bandScale.width - 0.2'f32) < 1e-6
for (fraction, expectedIndex, expectedOk) in [
  (0.01'f32, 0, true), (0.1'f32, 0, true), (0.249'f32, 0, true),
  (0.251'f32, 1, true), (0.99'f32, 3, true), (-0.01'f32, 0, false),
  (1.01'f32, 0, false)
]:
  let (index, ok) = bandScale.index(fraction)
  doAssert index == expectedIndex and ok == expectedOk
let bandTicks = bandScale.ticks
doAssert bandTicks.len == 4 and bandTicks[2].label == "c"
doAssert bandTicks[2].at == bandScale.at(2)
doAssert newBand().index(0.5'f32).ok == false

echo "chart scale tests passed"
