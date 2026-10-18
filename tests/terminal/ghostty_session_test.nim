import std/[options, os, sequtils, strutils, unittest]
import mynim/plugins/terminal/internal/[pty, session]
import mynim/plugins/terminal/internal/vt/[frame, library]

proc text(frame: TerminalFrame): string =
  for row in frame.viewport:
    for cell in row.cells:
      for codepoint in cell.codepoints:
        if codepoint > 0 and codepoint < 128:
          result.add char(codepoint)
    result.add '\n'

suite "Ghostty PTY terminal session":
  test "connects process output, input, effects, and owned frames":
    let path = getEnv("MYNIM_GHOSTTY_VT")
    if path.len == 0:
      skip()
    let library = openGhosttyVT(path)
    defer: library.close()
    let script = "printf '\\033]2;Session title\\007" &
      "\\033]7;file:///tmp/session\\007\\007ready\\n'; " &
      "IFS= read -r value; stty -icanon -echo min 1 time 0; " &
      "printf '\\033[5n'; " &
      "response=$(dd bs=1 count=4 2>/dev/null | od -An -tx1); " &
      "stty icanon echo; printf 'got:%s reply:%s\\n' \"$value\" " &
      "\"$response\"; printf '\\033[?2026hSYNC'; " &
      "sleep 0.02; printf '\\033[?2026l'; exit 7"
    let session = newTerminalSession(library,
      PtyOptions(path: "/bin/sh", args: @["/bin/sh", "-c", script]),
      cols = 80, rows = 24)
    defer: session.close()

    check session.size() == (cols: 80, rows: 24)
    var ready = false
    for _ in 0 ..< 500:
      if text(session.snapshot()).contains("ready"):
        ready = true
        break
      sleep(10)
    if not ready:
      let failure = session.failure()
      session.close()
      checkpoint("terminal did not print ready; session failure: " & failure)
    check ready
    if ready:
      session.send("mynim-session-input\n")
      var exited = false
      for _ in 0 ..< 500:
        if session.processExitCode().isSome:
          exited = true
          break
        sleep(10)
      if not exited:
        let failure = session.failure()
        session.close()
        checkpoint("terminal process did not exit; session failure: " & failure)
      check exited
      if exited:
        check session.waitForExit() == 7

        let frame = session.snapshot()
        let contents = text(frame)
        let normalized = contents.splitWhitespace().join(" ")
        check contents.contains("ready")
        check contents.contains("got:mynim-session-input")
        check normalized.contains("reply: 1b 5b 30 6e")
        check contents.contains("SYNC")
        let events = session.takeEvents()
        check events.anyIt(it.kind == terminalTitleChanged and
          it.title == "Session title")
        check events.anyIt(it.kind == terminalPwdChanged and
          it.pwd == "file:///tmp/session")
        check events.anyIt(it.kind == terminalBell)
        check events.anyIt(it.kind == terminalRenderHoldChanged and it.held)
        check events.anyIt(it.kind == terminalRenderHoldChanged and not it.held)
        check events.anyIt(it.kind == terminalProcessExited and it.exitCode == 7)
        check session.processExitCode().get() == 7
        check session.failure().len == 0

  test "serializes resize and close with frame access":
    let path = getEnv("MYNIM_GHOSTTY_VT")
    if path.len == 0:
      skip()
    let library = openGhosttyVT(path)
    defer: library.close()
    let session = newTerminalSession(library,
      PtyOptions(path: "/bin/sh", args: @["/bin/sh", "-c", "sleep 10"]),
      cols = 80, rows = 24)
    session.resize(100, 30, cellWidth = 9, cellHeight = 18)
    check session.size() == (cols: 100, rows: 30)
    check session.snapshot().cols == 100
    session.close()
    expect IOError:
      discard session.snapshot()
