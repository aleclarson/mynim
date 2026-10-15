import std/assertions

import mynim/ui

block constructors_and_formatting:
  doAssert rgb(18, 52, 86) == Color(r: 18, g: 52, b: 86, a: 255)
  doAssert rgba(18, 52, 86, 0.5).a == 128
  doAssert $hexColor("#123456") == "#123456"
  doAssert $hexColor("#12345680") == "#12345680"
  doAssert $transparent == "#00000000"

block hex_and_css_parsing:
  doAssert hexColor("abc") == rgb(170, 187, 204)
  doAssert parseColor("#abcd") == Color(r: 170, g: 187, b: 204, a: 221)
  doAssert parseColor("rgb(12, 34, 56)") == rgb(12, 34, 56)
  doAssertRaises ValueError:
    discard hexColor("not-a-color")

block alpha_mix_and_over:
  let red = rgba(255, 0, 0, 0.5)
  doAssert red.alpha(0).a == 0
  doAssert red.alpha(2).a == 255
  doAssert red.mix(rgb(0, 0, 255), 0) == red
  doAssert red.mix(rgb(0, 0, 255), 1) == rgb(0, 0, 255)
  doAssert red.over(rgb(255, 255, 255)) == rgb(255, 127, 127)

block oklch_and_wide_gamut:
  let green = oklch(0.85, 0.3, 145)
  doAssert green.a == 255
  doAssert green.g > green.r and green.g > green.b
  doAssert green != green.srgb()
  doAssert green.alpha(0.5).srgb() == green.srgb().alpha(0.5)

  let gray = oklch(0.6, 0, 0)
  doAssert gray.srgb().r == gray.g and gray.g == gray.b
  doAssert oklch(1, 0.2, 30) == rgb(255, 255, 255)

  let inside = green.mix(rgb(255, 255, 255), 0.5)
  doAssert inside == inside.srgb()
  doAssert green.mix(rgb(255, 255, 255), 0) == green
  doAssert oklch(NaN.float32, 0.3, 145) == rgb(0, 0, 0)
  doAssert oklch(0.5, Inf.float32, 30) != oklch(0.5, Inf.float32, 30).srgb()
  doAssert oklch(0.5, 0.2, Inf.float32).a == 255
  doAssert oklch(0.7, -0.1, 30).srgb().r ==
    oklch(0.7, -0.1, 30).srgb().g
