import std/[os, unittest]
import mynim/plugins/terminal/internal/vt/[effects, library, terminal]

type EffectProbe = object
  replies: string
  bells, titles, pwds, resets: int
  renderHolds: seq[bool]

proc onWritePty(rawTerminal, userdata: pointer;
                data: ptr UncheckedArray[byte]; length: csize_t) {.cdecl.} =
  discard rawTerminal
  let probe = cast[ptr EffectProbe](userdata)
  probe.replies.setLen(int(length))
  if length > 0:
    copyMem(addr probe.replies[0], data, int(length))

proc onBell(rawTerminal, userdata: pointer) {.cdecl.} =
  discard rawTerminal
  inc cast[ptr EffectProbe](userdata).bells

proc onTitleChanged(rawTerminal, userdata: pointer) {.cdecl.} =
  discard rawTerminal
  inc cast[ptr EffectProbe](userdata).titles

proc onPwdChanged(rawTerminal, userdata: pointer) {.cdecl.} =
  discard rawTerminal
  inc cast[ptr EffectProbe](userdata).pwds

proc onRenderHold(rawTerminal, userdata: pointer; held: bool) {.cdecl.} =
  discard rawTerminal
  cast[ptr EffectProbe](userdata).renderHolds.add(held)

proc onReset(rawTerminal, userdata: pointer) {.cdecl.} =
  discard rawTerminal
  inc cast[ptr EffectProbe](userdata).resets

proc onClipboardReadDenied(rawTerminal, userdata, request: pointer) {.cdecl.} =
  discard rawTerminal
  discard userdata
  discard request

proc callbacks(): TerminalCallbacks =
  TerminalCallbacks(
    writePty: onWritePty,
    bell: onBell,
    titleChanged: onTitleChanged,
    pwdChanged: onPwdChanged,
    renderHold: onRenderHold,
    reset: onReset,
    clipboardRead: onClipboardReadDenied)

suite "Ghostty terminal effects":
  test "closed terminals reject callback registration":
    let terminal: GhosttyTerminal = nil
    expect IOError:
      terminal.setCallbacks(nil, callbacks())
    expect IOError:
      terminal.clearCallbacks()

  test "dispatches terminal replies and effect callbacks synchronously":
    let path = getEnv("MYNIM_GHOSTTY_VT")
    if path.len == 0:
      skip()
    let library = openGhosttyVT(path)
    defer: library.close()
    let terminal = newGhosttyTerminal(library, 80, 24)
    defer: terminal.close()
    var probe: EffectProbe
    terminal.setCallbacks(cast[pointer](addr probe), callbacks())

    terminal.write("\x1b[5n\x07\x1b]2;Mynim\a" &
      "\x1b]7;file:///tmp/mynim\a\x1b[?2026h\x1b[?2026l")
    check probe.replies == "\x1b[0n"
    check probe.bells == 1
    check probe.titles == 1
    check probe.pwds == 1
    check probe.renderHolds == @[true, false]
    check terminal.title() == "Mynim"
    check terminal.pwd() == "file:///tmp/mynim"

    terminal.write("\x1b]52;c;?\x1b\\")
    check probe.replies == "\x1b]52;c;\x1b\\"

    terminal.write("\x1bc")
    check probe.resets == 1
    check terminal.title() == ""
    check terminal.pwd() == ""

    terminal.clearCallbacks()
    terminal.write("\x07")
    check probe.bells == 1
