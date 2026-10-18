import std/[assertions, strutils]
import mynim/plugins/terminal/internal/pty

proc readAll(pty: Pty): string =
  var buffer: array[4096, byte]
  while true:
    let count = pty.read(buffer)
    if count == 0:
      break
    for value in buffer.toOpenArray(0, count - 1):
      result.add char(value)

proc shell(command: string; cols = 80; rows = 24): Pty =
  start(PtyOptions(path: "/bin/sh", args: @["sh", "-c", command],
    cols: cols, rows: rows, env: @["TERM=dumb"]))

block startsWithAControllingTerminalAndReportsExitCode:
  let pty = shell("echo hello; stty size; [ -t 0 ] && echo tty; exit 3",
    100, 30)
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
  pty.close()
  doAssert pty.wait() >= 128

block reportsAnExecFailure:
  var failed = false
  try:
    discard start(PtyOptions(path: "/no/such/program"))
  except OSError as error:
    failed = error.msg.contains("pty: starting")
  doAssert failed
