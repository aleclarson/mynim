## Package ui builds native, GPU-rendered user interfaces.

import std/[algorithm, hashes, locks, math, monotimes, options, parseutils,
            sequtils, sets, strutils, tables, times, unicode]
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
export platform.modShift, platform.modCtrl, platform.modAlt, platform.modSuper
export platform.keyUnknown, platform.keyEnter, platform.keyEscape,
  platform.keyBackspace, platform.keyTab, platform.keySpace, platform.keyDelete,
  platform.keyInsert, platform.keyHome, platform.keyEnd, platform.keyPageUp,
  platform.keyPageDown, platform.keyLeft, platform.keyRight, platform.keyUp,
  platform.keyDown, platform.keyF1, platform.keyF2, platform.keyF3,
  platform.keyF4, platform.keyF5, platform.keyF6, platform.keyF7,
  platform.keyF8, platform.keyF9, platform.keyF10, platform.keyF11,
  platform.keyF12, platform.keyMinus, platform.keyEqual, platform.keyComma,
  platform.keyPeriod, platform.keySlash, platform.keySemicolon,
  platform.keyQuote, platform.keyBracketLeft, platform.keyBracketRight,
  platform.keyBackslash, platform.keyBackquote, platform.keyContextMenu,
  platform.key0, platform.key1, platform.key2, platform.key3, platform.key4,
  platform.key5, platform.key6, platform.key7, platform.key8, platform.key9,
  platform.keyA, platform.keyB, platform.keyC, platform.keyD, platform.keyE,
  platform.keyF, platform.keyG, platform.keyH, platform.keyI, platform.keyJ,
  platform.keyK, platform.keyL, platform.keyM, platform.keyN, platform.keyO,
  platform.keyP, platform.keyQ, platform.keyR, platform.keyS, platform.keyT,
  platform.keyU, platform.keyV, platform.keyW, platform.keyX, platform.keyY,
  platform.keyZ, platform.keyBack, platform.keyForward
when defined(macosx):
  import mynim/internal/gpu/metal as metalGpu
elif defined(windows):
  import mynim/internal/gpu/d3d11/renderer as d3d11Gpu
elif (defined(linux) and (defined(amd64) or defined(arm64))) or
    defined(emscripten):
  import mynim/internal/gpu/gl as glGpu

include mynim/ui/color
include mynim/ui/theme
include mynim/ui/selection
include mynim/ui/element
include mynim/ui/path
include mynim/ui/router
include mynim/ui/context
include mynim/ui/handler
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
include mynim/ui/draggable
include mynim/ui/drop
include mynim/ui/drag
include mynim/ui/router_view
include mynim/ui/runtime
include mynim/ui/tester
