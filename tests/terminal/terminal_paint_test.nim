import std/unittest
import mynim/ui as ui
import mynim/plugins/terminal/internal/view_paint
import mynim/plugins/terminal/internal/vt/terminal

suite "terminal view geometry":
  test "scrollbar thumb follows Ghostty's viewport offset":
    let bounds = ui.Rect(x: 0, y: 0, w: 200, h: 100)
    let top = scrollbarGeometry(bounds,
      TerminalScrollbar(total: 100, offset: 0, len: 20), 6, 6, 4)
    let bottom = scrollbarGeometry(bounds,
      TerminalScrollbar(total: 100, offset: 80, len: 20), 6, 6, 4)

    check bottom.maxOffset == 80
    check bottom.track.x == 188
    check bottom.track.y == 4
    check bottom.track.h == 92
    check bottom.thumb.y > top.thumb.y
    check top.thumb.y == top.track.y
    check top.scrollbarOffsetAt(top.thumb.y, 0) == 0
    check bottom.scrollbarOffsetAt(
      bottom.track.y + bottom.track.h - bottom.thumb.h, 0) == 80

  test "hides the thumb when all retained rows are visible":
    let geometry = scrollbarGeometry(ui.Rect(w: 200, h: 100),
      TerminalScrollbar(total: 24, offset: 0, len: 24), 6, 6, 4)

    check geometry.maxOffset == 0
    check geometry.thumb.w == 0
