import std/unittest
import mynim/plugins/terminal/internal/vt/encode
import mynim/plugins/terminal/internal/vt/library

suite "Ghostty paste helper edge cases":
  test "empty paste operations need no native call":
    let library: GhosttyVT = nil
    check library.encodePaste("", bracketed = false).len == 0
    check library.encodePaste("", bracketed = true).len == 0
    check library.pasteIsSafe("")

when defined(mynimGhosttyIntegration):
  import std/os

  proc asString(data: openArray[byte]): string =
    result = newString(data.len)
    if data.len > 0:
      copyMem(addr result[0], unsafeAddr data[0], data.len)

  suite "Ghostty native encoders":
    test "matches focus, paste, and safety behavior":
      let path = getEnv("MYNIM_GHOSTTY_VT")
      if path.len == 0:
        raise newException(ValueError,
          "set MYNIM_GHOSTTY_VT to run this integration test")
      let library = openGhosttyVT(path)
      defer: library.close()

      check library.encodeFocus(true).asString() == "\x1b[I"
      check library.encodeFocus(false).asString() == "\x1b[O"
      check library.encodePaste("a\nb", bracketed = false).asString() == "a\rb"
      check library.encodePaste("a\nb", bracketed = true).asString() ==
        "\x1b[200~a\nb\x1b[201~"
      check library.pasteIsSafe("ls")
      check not library.pasteIsSafe("rm -rf /\n")
