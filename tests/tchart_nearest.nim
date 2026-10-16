import std/assertions
import mynim/ui/chart

let values = [0'f32, 0.25'f32, 0.5'f32, 1'f32]
for (value, expected) in [
  (-1'f32, 0), (0.1'f32, 0), (0.125'f32, 0), (0.2'f32, 1),
  (0.4'f32, 2), (0.8'f32, 3), (2'f32, 3)
]:
  doAssert nearest(values, value) == expected
doAssert nearest([], 0.5'f32) == -1

echo "chart nearest tests passed"
