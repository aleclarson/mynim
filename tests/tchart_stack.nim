import std/assertions
import mynim/ui/chart

let standard = stack(@[@[3.0, -1.0, 2.0], @[4.0, 2.0, -5.0], @[1.0, 1.0, 1.0]],
  stackStandard)
doAssert standard == @[
  @[Segment(lo: 0, hi: 3), Segment(lo: -1, hi: 0), Segment(lo: 0, hi: 2)],
  @[Segment(lo: 3, hi: 7), Segment(lo: 0, hi: 2), Segment(lo: -5, hi: 0)],
  @[Segment(lo: 7, hi: 8), Segment(lo: 2, hi: 3), Segment(lo: 2, hi: 3)]]

let positive = @[@[3.0, 1.0, 2.0], @[4.0, 2.0, 5.0], @[1.0, 1.0, 1.0]]
let normalized = stack(positive, stackNormalized)
doAssert normalized == @[
  @[Segment(lo: 0, hi: 0.375), Segment(lo: 0, hi: 0.25), Segment(lo: 0, hi: 0.25)],
  @[Segment(lo: 0.375, hi: 0.875), Segment(lo: 0.25, hi: 0.75), Segment(lo: 0.25, hi: 0.875)],
  @[Segment(lo: 0.875, hi: 1), Segment(lo: 0.75, hi: 1), Segment(lo: 0.875, hi: 1)]]
let centered = stack(positive, stackCenter)
doAssert centered == @[
  @[Segment(lo: -4, hi: -1), Segment(lo: -2, hi: -1), Segment(lo: -4, hi: -2)],
  @[Segment(lo: -1, hi: 3), Segment(lo: -1, hi: 1), Segment(lo: -2, hi: 3)],
  @[Segment(lo: 3, hi: 4), Segment(lo: 1, hi: 2), Segment(lo: 3, hi: 4)]]

let ragged = stack(@[@[1.0, NaN], @[2.0]], stackStandard)
doAssert ragged == @[
  @[Segment(lo: 0, hi: 1), Segment(lo: 0, hi: 0)],
  @[Segment(lo: 1, hi: 3), Segment(lo: 0, hi: 0)]]

echo "chart stack tests passed"
