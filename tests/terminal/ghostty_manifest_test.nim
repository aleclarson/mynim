import std/[strutils, unittest]
import mynim/plugins/terminal/internal/vt/library

const validManifest = """
{"abi":{"pointer_size":8},"types":{
  "GhosttyString":{"kind":"struct","size":16,"fields":{
    "ptr":{"offset":0},"len":{"offset":8}}},
  "GhosttyColorRgb":{"kind":"struct","size":3,"fields":{
    "r":{"offset":0},"g":{"offset":1},"b":{"offset":2}}},
  "GhosttyStyleColor":{"kind":"struct","size":16,"fields":{
    "tag":{"offset":0},"value":{"offset":8}}},
  "GhosttyStyle":{"kind":"struct","size":72,"fields":{
    "size":{"offset":0},"fg_color":{"offset":8},
    "bg_color":{"offset":24},"underline_color":{"offset":40},
    "bold":{"offset":56},"italic":{"offset":57},"faint":{"offset":58},
    "blink":{"offset":59},"inverse":{"offset":60},
    "invisible":{"offset":61},"strikethrough":{"offset":62},
    "overline":{"offset":63},"underline":{"offset":64}}},
  "GhosttyRenderStateCursor":{"kind":"struct","size":24,"fields":{
    "size":{"offset":0},"viewport_has_value":{"offset":8},
    "viewport_x":{"offset":10},"viewport_y":{"offset":12},
    "wide_tail":{"offset":14},"visible":{"offset":15},
    "blinking":{"offset":16},"password_input":{"offset":17},
    "visual_style":{"offset":20}}},
  "GhosttyRenderStateColors":{"kind":"struct","size":792,"fields":{
    "size":{"offset":0},"background":{"offset":8},
    "foreground":{"offset":11},"cursor":{"offset":14},
    "cursor_has_value":{"offset":17},"palette":{"offset":18}}},
  "GhosttyRenderStateRowSelection":{"kind":"struct","size":16,"fields":{
    "size":{"offset":0},"start_x":{"offset":8},"end_x":{"offset":10}}},
  "GhosttyRenderStateRowId":{"kind":"struct","size":16,"fields":{
    "bits":{"offset":0}}},
  "GhosttyCellsView":{"kind":"struct","size":16,"fields":{
    "ptr":{"offset":0},"len":{"offset":8}}},
  "GhosttyCell":{"kind":"packed","size":8,"bits":{
    "content_tag":{"lsb":0,"width":2},
    "style_id":{"lsb":26,"width":16},
    "wide":{"lsb":42,"width":2},
    "hyperlink":{"lsb":45,"width":1},
    "content":{"lsb":2,"width":24,"arms":{
      "CODEPOINT":{"bits":{"codepoint":{"lsb":0,"width":21}}},
      "BG_COLOR_PALETTE":{"bits":{"index":{"lsb":0,"width":8}}},
      "BG_COLOR_RGB":{"bits":{
        "r":{"lsb":0,"width":8},"g":{"lsb":8,"width":8},
        "b":{"lsb":16,"width":8}}}}}}},
  "GhosttyCellContentTag":{"kind":"enum","values":{
    "CODEPOINT":0,"CODEPOINT_GRAPHEME":1,
    "BG_COLOR_PALETTE":2,"BG_COLOR_RGB":3}},
  "GhosttyCellWide":{"kind":"enum","values":{
    "NARROW":0,"WIDE":1,"SPACER_TAIL":2,"SPACER_HEAD":3}},
  "GhosttyStyleColorTag":{"kind":"enum","values":{
    "NONE":0,"PALETTE":1,"RGB":2}}
}}"""

suite "Ghostty ABI manifest":
  test "reads the checked layouts and packed-cell bit positions":
    let manifest = parseManifest(validManifest)
    check manifest.pointerSize == sizeof(pointer)
    check manifest.cell.contentTag.lsb == 0
    check manifest.cell.styleId.width == 16
    check manifest.cell.codepoint.lsb == 2
    check manifest.cell.paletteIndex.width == 8
    check manifest.cell.blue.lsb == 18

  test "rejects another pointer width":
    let wrongWidth = if sizeof(pointer) == 8: 4 else: 8
    let data = validManifest.replace("\"pointer_size\":8",
      "\"pointer_size\":" & $wrongWidth)
    expect ValueError:
      discard parseManifest(data)

  test "rejects a changed string layout":
    let data = validManifest.replace("\"len\":{\"offset\":8}",
      "\"len\":{\"offset\":4}")
    expect ValueError:
      discard parseManifest(data)

  test "rejects changed render-state layouts":
    let data = validManifest.replace("\"viewport_x\":{\"offset\":10}",
      "\"viewport_x\":{\"offset\":8}")
    expect ValueError:
      discard parseManifest(data)

  test "rejects changed packed-cell tag values":
    let data = validManifest.replace("\"BG_COLOR_RGB\":3",
      "\"BG_COLOR_RGB\":4")
    expect ValueError:
      discard parseManifest(data)

  test "rejects a packed-cell arm extending past its content field":
    let data = validManifest.replace("\"width\":24,\"arms\"",
      "\"width\":18,\"arms\"")
    expect ValueError:
      discard parseManifest(data)
