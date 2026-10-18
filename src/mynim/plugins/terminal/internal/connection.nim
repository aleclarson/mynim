## A caller-supplied byte stream for a native Terminal session.

type
  TerminalConn* = ref object of RootObj
    ## `read` and `write` run on separate terminal worker threads and can
    ## overlap. `read` returns zero at end of stream; `write` returns the
    ## number of bytes accepted. `close` can overlap either and must unblock
    ## blocked I/O or resize. `resize` runs asynchronously on a coalescing
    ## worker, so it cannot stall the UI. Override `resize` when the remote
    ## endpoint can be resized.

method read*(conn: TerminalConn; buffer: var openArray[byte]): int {.base.} =
  raise newException(IOError, "terminal connection does not implement read")

method write*(conn: TerminalConn; buffer: openArray[byte]): int {.base.} =
  raise newException(IOError, "terminal connection does not implement write")

method resize*(conn: TerminalConn; cols, rows: int) {.base.} =
  discard

method close*(conn: TerminalConn) {.base.} =
  discard
