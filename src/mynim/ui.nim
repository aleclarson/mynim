## Package ui builds native, GPU-rendered user interfaces.

import std/[math, parseutils, sequtils, strutils]
import mynim/internal/gamut
import mynim/internal/scene as scene
import mynim/internal/platform
import mynim/internal/surface
import mynim/internal/raster as raster
when defined(macosx):
  import mynim/internal/gpu/metal as metalGpu
elif (defined(linux) and (defined(amd64) or defined(arm64))) or
    defined(emscripten):
  import mynim/internal/gpu/gl as glGpu

include mynim/ui/color
include mynim/ui/element
include mynim/ui/context
include mynim/ui/layout
include mynim/ui/paint
include mynim/ui/runtime
