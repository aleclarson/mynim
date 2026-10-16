## Package ui builds native, GPU-rendered user interfaces.

import std/[algorithm, math, monotimes, parseutils, sequtils, sets, strutils,
            tables, times, unicode]
import std/uri as uri
import mynim/internal/gamut
import mynim/internal/scene as scene
import mynim/internal/platform
import mynim/internal/surface
import mynim/internal/raster as raster
import mynim/transfer as transfer
import mynim/internal/text as textStack
import mynim/i18n as i18n
import mynim/internal/l10n as l10n
from mynim/internal/ucd import lookupGeneralCategory, Ll, Lm, Lo, Lt, Lu, Nd
import mynim/internal/svg as svgRenderer
import mynim/image as sourceImage
export platform.TextInputClient, platform.TextRange, platform.TextSelection,
  platform.RectF, platform.TitleBar, platform.Preferences, platform.Cursor,
  platform.Key, platform.Modifiers, i18n.Region
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
include mynim/ui/router
include mynim/ui/context
include mynim/ui/rich_text
include mynim/ui/list_state
include mynim/ui/menu
include mynim/ui/layout
include mynim/ui/text_buffer
include mynim/ui/paragraph_heights
include mynim/ui/text_input
include mynim/ui/direction
include mynim/ui/list
include mynim/ui/gridview
include mynim/ui/paint
include mynim/ui/editable_text
include mynim/ui/widgets
include mynim/ui/toolbar
include mynim/ui/collapsible
include mynim/ui/meter
include mynim/ui/progress
include mynim/ui/rating
include mynim/ui/stepper
include mynim/ui/number_input
include mynim/ui/split
include mynim/ui/spinner
include mynim/ui/avatar
include mynim/ui/badge
include mynim/ui/range_slider
include mynim/ui/tabs
include mynim/ui/table
include mynim/ui/outline
include mynim/ui/tree
include mynim/ui/sidebar
include mynim/ui/form
include mynim/ui/breadcrumb
include mynim/ui/search_field
include mynim/ui/tooltip
include mynim/ui/overlay
include mynim/ui/popover
include mynim/ui/date
include mynim/ui/time_input
include mynim/ui/color_picker
include mynim/ui/dialog
include mynim/ui/combobox
include mynim/ui/toast
include mynim/ui/findbar
include mynim/ui/drop
include mynim/ui/drag
include mynim/ui/router_view
include mynim/ui/runtime
include mynim/ui/tester
