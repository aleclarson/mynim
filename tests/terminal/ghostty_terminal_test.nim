import std/[options, os, unittest]
import mynim/plugins/terminal/internal/vt/[library, render, terminal]

suite "Ghostty terminal state":
  test "validates the library and dimensions before construction":
    expect ValueError:
      discard newGhosttyTerminal(nil, 80, 24)
    expect ValueError:
      discard newGhosttyTerminal(nil, 0, 24)

  test "reports nil handles as closed":
    let terminal: GhosttyTerminal = nil
    let renderState: GhosttyRenderState = nil
    expect IOError:
      discard terminal.size()
    expect IOError:
      discard renderState.size()

  test "creates, writes, resizes, resets and closes a terminal":
    let path = getEnv("MYNIM_GHOSTTY_VT")
    if path.len == 0:
      skip()
    let library = openGhosttyVT(path)
    defer: library.close()
    let terminal = newGhosttyTerminal(library, 80, 24)
    defer: terminal.close()

    check terminal.size() == (cols: 80, rows: 24)
    check terminal.cursor() == (x: 0, y: 0)
    terminal.setTerminfoName("xterm-256color")
    terminal.setScrollbackMaxBytes(1024 * 1024)
    check terminal.scrollbackMaxBytes() == 1024 * 1024'u64
    terminal.setDefaultCursor(cursorStyleUnderline, blink = false)
    terminal.setModeDefault(modeGraphemes, true)
    check terminal.mode(modeGraphemes)
    terminal.setMode(modeFocusEvent, true)
    check terminal.mode(modeFocusEvent)
    terminal.setMode(modeFocusEvent, false)
    check not terminal.mode(modeFocusEvent)
    terminal.setResizePullScrollback(false)
    var palette: TerminalPalette
    palette[42] = TerminalColor(r: 8, g: 9, b: 10)
    terminal.setColors(
      foreground = TerminalColor(r: 11, g: 12, b: 13),
      background = TerminalColor(r: 21, g: 22, b: 23),
      cursor = some(TerminalColor(r: 31, g: 32, b: 33)),
      palette = some(palette))
    check uint16(ansiMode(20)) == 0x8014'u16
    expect ValueError:
      terminal.setScrollbackMaxBytes(-1)
    expect ValueError:
      discard ansiMode(0x8000)

    terminal.write("hello\e[1;6He\u0301\e[1mB\e[0m" &
      "\e[38;5;123mP\e[0m\e[38;2;1;2;3mR\e[0m\e[2;4H")
    check terminal.cursor() == (x: 3, y: 1)

    terminal.resize(100, 30, 9, 16)
    check terminal.size() == (cols: 100, rows: 30)

    let renderState = newGhosttyRenderState(library)
    defer: renderState.close()
    renderState.update(terminal)
    check renderState.size() == (cols: 100, rows: 30)
    check renderState.dirty() != renderClean
    let frameCursor = renderState.cursor()
    check frameCursor.inView
    check (frameCursor.x, frameCursor.y) == (3, 1)
    check frameCursor.visible
    let frameColors = renderState.colors()
    check frameColors.foreground == RGB(r: 11, g: 12, b: 13)
    check frameColors.background == RGB(r: 21, g: 22, b: 23)
    check frameColors.hasCursor
    check frameColors.cursor == RGB(r: 31, g: 32, b: 33)
    check frameColors.palette[42] == RGB(r: 8, g: 9, b: 10)

    renderState.rows()
    var rowCount = 0
    var firstRow: seq[RenderCell]
    while renderState.nextRow():
      let y = renderState.rowViewportY()
      let cells = renderState.rowCells()
      check cells.len == 100
      if y == 0:
        firstRow = cells
        check renderState.rowDirty()
        check cells[0].codepoint == uint32(ord('h'))
        check cells[1].codepoint == uint32(ord('e'))
        check cells[4].codepoint == uint32(ord('o'))
        check cells[5].codepoint == uint32(ord('e'))
        check cells[5].grapheme
        check cells[6].codepoint == uint32(ord('B'))
        check cells[7].codepoint == uint32(ord('P'))
        check cells[8].codepoint == uint32(ord('R'))
        check cells[0].wide == cellNarrow
        check cells[6].styleId != 0
        check renderState.cellGraphemes(5) ==
          @[uint32(ord('e')), 0x301'u32]
        check renderState.cellStyle(6).bold
        let paletteStyle = renderState.cellStyle(7)
        check paletteStyle.foreground.kind == renderColorPalette
        check paletteStyle.foreground.paletteIndex == 123
        let rgbStyle = renderState.cellStyle(8)
        check rgbStyle.foreground.kind == renderColorRgb
        check rgbStyle.foreground.rgb == RGB(r: 1, g: 2, b: 3)
        check renderState.rowSelection().isNone
        discard renderState.rowId()
      inc rowCount
    check rowCount == 30

    renderState.clean()
    check renderState.dirty() == renderClean

    terminal.reset()
    check terminal.size() == (cols: 100, rows: 30)
    check terminal.cursor() == (x: 0, y: 0)
    check terminal.mode(modeGraphemes)
    renderState.update(terminal)
    check renderState.dirty() != renderClean
    check (renderState.cursor().x, renderState.cursor().y) == (0, 0)
    check firstRow[0].codepoint == uint32(ord('h'))

    renderState.close()
    terminal.close()
    expect IOError:
      discard renderState.size()
    expect IOError:
      discard terminal.size()
