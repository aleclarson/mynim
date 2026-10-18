import std/[atomics, options, os, strutils, unittest]
import mynim/plugins/terminal
import mynim/transfer as transfer
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

  test "routes OSC notifications and clipboard writes":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    when defined(windows):
      skip()
    else:
      var notificationTitleMatches, notificationBodyMatches: Atomic[bool]
      var options = defaultTerminalOptions()
      options.command = @[
        "/bin/sh", "-c",
        "printf '\\033]52;c;aGVsbG8=\\a\\033]9;Mynim notice\\a'; sleep 10"]
      options.onNotify = proc(title, body: string) =
        notificationTitleMatches.store(title == "", moRelaxed)
        notificationBodyMatches.store(body == "Mynim notice", moRelaxed)
      let terminal = newTerminal(options)
      defer: terminal.close()

      for _ in 0 ..< 200:
        if notificationBodyMatches.load(moRelaxed):
          break
        sleep(10)
      check notificationTitleMatches.load(moRelaxed)
      check notificationBodyMatches.load(moRelaxed)

      let tester = ui.newTester(proc(c: ui.Context) =
        discard view(c, terminal).size(800, 500)
      , 800, 500)
      defer: tester.close()

      for _ in 0 ..< 200:
        sleep(10)
        tester.frame()
        if tester.clipboard() == "hello" and
            notificationBodyMatches.load(moRelaxed):
          break
      check tester.clipboard() == "hello"

      var deniedOptions = defaultTerminalOptions()
      deniedOptions.command = @[
        "/bin/sh", "-c",
        "printf '\\033]52;c;bm8=\\a'; sleep 1"]
      deniedOptions.noClipboardWrite = true
      let deniedTerminal = newTerminal(deniedOptions)
      defer: deniedTerminal.close()
      let deniedTester = ui.newTester(proc(c: ui.Context) =
        discard view(c, deniedTerminal).size(800, 500)
      , 800, 500)
      defer: deniedTester.close()
      deniedTester.setClipboard("preserved")
      check deniedTerminal.waitForExit() == 0
      deniedTester.frame()
      check deniedTester.clipboard() == "preserved"

  test "denies OSC 52 clipboard reads by default":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    when defined(windows):
      skip()
    else:
      let script = "stty -echo -icanon min 0 time 10; " &
        "printf '\\033]52;c;?\\033\\\\'; " &
        "response=$(dd bs=1 count=9 2>/dev/null); " &
        "stty icanon echo; " &
        "expected=$(printf '\\033]52;c;\\033\\\\'); " &
        "test \"$response\" = \"$expected\""
      let terminal = newTerminal(TerminalOptions(command: @[
        "/bin/sh", "-c", script]))
      defer: terminal.close()
      check terminal.waitForExit() == 0
      check terminal.failure().len == 0

  test "allows OSC 52 reads through the UI clipboard service":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    when defined(windows):
      skip()
    else:
      let script = "stty -echo -icanon min 0 time 10; " &
        "printf '\\033]52;c;?\\033\\\\'; " &
        "expected=$(printf '\\033]52;c;YWxsb3dlZA==\\033\\\\'); " &
        "response=$(dd bs=1 count=${#expected} 2>/dev/null); " &
        "stty icanon echo; test \"$response\" = \"$expected\""
      let terminal = newTerminal(TerminalOptions(
        command: @["/bin/sh", "-c", "read start; " & script],
        clipboardRead: clipboardReadAllow))
      defer: terminal.close()
      let tester = ui.newTester(proc(c: ui.Context) =
        discard view(c, terminal).size(800, 500)
      , 800, 500)
      defer: tester.close()
      tester.setClipboard("allowed")
      terminal.send("go\n")
      for _ in 0 ..< 200:
        tester.frame()
        if terminal.processExitCode().isSome:
          break
        sleep(10)
      check terminal.processExitCode().get() == 0
      check terminal.failure().len == 0

  test "asks the app before allowing an OSC 52 clipboard read":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    when defined(windows):
      skip()
    else:
      let script = "stty -echo -icanon min 0 time 10; " &
        "printf '\\033]52;c;?\\033\\\\'; " &
        "expected=$(printf '\\033]52;c;Y2FsbGJhY2s=\\033\\\\'); " &
        "response=$(dd bs=1 count=${#expected} 2>/dev/null); " &
        "stty icanon echo; test \"$response\" = \"$expected\""
      var callbackCount = 0
      var options = defaultTerminalOptions()
      options.command = @["/bin/sh", "-c", "read start; " & script]
      options.clipboardRead = clipboardReadAsk
      options.onClipboardRequest = proc(request: TerminalClipboardRequest) =
        inc callbackCount
        check request.mimes == @["text/plain"]
        request.allow()
      let terminal = newTerminal(options)
      defer: terminal.close()
      let tester = ui.newTester(proc(c: ui.Context) =
        discard view(c, terminal).size(800, 500)
      , 800, 500)
      defer: tester.close()
      tester.setClipboard("callback")
      terminal.send("go\n")
      for _ in 0 ..< 200:
        tester.frame()
        if terminal.processExitCode().isSome:
          break
        sleep(10)
      check terminal.processExitCode().get() == 0
      check terminal.failure().len == 0
      check callbackCount == 1

  test "shows a prompt for app-less clipboard read approval":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    when defined(windows):
      skip()
    else:
      let expected = "\x1b]52;c;cHJvbXB0\x1b\\"
      let script = "read start; stty -echo -icanon min 0 time 10; " &
        "printf '\\033]52;c;?\\033\\\\'; " &
        "expected='" & expected & "'; " &
        "response=$(dd bs=1 count=${#expected} 2>/dev/null); " &
        "stty icanon echo; test \"$response\" = \"$expected\""
      let terminal = newTerminal(TerminalOptions(
        command: @["/bin/sh", "-c", script],
        clipboardRead: clipboardReadAsk))
      defer: terminal.close()
      let tester = ui.newTester(proc(c: ui.Context) =
        discard view(c, terminal).size(800, 500)
      , 800, 500)
      defer: tester.close()
      tester.setClipboard("prompt")
      terminal.send("go\n")
      var promptShown = false
      for _ in 0 ..< 200:
        tester.frame()
        if tester.hasText("Clipboard access"):
          promptShown = true
          break
        sleep(10)
      check promptShown
      check tester.click("Allow") == nil
      for _ in 0 ..< 200:
        tester.frame()
        if terminal.processExitCode().isSome:
          break
        sleep(10)
      check terminal.processExitCode().get() == 0
      check terminal.failure().len == 0

  test "answers Kitty clipboard reads with their requested MIME data":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    when defined(windows):
      skip()
    else:
      let expected =
        "\x1b]5522;type=read:status=OK:id=x\x1b\\" &
        "\x1b]5522;type=read:status=DATA:id=x:mime=dGV4dC9wbGFpbg==;a2l0dHk=\x1b\\" &
        "\x1b]5522;type=read:status=DONE:id=x\x1b\\"
      let script = "read start; stty -echo -icanon min 0 time 20; " &
        "printf '\\033]5522;type=read:id=x;dGV4dC9wbGFpbg==\\033\\\\'; " &
        "expected='" & expected & "'; " &
        "response=$(dd bs=1 count=${#expected} 2>/dev/null); " &
        "stty icanon echo; test \"$response\" = \"$expected\""
      let terminal = newTerminal(TerminalOptions(
        command: @["/bin/sh", "-c", script],
        clipboardRead: clipboardReadAllow))
      defer: terminal.close()
      let tester = ui.newTester(proc(c: ui.Context) =
        discard view(c, terminal).size(800, 500)
      , 800, 500)
      defer: tester.close()
      tester.setClipboard("kitty")
      terminal.send("go\n")
      for _ in 0 ..< 300:
        tester.frame()
        if terminal.processExitCode().isSome:
          break
        sleep(10)
      check terminal.processExitCode().get() == 0
      check terminal.failure().len == 0

  test "builds a GPU scene and sizes the PTY from the native view":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    let oscUrl = "https://osc.example/" & repeat("x", 600)
    var options = defaultTerminalOptions()
    var processStarted: Atomic[bool]
    options.command = @[
      when defined(windows): "cmd.exe"
      else: "/bin/sh",
      when defined(windows): "/c"
      else: "-c",
      when defined(windows): "ping -n 10 127.0.0.1 >nul"
      else:
        "printf '\\033]9;terminal-ready\\007\\033]8;;" & oscUrl &
        "\\aosc-link\\033]8;;\\a\\r\\n" &
        "https://text.example/path.\\r\\n" &
        "./src/main.nim:12:3\\r\\n'; sleep 10"]
    options.font.fontFeatures = "liga=0,calt=0"
    options.onNotify = proc(title, body: string) =
      if body == "terminal-ready":
        processStarted.store(true, moRelaxed)
    var openedPaths: seq[string]
    var seenLinks: seq[string]
    options.openLink = proc(link: string): bool =
      seenLinks.add(link)
      if link.startsWith("./"):
        openedPaths.add(link)
        true
      else:
        false
    let terminal = newTerminal(options)
    defer: terminal.close()
    let tester = ui.newTester(proc(c: ui.Context) =
      discard view(c, terminal).size(800, 500)
    , 800, 500)
    defer: tester.close()
    let (cols, rows) = terminal.size()
    check cols > 0 and rows > 0
    check (cols, rows) != (80, 24)
    when not defined(windows):
      const commandMods = when defined(macosx): ui.modSuper else: ui.modCtrl
      var processOutputReady = false
      for _ in 0 ..< 200:
        tester.frame()
        if processStarted.load(moRelaxed):
          processOutputReady = true
          break
        sleep(10)
      check processOutputReady
      tester.frame()
      tester.move(20, 12)
      tester.holdModifiers(commandMods)
      check tester.cursor() == ui.cursorPointer
      tester.holdModifiers(0)
      check tester.cursor() == ui.cursorText

      tester.clickAt(20, 12)
      check tester.openedUrls().len == 0
      check seenLinks.len == 0
      tester.clickAtWith(commandMods, 20, 12)
      check tester.openedUrls() == @[oscUrl]
      tester.clickAtWith(commandMods, 20, 30)
      check tester.openedUrls() == @[
        oscUrl, "https://text.example/path"]
      tester.clickAtWith(commandMods, 20, 48)
      check openedPaths == @["./src/main.nim:12:3"]
      check seenLinks == @[
        oscUrl, "https://text.example/path",
        "./src/main.nim:12:3"]

  test "encodes typed text and pastes clipboard through the native view":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    when defined(windows):
      skip()
    else:
      let terminal = newTerminal(TerminalOptions(command: @[
        "/bin/bash", "-c",
        "read -t 5 -r value || exit 98; test \"$value\" = m || exit 99; " &
        "read -t 30 -n 6 -r value || exit 98; test \"$value\" = pasted"]))
      defer: terminal.close()
      let tester = ui.newTester(proc(c: ui.Context) =
        discard view(c, terminal).size(800, 500)
      , 800, 500)
      defer: tester.close()
      tester.setFocused(true)
      tester.clickAt(20, 20)
      tester.typeKey(0, ui.keyM, "m")
      tester.key(0, ui.keyEnter)
      tester.setClipboard("pasted")
      tester.rightClickAt(30, 20)
      check tester.chooseMenuItem("Paste") == nil
      check terminal.waitForExit() == 0

  test "offers all clipboard formats to the paste callback":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    when defined(windows):
      skip()
    else:
      var offeredFormats: seq[transfer.Format]
      var offeredText = ""
      var options = defaultTerminalOptions()
      options.command = @[
        "/bin/bash", "-c",
        "read -t 1 -n 6 -r value && exit 12; exit 0"]
      options.onPaste = proc(data: transfer.Data): bool =
        offeredFormats = data.formats()
        let read = data.read(transfer.Text)
        if read.err == nil:
          offeredText = transfer.bytesToString(read.data)
        true
      let terminal = newTerminal(options)
      defer: terminal.close()
      let tester = ui.newTester(proc(c: ui.Context) =
        discard view(c, terminal).size(800, 500)
      , 800, 500)
      defer: tester.close()
      tester.setFocused(true)
      tester.clickAt(20, 20)
      tester.setClipboardData(transfer.newData(transfer.newItem(
        transfer.bytes(transfer.Text, "pasted"),
        transfer.bytes(transfer.HTML, "<b>pasted</b>"))))
      tester.command("paste")
      check offeredFormats == @[transfer.Text, transfer.HTML]
      check offeredText == "pasted"
      check terminal.waitForExit() == 0

  test "reports when an image-only paste cannot be offered":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    when defined(windows):
      skip()
    else:
      var statuses: seq[TerminalPasteStatus]
      var options = defaultTerminalOptions()
      options.command = @["/bin/sh", "-c", "sleep 5"]
      options.onPasteStatus = proc(progress: TerminalPasteProgress) =
        statuses.add(progress.status)
      let terminal = newTerminal(options)
      defer: terminal.close()
      let tester = ui.newTester(proc(c: ui.Context) =
        discard view(c, terminal).size(800, 500)
      , 800, 500)
      defer: tester.close()
      tester.setFocused(true)
      tester.clickAt(20, 20)
      tester.setClipboardData(transfer.newData(transfer.newItem(
        transfer.bytes(transfer.PNG, @[137'u8, 80, 78, 71]))))
      tester.command("paste")
      tester.frame()
      check pasteNoText in statuses

  test "falls back to text paste when the paste callback declines":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    when defined(windows):
      skip()
    else:
      var options = defaultTerminalOptions()
      options.command = @[
        "/bin/bash", "-c",
        "read -t 3 -n 6 -r value || exit 98; test \"$value\" = pasted"]
      options.onPaste = proc(data: transfer.Data): bool = false
      let terminal = newTerminal(options)
      defer: terminal.close()
      let tester = ui.newTester(proc(c: ui.Context) =
        discard view(c, terminal).size(800, 500)
      , 800, 500)
      defer: tester.close()
      tester.setFocused(true)
      tester.clickAt(20, 20)
      tester.setClipboardData(transfer.textData("pasted"))
      tester.command("paste")
      check terminal.waitForExit() == 0

  test "pastes clipboard on configured right-click":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    when defined(windows):
      skip()
    else:
      var options = defaultTerminalOptions()
      options.command = @[
        "/bin/bash", "-c",
        "read -t 5 -r value || exit 98; test \"$value\" = m || exit 99; " &
        "read -t 30 -n 6 -r value || exit 98; test \"$value\" = pasted"]
      options.rightClick = rightClickPaste
      let terminal = newTerminal(options)
      defer: terminal.close()
      let tester = ui.newTester(proc(c: ui.Context) =
        discard view(c, terminal).size(800, 500)
      , 800, 500)
      defer: tester.close()
      tester.setFocused(true)
      tester.clickAt(20, 20)
      tester.typeKey(0, ui.keyM, "m")
      tester.key(0, ui.keyEnter)
      tester.setClipboard("pasted")
      tester.rightClickAt(30, 20)
      check terminal.waitForExit() == 0

  test "selects terminal output and copies it through UI commands":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    when defined(windows):
      skip()
    else:
      var options = defaultTerminalOptions()
      options.command = @["/bin/sh", "-c", "printf hello"]
      options.copyOnSelect = copyOnSelectClipboard
      options.rightClick = rightClickCopy
      let terminal = newTerminal(options)
      defer: terminal.close()
      check terminal.waitForExit() == 0
      let tester = ui.newTester(proc(c: ui.Context) =
        discard view(c, terminal).size(800, 500)
      , 800, 500)
      defer: tester.close()
      tester.setFocused(true)
      tester.clickAt(20, 20)
      tester.setClipboard("stale")
      tester.command("selectAll")
      check tester.clipboard() == "hello"
      tester.command("copy")
      check tester.clipboard() == "hello"
      tester.command("selectAll")
      tester.key(ui.modSuper, ui.keyC)
      check tester.clipboard() == "hello"
      tester.setClipboard("stale")
      tester.press(10, 12)
      tester.move(50, 12)
      tester.release(50, 12)
      check tester.clipboard() == "hello"
      tester.setClipboard("stale")
      tester.rightClickAt(30, 20)
      check tester.clipboard() == "hello"

  test "drags the terminal scrollbar to older output":
    if getEnv("MYNIM_GHOSTTY_VT").len == 0:
      skip()
    when defined(windows):
      skip()
    else:
      let terminal = newTerminal(TerminalOptions(command: @[
        "/bin/sh", "-c",
        "i=0; while [ $i -lt 100 ]; do printf 'line %03d\\r\\n' \"$i\"; i=$((i+1)); done"]))
      defer: terminal.close()
      check terminal.waitForExit() == 0
      let tester = ui.newTester(proc(c: ui.Context) =
        discard view(c, terminal).size(800, 500)
      , 800, 500)
      defer: tester.close()
      tester.setFocused(true)
      tester.press(792, 5)
      tester.release(792, 5)
      tester.press(10, 12)
      tester.move(60, 12)
      tester.release(60, 12)
      tester.command("copy")
      let topLine = tester.clipboard()
      check topLine.startsWith("line ")
      check parseInt(topLine[5 .. ^1]) < 10
      tester.setLocale("zh-Hans")
      tester.rightClickAt(30, 20)
      check tester.menu() == @[
        "复制", "粘贴", "全选", "-", "清除回滚"]
      check tester.chooseMenuItem("全选") == nil
      tester.setLocale("")
      tester.rightClickAt(30, 20)
      check tester.menu() == @[
        "Copy", "Paste", "Select All", "-", "Clear Scrollback"]
      check tester.chooseMenuItem("Select All") == nil
      tester.rightClickAt(30, 20)
      check tester.chooseMenuItem("Copy") == nil
      let allScrollback = tester.clipboard()
      check allScrollback.contains("line 000")
      tester.rightClickAt(30, 20)
      check tester.chooseMenuItem("Clear Scrollback") == nil
      tester.rightClickAt(30, 20)
      check tester.chooseMenuItem("Select All") == nil
      tester.rightClickAt(30, 20)
      check tester.chooseMenuItem("Copy") == nil
      check tester.clipboard().len < allScrollback.len
