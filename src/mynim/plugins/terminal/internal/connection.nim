## A caller-supplied byte stream for a native Terminal session.

type
  TerminalConn* = ref object of RootObj
    ## Read, write, and close are called from terminal worker threads. A
    ## connection must support concurrent reads and writes. `read` returns
    ## zero only at end of stream; `close` must unblock a blocked read or
    ## write. Override `resize` when the remote endpoint can be resized.

method read*(conn: TerminalConn; buffer: var openArray[byte]): int {.base.} =
  raise newException(IOError, "terminal connection does not implement read")

method write*(conn: TerminalConn; buffer: openArray[byte]): int {.base.} =
  raise newException(IOError, "terminal connection does not implement write")

method resize*(conn: TerminalConn; cols, rows: int) {.base.} =
  discard

method close*(conn: TerminalConn) {.base.} =
  discard
