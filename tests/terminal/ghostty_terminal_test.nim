import std/[os, unittest]
import mynim/plugins/terminal/internal/vt/[library, terminal]

suite "Ghostty terminal state":
  test "validates the library and dimensions before construction":
    expect ValueError:
      discard newGhosttyTerminal(nil, 80, 24)
    expect ValueError:
      discard newGhosttyTerminal(nil, 0, 24)

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
    terminal.write("hello\e[2;4H")
    check terminal.cursor() == (x: 3, y: 1)

    terminal.resize(100, 30, 9, 16)
    check terminal.size() == (cols: 100, rows: 30)
    terminal.reset()
    check terminal.size() == (cols: 100, rows: 30)
    check terminal.cursor() == (x: 0, y: 0)

    terminal.close()
    expect IOError:
      discard terminal.size()
