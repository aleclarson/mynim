import std/[os, unittest]
import mynim/plugins/terminal/internal/vt/[input, library, terminal]

proc asString(data: openArray[byte]): string =
  result = newString(data.len)
  if data.len > 0:
    copyMem(addr result[0], unsafeAddr data[0], data.len)

suite "Ghostty keyboard and pointer encoders":
  test "validates library and closed handles":
    expect ValueError:
      discard newGhosttyKeyEncoder(nil)
    expect ValueError:
      discard newGhosttyMouseEncoder(nil)

    let keyEncoder: GhosttyKeyEncoder = nil
    let mouseEncoder: GhosttyMouseEncoder = nil
    expect IOError:
      discard keyEncoder.encode(KeyEvent(action: keyPress,
        key: keyArrowUp))
    expect IOError:
      discard mouseEncoder.encode(mousePress, buttonLeft, Mods(0), 0, 0)
    check (modCtrl or modAlt) == Mods(6)

  test "encodes terminal key and SGR mouse input":
    let path = getEnv("MYNIM_GHOSTTY_VT")
    if path.len == 0:
      skip()
    let library = openGhosttyVT(path)
    defer: library.close()
    let terminal = newGhosttyTerminal(library, 80, 24)
    defer: terminal.close()
    let keyEncoder = newGhosttyKeyEncoder(library)
    defer: keyEncoder.close()
    let mouseEncoder = newGhosttyMouseEncoder(library)
    defer: mouseEncoder.close()

    keyEncoder.sync(terminal)
    check keyEncoder.encode(KeyEvent(action: keyPress,
      key: keyArrowUp)).asString() == "\x1b[A"
    check keyEncoder.encode(KeyEvent(action: keyPress,
      key: keyA, mods: modCtrl, text: "a", unshifted: uint32(ord('a')))).
      asString() == "\x01"
    terminal.write("\x1b[?1h")
    keyEncoder.sync(terminal)
    check keyEncoder.encode(KeyEvent(action: keyPress,
      key: keyArrowUp)).asString() == "\x1bOA"
    terminal.write("\x1b[?1l")

    terminal.write("\x1b[?1000h\x1b[?1006h")
    mouseEncoder.sync(terminal, width = 800, height = 480,
      cellWidth = 10, cellHeight = 20, padLeft = 0, padTop = 0,
      pressed = false)
    check mouseEncoder.encode(mousePress, buttonLeft, Mods(0), 20, 40).
      asString() == "\x1b[<0;3;3M"
    check mouseEncoder.encode(mouseRelease, buttonLeft, Mods(0), 20, 40).
      asString() == "\x1b[<0;3;3m"

    mouseEncoder.sync(terminal, width = 0, height = 0,
      cellWidth = 0, cellHeight = 0, padLeft = -4, padTop = -9,
      pressed = false)
    expect ValueError:
      mouseEncoder.sync(terminal, width = high(int), height = 10,
        cellWidth = 1, cellHeight = 1, padLeft = 0, padTop = 0,
        pressed = false)
