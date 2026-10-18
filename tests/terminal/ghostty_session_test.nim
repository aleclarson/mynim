import std/[atomics, locks, options, os, sequtils, strutils, unittest]
import mynim/transfer as transfer
import mynim/plugins/terminal/internal/[connection, pty, session]
import mynim/plugins/terminal/internal/vt/[frame, input, library, terminal]
import mynim/plugins/terminal as terminalApi

type
  TestTerminalConn = ref object of TerminalConn
    guard: Lock
    changed: Cond
    incoming, sent: seq[byte]
    closed, readStarted: bool
    resizeCols, resizeRows: int

proc newTestTerminalConn(): TestTerminalConn =
  new(result)
  initLock(result.guard)
  initCond(result.changed)

method read(conn: TestTerminalConn; buffer: var openArray[byte]): int =
  conn.guard.acquire()
  conn.readStarted = true
  conn.changed.broadcast()
  while conn.incoming.len == 0 and not conn.closed:
    conn.changed.wait(conn.guard)
  if conn.incoming.len == 0:
    conn.guard.release()
    return 0
  result = min(buffer.len, conn.incoming.len)
  for i in 0 ..< result:
    buffer[i] = conn.incoming[i]
  conn.incoming.delete(0 ..< result)
  conn.guard.release()

method write(conn: TestTerminalConn; buffer: openArray[byte]): int =
  conn.guard.acquire()
  if conn.closed:
    conn.guard.release()
    raise newException(IOError, "test terminal connection is closed")
  conn.sent.add(buffer)
  result = buffer.len
  conn.changed.broadcast()
  conn.guard.release()

method resize(conn: TestTerminalConn; cols, rows: int) =
  conn.guard.acquire()
  conn.resizeCols = cols
  conn.resizeRows = rows
  conn.changed.broadcast()
  conn.guard.release()

method close(conn: TestTerminalConn) =
  conn.guard.acquire()
  conn.closed = true
  conn.changed.broadcast()
  conn.guard.release()

proc feed(conn: TestTerminalConn; value: string) =
  conn.guard.acquire()
  for c in value:
    conn.incoming.add byte(ord(c))
  conn.changed.broadcast()
  conn.guard.release()

proc sentText(conn: TestTerminalConn): string =
  conn.guard.acquire()
  for b in conn.sent:
    result.add char(b)
  conn.guard.release()

proc resizedTo(conn: TestTerminalConn): tuple[cols, rows: int] =
  conn.guard.acquire()
  result = (conn.resizeCols, conn.resizeRows)
  conn.guard.release()

proc isClosed(conn: TestTerminalConn): bool =
  conn.guard.acquire()
  result = conn.closed
  conn.guard.release()

proc isReading(conn: TestTerminalConn): bool =
  conn.guard.acquire()
  result = conn.readStarted
  conn.guard.release()

proc text(frame: TerminalFrame): string =
  for row in frame.viewport:
    for cell in row.cells:
      for codepoint in cell.codepoints:
        if codepoint > 0 and codepoint < 128:
          result.add char(codepoint)
    result.add '\n'

