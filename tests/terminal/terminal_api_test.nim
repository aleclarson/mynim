import std/[options, os, unittest]
import mynim/plugins/terminal
import mynim/ui as ui

suite "native Terminal API":
  test "starts a command with defaults and waits for exit":
    let path = getEnv("MYNIM_GHOSTTY_VT")
    if path.len == 0:
      skip()
    when defined(windows):
      let command = @[
        "cmd.exe", "/c", "exit /b 11"]
    else:
      let command = @[
        "/bin/sh", "-c", "printf 'terminal-api-ready'; exit 11"]
    let terminal = newTerminal(TerminalOptions(command: command))
    defer: terminal.close()
    check terminal.waitForExit() == 11
    check terminal.processExitCode().get() == 11
    check terminal.failure().len == 0

  test "builds a GPU scene and sizes the PTY from the native view":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    var options = defaultTerminalOptions()
    options.command = @[
      when defined(windows): "cmd.exe"
      else: "/bin/sh",
      when defined(windows): "/c"
      else: "-c",
      when defined(windows): "ping -n 10 127.0.0.1 >nul"
      else: "sleep 10"]
    options.font.fontFeatures = "liga=0,calt=0"
    let terminal = newTerminal(options)
    defer: terminal.close()
    let tester = ui.newTester(proc(c: ui.Context) =
      discard view(c, terminal).size(800, 500)
    , 800, 500)
    defer: tester.close()
    let (cols, rows) = terminal.size()
    check cols > 0 and rows > 0
    check (cols, rows) != (80, 24)

  test "encodes typed text and special keys through the native view":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    when defined(windows):
      skip()
    else:
      let terminal = newTerminal(TerminalOptions(command: @[
        "/bin/bash", "-c",
        "read -t 5 -r value || exit 98; test \"$value\" = m"]))
      defer: terminal.close()
      let tester = ui.newTester(proc(c: ui.Context) =
        discard view(c, terminal).size(800, 500)
      , 800, 500)
      defer: tester.close()
      tester.setFocused(true)
      tester.clickAt(20, 20)
      tester.typeKey(0, ui.keyM, "m")
      tester.key(0, ui.keyEnter)
      check terminal.waitForExit() == 0
