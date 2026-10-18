import std/[strutils, unittest]
import mynim/plugins/terminal/internal/vt/library

const validManifest = """
{"abi":{"pointer_size":8},"types":{
  "GhosttyString":{"kind":"struct","size":16,"fields":{
    "ptr":{"offset":0},"len":{"offset":8}}},
  "GhosttyCell":{"kind":"packed","size":8,"bits":{
    "content_tag":{"lsb":0,"width":2},
    "style_id":{"lsb":2,"width":16},
    "wide":{"lsb":18,"width":2},
    "hyperlink":{"lsb":20,"width":16},
    "content":{"lsb":36,"width":28,"arms":{
      "CODEPOINT":{"bits":{"codepoint":{"lsb":0,"width":21}}},
      "BG_COLOR_PALETTE":{"bits":{"index":{"lsb":0,"width":8}}},
      "BG_COLOR_RGB":{"bits":{
        "r":{"lsb":0,"width":8},"g":{"lsb":8,"width":8},
        "b":{"lsb":16,"width":8}}}}}}}}
}"""

suite "Ghostty ABI manifest":
  test "reads the checked layouts and packed-cell bit positions":
    let manifest = parseManifest(validManifest)
    check manifest.pointerSize == sizeof(pointer)
    check manifest.cell.contentTag.lsb == 0
    check manifest.cell.styleId.width == 16
    check manifest.cell.codepoint.lsb == 36
    check manifest.cell.paletteIndex.width == 8
    check manifest.cell.blue.lsb == 52

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

  test "rejects a packed-cell arm extending past its content field":
    let data = validManifest.replace("\"width\":28,\"arms\"",
      "\"width\":23,\"arms\"")
    expect ValueError:
      discard parseManifest(data)