suite "Ghostty PTY terminal session":
  test "connects a caller stream for terminal output, input, resize, and EOF":
    let path = getEnv("MYNIM_GHOSTTY_VT")
    if path.len == 0:
      skip()
    let library = openGhosttyVT(path)
    defer: library.close()
    let conn = newTestTerminalConn()
    let publicOptions = terminalApi.TerminalOptions(conn: conn)
    check publicOptions.conn == conn
    let session = newTerminalSession(library, PtyOptions(),
      connection = conn, cols = 80, rows = 24)
    defer: session.close()

    session.resize(100, 30)
    check conn.resizedTo() == (cols: 100, rows: 30)
    conn.feed("remote-ready")
    var ready = false
    for _ in 0 ..< 200:
      if text(session.snapshot()).contains("remote-ready"):
        ready = true
        break
      sleep(10)
    check ready

    session.send(@[byte(ord('x'))])
    var sent = false
    for _ in 0 ..< 200:
      if conn.sentText().contains('x'):
        sent = true
        break
      sleep(10)
    check sent

    conn.close()
    check session.waitForExit() == 0
    check session.processExitCode().get() == 0
    check text(session.snapshot()).contains("[Disconnected]")
    check session.takeEvents().anyIt(it.kind == terminalProcessExited and
      it.exitCode == 0)
    check session.failure().len == 0
    check conn.isClosed()

  test "closing a connection session unblocks its reader":
    let path = getEnv("MYNIM_GHOSTTY_VT")
    if path.len == 0:
      skip()
    let library = openGhosttyVT(path)
    defer: library.close()
    let conn = newTestTerminalConn()
    let session = newTerminalSession(library, PtyOptions(), connection = conn)
    var reading = false
    for _ in 0 ..< 200:
      if conn.isReading():
        reading = true
        break
      sleep(10)
    check reading
    session.close()
    check conn.isClosed()

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
    var wakeCount: Atomic[int]
    session.setWake(proc() {.gcsafe.} =
      discard wakeCount.fetchAdd(1, moRelaxed))

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
    check wakeCount.load(moRelaxed) > 0
    if ready:
      session.sendKey(KeyEvent(action: keyPress, key: keyM, text: "m",
        unshifted: uint32(ord('m'))))
      session.sendKey(KeyEvent(action: keyRelease, key: keyM))
      session.sendKey(KeyEvent(action: keyPress, key: keyEnter))
      session.sendKey(KeyEvent(action: keyRelease, key: keyEnter))
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
        check contents.contains("got:m")
        check normalized.contains("reply: 1b 5b 30 6e")
        check contents.contains("SYNC")
        check contents.contains("[Process exited with code 7]")
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

  test "starts the process at the first resized PTY dimensions":
    let path = getEnv("MYNIM_GHOSTTY_VT")
    if path.len == 0:
      skip()
    let library = openGhosttyVT(path)
    defer: library.close()
    let session = newTerminalSession(library,
      PtyOptions(path: "/bin/sh", args: @["/bin/sh", "-c", "stty size"]),
      cols = 80, rows = 24)
    defer: session.close()

    session.resize(100, 30, cellWidth = 9, cellHeight = 18)
    check session.waitForExit() == 0
    check text(session.snapshot()).contains("30 100")

  test "offers rich clipboard data through Kitty mode 5522":
    let path = getEnv("MYNIM_GHOSTTY_VT")
    if path.len == 0:
      skip()
    let library = openGhosttyVT(path)
    defer: library.close()
    let script = """
import base64, os, re, select, sys, termios, time
attrs = termios.tcgetattr(0)
attrs[3] &= ~(termios.ICANON | termios.ECHO)
attrs[6][termios.VMIN] = 1
attrs[6][termios.VTIME] = 0
termios.tcsetattr(0, termios.TCSANOW, attrs)
os.write(1, b'\x1b[?5522hREADY\r\n')
def read_until(needle, timeout=3):
    result = b''
    deadline = time.monotonic() + timeout
    while needle not in result and time.monotonic() < deadline:
        ready, _, _ = select.select([0], [], [], 0.1)
        if ready:
            part = os.read(0, 1)
            if not part:
                break
            result += part
    return result
event = read_until(b'status=DONE')
if b'status=DONE' not in event:
    os.write(1, b'\r\nNO_EVENT\r\n')
    sys.exit(13)
match = re.search(rb':pw=([^;\x1b]+)', event)
if not match:
    sys.exit(11)
pw = match.group(1)
mimes = b'text/plain text/html'
mime = base64.b64encode(mimes)
name = base64.b64encode(b'Paste event')
listing = base64.b64encode(mimes + b'\n')
if b';' + listing not in event:
    os.write(1, b'\r\nBAD_LISTING:' + base64.b64encode(event) + b'\r\n')
    sys.exit(15)
request = b'\x1b]5522;type=read:pw=' + pw + b':name=' + name + b';' + mime + b'\x1b\\'
os.write(1, request)
reply = read_until(b'status=DONE')
if b'status=DONE' not in reply:
    os.write(1, b'\r\nNO_REPLY\r\n')
    sys.exit(14)
expected_text = b'status=DATA:mime=' + base64.b64encode(b'text/plain') + b';' + base64.b64encode(b'pasted')
expected_html = b'status=DATA:mime=' + base64.b64encode(b'text/html') + b';' + base64.b64encode(b'<b>pasted</b>')
ok = expected_text in reply and expected_html in reply
if not ok:
    os.write(1, b'\r\nOFFER_BAD:' + base64.b64encode(reply) + b'\r\n')
    sys.exit(12)
os.write(1, b'\r\nFIRST_OK\r\nEMPTY_READY\r\n')
event = read_until(b'status=DONE')
match = re.search(rb':pw=([^;\x1b]+)', event)
if not match:
    os.write(1, b'\r\nEMPTY_NO_EVENT\r\n')
    sys.exit(16)
pw = match.group(1)
mime = base64.b64encode(b'text/plain')
name = base64.b64encode(b'Paste event')
request = b'\x1b]5522;type=read:pw=' + pw + b':name=' + name + b';' + mime + b'\x1b\\'
os.write(1, request)
reply = read_until(b'status=DONE')
ok = b'status=OK' in reply and b'status=EPERM' not in reply and b'status=DATA' not in reply
marker = b'EMPTY_OK' if ok else b'EMPTY_BAD:' + base64.b64encode(reply)
os.write(1, b'\r\n' + marker + b'\r\n')
if not ok:
    sys.exit(17)
os.write(1, b'\r\nNOT_TAKEN_READY\r\n')
event = read_until(b'status=DONE')
if b'status=DONE' not in event:
    os.write(1, b'\r\nNO_THIRD_EVENT\r\n')
    sys.exit(18)
sys.exit(0)
"""
    let session = newTerminalSession(library,
      PtyOptions(path: "/usr/bin/python3",
        args: @["/usr/bin/python3", "-c", script]),
      cols = 80, rows = 24)
    defer: session.close()
    session.resize(80, 24)

    var ready = false
    for _ in 0 ..< 500:
      if text(session.snapshot()).contains("READY"):
        ready = true
        break
      sleep(10)
    check ready
    if ready:
      check session.mode(modePasteEvents)
      if session.processExitCode().isSome:
        checkpoint("paste child exited " & $session.processExitCode().get() &
          ": " & text(session.snapshot()))
      check session.processExitCode().isNone
      let data = transfer.newData(transfer.newItem(
        transfer.bytes(transfer.Text, "pasted"),
        transfer.bytes(transfer.HTML, "<b>pasted</b>")))
      session.pasteData(data)
      var secondReady = false
      for _ in 0 ..< 500:
        if text(session.snapshot()).contains("EMPTY_READY"):
          secondReady = true
          break
        sleep(10)
      check secondReady
      if secondReady:
        session.pasteData(transfer.textData(""))
      var thirdReady = false
      for _ in 0 ..< 500:
        if text(session.snapshot()).contains("NOT_TAKEN_READY"):
          thirdReady = true
          break
        sleep(10)
      check thirdReady
      if thirdReady:
        session.pasteData(transfer.textData("not read"))
      let exitCode = session.waitForExit()
      let contents = text(session.snapshot())
      check exitCode == 0
      if exitCode != 0:
        checkpoint("paste child exited " & $exitCode & ": " & contents)
      check contents.contains("FIRST_OK")
      check contents.contains("EMPTY_OK")
      sleep(5100)
      let progress = session.takeEvents().filterIt(
        it.kind == terminalPasteProgress)
      let statuses = progress.mapIt(it.pasteProgress.status)
      check pasteOffered in statuses
      check pasteSending in statuses
      check pasteSent in statuses
      check pasteNotTaken in statuses
      check progress.anyIt(it.pasteProgress.status == pasteSent and
        it.pasteProgress.sent == it.pasteProgress.total and
        it.pasteProgress.total > 0)
