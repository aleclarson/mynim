import std/[assertions, os, strutils]
when not defined(windows):
  import std/typedthreads
import mynim/plugins/terminal/internal/pty

proc readAll(pty: Pty): string =
  var buffer: array[4096, byte]
  while true:
    let count = pty.read(buffer)
    if count == 0:
      break
    for value in buffer.toOpenArray(0, count - 1):
      result.add char(value)

when not defined(windows):
  proc shell(command: string; cols = 80; rows = 24): Pty =
    start(PtyOptions(path: "/bin/sh", args: @["sh", "-c", command],
      cols: cols, rows: rows, env: @["TERM=dumb"]))

when defined(windows):
  block startsAConPtyProcess:
    let command = getEnv("COMSPEC", "cmd.exe")
    let pty = start(PtyOptions(path: command,
      args: @["cmd.exe", "/c", "echo hello & exit /b 3"], cols: 100, rows: 30))
    doAssert pty.wait() == 3
    pty.close()
    doAssert readAll(pty).contains("hello")
else:
  block startsWithAControllingTerminalAndReportsExitCode:
    let pty = shell("echo hello; stty size; [ -t 0 ] && echo tty; exit 3",
      100, 30)
    doAssert pty.pid() > 0
    let output = pty.readAll()
    doAssert output.contains("hello\r\n")
    doAssert output.contains("30 100\r\n")
    doAssert output.contains("tty\r\n")
    doAssert pty.wait() == 3
    doAssert pty.wait() == 3
    pty.close()

  block resizeAndWriteInput:
    let pty = shell("read line; echo got $line; stty size")
    pty.resize(120, 40)
    let input = "typed\r"
    var bytes = newSeq[byte](input.len)
    for index, value in input:
      bytes[index] = byte(value)
    doAssert pty.write(bytes) == bytes.len
    let output = pty.readAll()
    doAssert output.contains("got typed\r\n")
    doAssert output.contains("40 120\r\n")
    doAssert pty.wait() == 0
    pty.close()

  block closeHangsUpTheProcessGroup:
    let pty = shell("sleep 30")
    type ReaderState = object
      process: Pty
      result: int
    proc readInBackground(state: ptr ReaderState) {.thread.} =
      var buffer: array[128, byte]
      state.result = state.process.read(buffer)
    let state = cast[ptr ReaderState](allocShared0(sizeof(ReaderState)))
    state.process = pty
    var reader: Thread[ptr ReaderState]
    createThread(reader, readInBackground, state)
    sleep(50)
    pty.close()
    joinThread(reader)
    doAssert state.result == 0
    state.process = nil
    deallocShared(state)
    doAssert pty.wait() >= 128

  block killsTheProcessGroup:
    let pty = shell("sleep 30")
    pty.kill()
    doAssert pty.wait() >= 128
    pty.close()

  block reportsAnExecFailure:
    var failed = false
    try:
      discard start(PtyOptions(path: "/no/such/program"))
    except OSError as error:
      failed = error.msg.contains("pty: starting")
    doAssert failed
