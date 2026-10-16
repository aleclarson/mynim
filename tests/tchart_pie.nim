import std/[assertions, math]
import mynim/ui/chart

let expected = [
  (0.0, 0.6383185307179586),
  (0.6383185307179586, 1.8949555921538759),
  (1.8949555921538759, 3.7699111843077517),
  (3.7699111843077517, 3.7899111843077518),
  (3.7899111843077518, 2 * PI)
]
let slices = pie([1.0, 2.0, 3.0, 0.0, 4.0], 0.02)
doAssert slices.len == expected.len
for i, slice in slices:
  doAssert abs(slice.start - expected[i][0]) < 1e-12
  doAssert abs(slice.`end` - expected[i][1]) < 1e-12

let equalSlices = pie([1.0, 1.0, 1.0, 1.0], 0)
for (x, y, expectedIndex) in [
  (1'f32, -10'f32, 0), (10'f32, 1'f32, 1),
  (-1'f32, 10'f32, 2), (-10'f32, -1'f32, 3)
]:
  let (index, ok) = sliceAt(equalSlices, x, y, 5, 20)
  doAssert ok and index == expectedIndex
doAssert not sliceAt(equalSlices, 1, 1, 5, 20).ok

let (px, py) = polar(0, 0, 10, PI / 2)
doAssert abs(px - 10'f32) < 1e-5 and abs(py) < 1e-5
doAssert abs(slices[0].mid - (slices[0].start + slices[0].`end`) / 2) < 1e-12

echo "chart pie tests passed"
