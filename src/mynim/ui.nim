## Package ui builds native, GPU-rendered user interfaces.

import std/[algorithm, math, monotimes, parseutils, sequtils, sets, strutils,
            tables, times, unicode]
import mynim/internal/gamut
import mynim/internal/scene as scene
import mynim/internal/platform
import mynim/internal/surface
import mynim/internal/raster as raster
import mynim/internal/text as textStack
import mynim/internal/svg as svgRenderer
import mynim/image as sourceImage
export platform.TextInputClient, platform.TextRange, platform.TextSelection,
  platform.RectF
when defined(macosx):
  import mynim/internal/gpu/metal as metalGpu
elif defined(windows):
  import mynim/internal/gpu/d3d11/renderer as d3d11Gpu
elif (defined(linux) and (defined(amd64) or defined(arm64))) or
    defined(emscripten):
  import mynim/internal/gpu/gl as glGpu

include mynim/ui/color
include mynim/ui/theme
include mynim/ui/element
include mynim/ui/context
include mynim/ui/list_state
include mynim/ui/layout
include mynim/ui/direction
include mynim/ui/list
include mynim/ui/paint
include mynim/ui/table
include mynim/ui/runtime
