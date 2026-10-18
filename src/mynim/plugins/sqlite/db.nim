## A small SQLite C API binding used by the SQLite plugin and native apps.
## The pinned SQLite amalgamation is compiled into the Mynim executable.

import std/[locks, math, monotimes, os, strutils, times]
import mynim/internal/ctx as context

type
  SqliteDb = pointer
  SqliteStmt = pointer
  SqliteDestructor = proc(data: pointer) {.cdecl.}

  OpenV2 = proc(filename: cstring; db: ptr SqliteDb; flags: cint;
                 vfs: cstring): cint {.cdecl.}
  CloseDb = proc(db: SqliteDb): cint {.cdecl.}
  ErrorMessage = proc(db: SqliteDb): cstring {.cdecl.}
  ExtendedCode = proc(db: SqliteDb): cint {.cdecl.}
  ExtendedResults = proc(db: SqliteDb; enabled: cint): cint {.cdecl.}
  BusyTimeout = proc(db: SqliteDb; milliseconds: cint): cint {.cdecl.}
  BusyCallback = proc(userData: pointer; priorCalls: cint): cint {.cdecl.}
  ProgressCallback = proc(userData: pointer): cint {.cdecl.}
  SetBusyHandler = proc(db: SqliteDb; callback: BusyCallback;
                        userData: pointer): cint {.cdecl.}
  SetProgressHandler = proc(db: SqliteDb; instructions: cint;
                            callback: ProgressCallback; userData: pointer) {.cdecl.}
  PrepareV2 = proc(db: SqliteDb; sql: cstring; bytes: cint;
                   stmt: ptr SqliteStmt; tail: ptr cstring): cint {.cdecl.}
  FinalizeStmt = proc(stmt: SqliteStmt): cint {.cdecl.}
  ParameterCount = proc(stmt: SqliteStmt): cint {.cdecl.}
  BindNull = proc(stmt: SqliteStmt; index: cint): cint {.cdecl.}
  BindInt64 = proc(stmt: SqliteStmt; index: cint; value: int64): cint {.cdecl.}
  BindDouble = proc(stmt: SqliteStmt; index: cint; value: cdouble): cint {.cdecl.}
  BindText = proc(stmt: SqliteStmt; index: cint; value: cstring; bytes: cint;
                  freeValue: SqliteDestructor): cint {.cdecl.}
  BindBlob = proc(stmt: SqliteStmt; index: cint; value: pointer; bytes: cint;
                  freeValue: SqliteDestructor): cint {.cdecl.}
  StepStmt = proc(stmt: SqliteStmt): cint {.cdecl.}
  ColumnCount = proc(stmt: SqliteStmt): cint {.cdecl.}
  ColumnName = proc(stmt: SqliteStmt; index: cint): cstring {.cdecl.}
  ColumnType = proc(stmt: SqliteStmt; index: cint): cint {.cdecl.}
  ColumnInt64 = proc(stmt: SqliteStmt; index: cint): int64 {.cdecl.}
  ColumnDouble = proc(stmt: SqliteStmt; index: cint): cdouble {.cdecl.}
  ColumnText = proc(stmt: SqliteStmt; index: cint): pointer {.cdecl.}
  ColumnBlob = proc(stmt: SqliteStmt; index: cint): pointer {.cdecl.}
  ColumnBytes = proc(stmt: SqliteStmt; index: cint): cint {.cdecl.}
  Changes = proc(db: SqliteDb): cint {.cdecl.}
  TotalChanges = proc(db: SqliteDb): cint {.cdecl.}
  LastInsertRowId = proc(db: SqliteDb): int64 {.cdecl.}
  Interrupt = proc(db: SqliteDb) {.cdecl.}

  SqliteApi = object
    openV2: OpenV2
    closeDb: CloseDb
    errorMessage: ErrorMessage
    extendedCode: ExtendedCode
    extendedResults: ExtendedResults
    busyTimeout: BusyTimeout
    setBusyHandler: SetBusyHandler
    setProgressHandler: SetProgressHandler
    prepareV2: PrepareV2
    finalizeStmt: FinalizeStmt
    parameterCount: ParameterCount
    bindNull: BindNull
    bindInt64: BindInt64
    bindDouble: BindDouble
    bindText: BindText
    bindBlob: BindBlob
    stepStmt: StepStmt
    columnCount: ColumnCount
    columnName: ColumnName
    columnType: ColumnType
    columnInt64: ColumnInt64
    columnDouble: ColumnDouble
    columnText: ColumnText
    columnBlob: ColumnBlob
    columnBytes: ColumnBytes
    changes: Changes
    totalChanges: TotalChanges
    lastInsertRowId: LastInsertRowId
    interrupt: Interrupt

  SqlValueKind* = enum
    sqlNull, sqlInteger, sqlReal, sqlText, sqlBlob

  SqlValue* = object
    ## A SQLite storage-class value. Blob bytes are owned by the Nim value.
    case kind*: SqlValueKind
    of sqlNull:
      discard
    of sqlInteger:
      integer*: int64
    of sqlReal:
      real*: float64
    of sqlText:
      text*: string
    of sqlBlob:
      blob*: seq[byte]

  SqlResult* = object
    changes*: int64
    lastInsertId*: int64

  SqlRows* = object
    ## Column order and duplicate names are retained.
    columns*: seq[string]
    rows*: seq[seq[SqlValue]]

  SqlStatement* = object
    sql*: string
    params*: seq[SqlValue]

  OpenOptions* = object
    readOnly*: bool
    ## Zero selects SQLite's five-second default; a negative value disables
    ## lock waiting.
    busyTimeoutMs*: int

  SqliteError* = object of CatchableError
    code*: int
    extendedCode*: int

  Database* = ref object
    handle: SqliteDb
    mutex: Lock
    handleMutex: Lock
    busyTimeoutMs: int
    closing: bool

  OperationCancellation = object
    cancelled: proc(): bool {.closure.}
    busyTimeoutMs: int
    busyStarted: MonoTime
    failure: ref CatchableError

const
  sqliteOk = 0
  sqliteRow = 100
  sqliteDone = 101
  openReadOnly = 0x00000001.cint
  openReadWrite = 0x00000002.cint
  openCreate = 0x00000004.cint
  openFullMutex = 0x00010000.cint
  sqliteInteger = 1
  sqliteFloat = 2
  sqliteText = 3
  sqliteBlob = 4

let transient = cast[SqliteDestructor](cast[pointer](-1))

{.compile: "native/sqlite3.c".}
{.passC: "-DSQLITE_THREADSAFE=1 -DSQLITE_DQS=0 -DSQLITE_DEFAULT_FOREIGN_KEYS=1 " &
        "-DSQLITE_ENABLE_FTS5=1 -DSQLITE_ENABLE_RTREE=1 " &
        "-DSQLITE_OMIT_LOAD_EXTENSION=1 -DSQLITE_OMIT_DEPRECATED=1 " &
        "-DSQLITE_OMIT_SHARED_CACHE=1".}
when not defined(windows):
  {.passL: "-lm".}

proc cOpenV2(filename: cstring; db: ptr SqliteDb; flags: cint;
              vfs: cstring): cint {.importc: "sqlite3_open_v2", cdecl.}
proc cCloseDb(db: SqliteDb): cint {.importc: "sqlite3_close", cdecl.}
proc cErrorMessage(db: SqliteDb): cstring {.importc: "sqlite3_errmsg", cdecl.}
proc cExtendedCode(db: SqliteDb): cint {.importc: "sqlite3_extended_errcode", cdecl.}
proc cExtendedResults(db: SqliteDb; enabled: cint): cint {.importc: "sqlite3_extended_result_codes", cdecl.}
proc cBusyTimeout(db: SqliteDb; milliseconds: cint): cint {.importc: "sqlite3_busy_timeout", cdecl.}
proc cSetBusyHandler(db: SqliteDb; callback: BusyCallback;
                     userData: pointer): cint {.importc: "sqlite3_busy_handler", cdecl.}
proc cSetProgressHandler(db: SqliteDb; instructions: cint;
                         callback: ProgressCallback; userData: pointer) {.
  importc: "sqlite3_progress_handler", cdecl.}
proc cPrepareV2(db: SqliteDb; sql: cstring; bytes: cint;
                stmt: ptr SqliteStmt; tail: ptr cstring): cint {.importc: "sqlite3_prepare_v2", cdecl.}
proc cFinalizeStmt(stmt: SqliteStmt): cint {.importc: "sqlite3_finalize", cdecl.}
proc cParameterCount(stmt: SqliteStmt): cint {.importc: "sqlite3_bind_parameter_count", cdecl.}
proc cBindNull(stmt: SqliteStmt; index: cint): cint {.importc: "sqlite3_bind_null", cdecl.}
proc cBindInt64(stmt: SqliteStmt; index: cint; value: int64): cint {.importc: "sqlite3_bind_int64", cdecl.}
proc cBindDouble(stmt: SqliteStmt; index: cint; value: cdouble): cint {.importc: "sqlite3_bind_double", cdecl.}
proc cBindText(stmt: SqliteStmt; index: cint; value: cstring; bytes: cint;
               freeValue: SqliteDestructor): cint {.importc: "sqlite3_bind_text", cdecl.}
proc cBindBlob(stmt: SqliteStmt; index: cint; value: pointer; bytes: cint;
               freeValue: SqliteDestructor): cint {.importc: "sqlite3_bind_blob", cdecl.}
proc cStepStmt(stmt: SqliteStmt): cint {.importc: "sqlite3_step", cdecl.}
proc cColumnCount(stmt: SqliteStmt): cint {.importc: "sqlite3_column_count", cdecl.}
proc cColumnName(stmt: SqliteStmt; index: cint): cstring {.importc: "sqlite3_column_name", cdecl.}
proc cColumnType(stmt: SqliteStmt; index: cint): cint {.importc: "sqlite3_column_type", cdecl.}
proc cColumnInt64(stmt: SqliteStmt; index: cint): int64 {.importc: "sqlite3_column_int64", cdecl.}
proc cColumnDouble(stmt: SqliteStmt; index: cint): cdouble {.importc: "sqlite3_column_double", cdecl.}
proc cColumnText(stmt: SqliteStmt; index: cint): pointer {.importc: "sqlite3_column_text", cdecl.}
proc cColumnBlob(stmt: SqliteStmt; index: cint): pointer {.importc: "sqlite3_column_blob", cdecl.}
proc cColumnBytes(stmt: SqliteStmt; index: cint): cint {.importc: "sqlite3_column_bytes", cdecl.}
proc cChanges(db: SqliteDb): cint {.importc: "sqlite3_changes", cdecl.}
proc cTotalChanges(db: SqliteDb): cint {.importc: "sqlite3_total_changes", cdecl.}
proc cLastInsertRowId(db: SqliteDb): int64 {.importc: "sqlite3_last_insert_rowid", cdecl.}
proc cInterrupt(db: SqliteDb) {.importc: "sqlite3_interrupt", cdecl.}

let sqliteApi = SqliteApi(
  openV2: cOpenV2,
  closeDb: cCloseDb,
  errorMessage: cErrorMessage,
  extendedCode: cExtendedCode,
  extendedResults: cExtendedResults,
  busyTimeout: cBusyTimeout,
  setBusyHandler: cSetBusyHandler,
  setProgressHandler: cSetProgressHandler,
  prepareV2: cPrepareV2,
  finalizeStmt: cFinalizeStmt,
  parameterCount: cParameterCount,
  bindNull: cBindNull,
  bindInt64: cBindInt64,
  bindDouble: cBindDouble,
  bindText: cBindText,
  bindBlob: cBindBlob,
  stepStmt: cStepStmt,
  columnCount: cColumnCount,
  columnName: cColumnName,
  columnType: cColumnType,
  columnInt64: cColumnInt64,
  columnDouble: cColumnDouble,
  columnText: cColumnText,
  columnBlob: cColumnBlob,
  columnBytes: cColumnBytes,
  changes: cChanges,
  totalChanges: cTotalChanges,
  lastInsertRowId: cLastInsertRowId,
  interrupt: cInterrupt,
)

proc nullValue*(): SqlValue = SqlValue(kind: sqlNull)
proc integerValue*(value: int64): SqlValue = SqlValue(kind: sqlInteger, integer: value)
proc realValue*(value: float64): SqlValue = SqlValue(kind: sqlReal, real: value)
proc textValue*(value: string): SqlValue = SqlValue(kind: sqlText, text: value)
proc blobValue*(value: openArray[byte]): SqlValue =
  SqlValue(kind: sqlBlob, blob: @value)

proc `==`*(left, right: SqlValue): bool =
  if left.kind != right.kind: return false
  case left.kind
  of sqlNull: true
  of sqlInteger: left.integer == right.integer
  of sqlReal: left.real == right.real
  of sqlText: left.text == right.text
  of sqlBlob: left.blob == right.blob

proc sqliteError(db: SqliteDb; rc: cint): ref SqliteError =
  var message = "SQLite operation failed"
  var code = int(rc)
  var extended = code
  if db != nil:
    let msg = sqliteApi.errorMessage(db)
    if msg != nil: message = $msg
    extended = int(sqliteApi.extendedCode(db))
    code = extended and 0xff
  result = newException(SqliteError, "sqlite: " & message & " (code " & $extended & ")")
  result.code = code
  result.extendedCode = extended

proc checkSqlite(db: SqliteDb; rc: cint) =
  if rc != sqliteOk:
    raise sqliteError(db, rc)

proc isUtf8Continuation(value: int): bool {.inline.} =
  value >= 0x80 and value <= 0xbf

proc isValidUtf8(value: string): bool =
  var i = 0
  while i < value.len:
    let first = ord(value[i])
    if first <= 0x7f:
      inc i
    elif first >= 0xc2 and first <= 0xdf:
      if i + 1 >= value.len or not isUtf8Continuation(ord(value[i + 1])):
        return false
      inc i, 2
    elif first == 0xe0:
      if i + 2 >= value.len: return false
      let second = ord(value[i + 1])
      if second < 0xa0 or second > 0xbf or
          not isUtf8Continuation(ord(value[i + 2])): return false
      inc i, 3
    elif (first >= 0xe1 and first <= 0xec) or
        (first >= 0xee and first <= 0xef):
      if i + 2 >= value.len or
          not isUtf8Continuation(ord(value[i + 1])) or
          not isUtf8Continuation(ord(value[i + 2])): return false
      inc i, 3
    elif first == 0xed:
      if i + 2 >= value.len: return false
      let second = ord(value[i + 1])
      if second < 0x80 or second > 0x9f or
          not isUtf8Continuation(ord(value[i + 2])): return false
      inc i, 3
    elif first == 0xf0:
      if i + 3 >= value.len: return false
      let second = ord(value[i + 1])
      if second < 0x90 or second > 0xbf or
          not isUtf8Continuation(ord(value[i + 2])) or
          not isUtf8Continuation(ord(value[i + 3])): return false
      inc i, 4
    elif first >= 0xf1 and first <= 0xf3:
      if i + 3 >= value.len or
          not isUtf8Continuation(ord(value[i + 1])) or
          not isUtf8Continuation(ord(value[i + 2])) or
          not isUtf8Continuation(ord(value[i + 3])): return false
      inc i, 4
    elif first == 0xf4:
      if i + 3 >= value.len: return false
      let second = ord(value[i + 1])
      if second < 0x80 or second > 0x8f or
          not isUtf8Continuation(ord(value[i + 2])) or
          not isUtf8Continuation(ord(value[i + 3])): return false
      inc i, 4
    else:
      return false
  true

proc open*(path: string; options = OpenOptions()): Database =
  ## Opens a database path or `:memory:` and enables foreign-key constraints.
  if path.len == 0 or '\0' in path or not isValidUtf8(path):
    raise newException(ValueError,
      "sqlite: database path must be nonempty UTF-8 without NUL")
  var flags = openReadWrite or openCreate or openFullMutex
  if options.readOnly:
    flags = openReadOnly or openFullMutex
  var handle: SqliteDb
  let rc = sqliteApi.openV2(path.cstring, addr handle, flags, nil)
  if rc != sqliteOk:
    let error = sqliteError(handle, rc)
    if handle != nil: discard sqliteApi.closeDb(handle)
    raise error

  discard sqliteApi.extendedResults(handle, 1)
  let timeout = if options.busyTimeoutMs == 0: 5000
                else: max(0, options.busyTimeoutMs)
  let timeoutRc = sqliteApi.busyTimeout(handle, min(timeout, high(cint).int).cint)
  if timeoutRc != sqliteOk:
    let error = sqliteError(handle, timeoutRc)
    discard sqliteApi.closeDb(handle)
    raise error

  new(result)
  result.handle = handle
  result.busyTimeoutMs = min(timeout, high(cint).int)
  initLock(result.mutex)
  initLock(result.handleMutex)
  result.mutex.acquire()
  try:
    var stmt: SqliteStmt
    let sql = "PRAGMA foreign_keys = ON"
    let rc = sqliteApi.prepareV2(handle, sql.cstring, sql.len.cint, addr stmt, nil)
    checkSqlite(handle, rc)
    if stmt != nil:
      defer: discard sqliteApi.finalizeStmt(stmt)
      let step = sqliteApi.stepStmt(stmt)
      if step != sqliteDone:
        checkSqlite(handle, step)
  except:
    result.mutex.release()
    discard sqliteApi.closeDb(handle)
    result.handle = nil
    raise
  result.mutex.release()

proc close*(db: Database)

proc open*(ctx: context.CancelCtx; path: string;
           options = OpenOptions()): Database =
  ## Opens a database if `ctx` is active; a context canceled during open
  ## causes the newly opened connection to be closed before returning.
  if ctx != nil and ctx.done():
    let error = ctx.err()
    if error != nil: raise error
    raise context.newCanceled("sqlite: operation canceled")
  result = open(path, options)
  if ctx != nil and ctx.done():
    result.close()
    let error = ctx.err()
    if error != nil: raise error
    raise context.newCanceled("sqlite: operation canceled")

proc close*(db: Database) =
  ## Interrupts any active operation, then closes this connection. Repeated
  ## calls are harmless.
  if db == nil: return
  db.handleMutex.acquire()
  db.closing = true
  if db.handle != nil: sqliteApi.interrupt(db.handle)
  db.handleMutex.release()
  db.mutex.acquire()
  defer: db.mutex.release()
  db.handleMutex.acquire()
  defer: db.handleMutex.release()
  if db.handle == nil: return
  let rc = sqliteApi.closeDb(db.handle)
  if rc != sqliteOk:
    db.closing = false
    raise sqliteError(db.handle, rc)
  db.handle = nil

proc requireOpen(db: Database) =
  if db == nil:
    raise newException(ValueError, "sqlite: database is closed")
  db.handleMutex.acquire()
  let closed = db.handle == nil or db.closing
  db.handleMutex.release()
  if closed:
    raise newException(ValueError, "sqlite: database is closed")

proc interrupt*(db: Database) =
  ## Interrupts the currently running statement, if there is one.
  if db == nil: return
  db.handleMutex.acquire()
  if db.handle != nil: sqliteApi.interrupt(db.handle)
  db.handleMutex.release()

proc prepareOne(db: SqliteDb; sql: string): SqliteStmt =
  if sql.len == 0 or sql.len > high(cint).int:
    raise newException(ValueError, "sqlite: SQL must contain one statement and fit in a C int")
  if '\0' in sql:
    raise newException(ValueError, "sqlite: SQL must not contain NUL")

  var buffer = sql & '\0'
  let base = cast[uint](addr buffer[0])
  var stmt: SqliteStmt
  var tail: cstring
  checkSqlite(db, sqliteApi.prepareV2(db, cast[cstring](addr buffer[0]),
    sql.len.cint, addr stmt, addr tail))
  if stmt == nil:
    raise newException(ValueError, "sqlite: SQL contains no statement")

  var offset = cast[uint](tail) - base
  while offset < uint(sql.len):
    let previous = offset
    var extra: SqliteStmt
    var next: cstring
    let remain = sql.len - int(offset)
    let rc = sqliteApi.prepareV2(db,
      cast[cstring](addr buffer[int(offset)]), remain.cint, addr extra, addr next)
    if rc != sqliteOk:
      discard sqliteApi.finalizeStmt(stmt)
      raise sqliteError(db, rc)
    if extra != nil:
      discard sqliteApi.finalizeStmt(extra)
      discard sqliteApi.finalizeStmt(stmt)
      raise newException(ValueError, "sqlite: expected exactly one statement")
    offset = cast[uint](next) - base
    if offset <= previous: break
  stmt

proc bindValue(db: SqliteDb; stmt: SqliteStmt; index: int; value: SqlValue) =
  var rc: cint
  case value.kind
  of sqlNull:
    rc = sqliteApi.bindNull(stmt, index.cint)
  of sqlInteger:
    rc = sqliteApi.bindInt64(stmt, index.cint, value.integer)
  of sqlReal:
    if classify(value.real) in {fcNan, fcInf, fcNegInf}:
      raise newException(ValueError, "sqlite: real values must be finite")
    rc = sqliteApi.bindDouble(stmt, index.cint, value.real)
  of sqlText:
    if value.text.len > high(cint).int:
      raise newException(ValueError, "sqlite: text value exceeds SQLite's size limit")
    rc = sqliteApi.bindText(stmt, index.cint, value.text.cstring,
      value.text.len.cint, transient)
  of sqlBlob:
    if value.blob.len > high(cint).int:
      raise newException(ValueError, "sqlite: blob value exceeds SQLite's size limit")
    var emptyByte: byte
    let data = if value.blob.len == 0: cast[pointer](addr emptyByte)
               else: cast[pointer](unsafeAddr value.blob[0])
    rc = sqliteApi.bindBlob(stmt, index.cint, data,
      value.blob.len.cint, transient)
  checkSqlite(db, rc)

proc copyBytes(data: pointer; count: int): string =
  result = newString(count)
  if count > 0:
    copyMem(addr result[0], data, count)

proc readColumn(stmt: SqliteStmt; index: int): SqlValue =
  case sqliteApi.columnType(stmt, index.cint)
  of sqliteInteger:
    integerValue(sqliteApi.columnInt64(stmt, index.cint))
  of sqliteFloat:
    realValue(sqliteApi.columnDouble(stmt, index.cint))
  of sqliteText:
    let data = sqliteApi.columnText(stmt, index.cint)
    let count = int(sqliteApi.columnBytes(stmt, index.cint))
    textValue(copyBytes(data, count))
  of sqliteBlob:
    let data = sqliteApi.columnBlob(stmt, index.cint)
    let count = int(sqliteApi.columnBytes(stmt, index.cint))
    var value = blobValue(newSeq[byte](count))
    if count > 0: copyMem(addr value.blob[0], data, count)
    value
  else:
    nullValue()

proc sqlWords(sql: string): seq[string] =
  var i = 0
  while i < sql.len:
    if sql[i] in {' ', '\t', '\r', '\n', '\v', '\f'}:
      inc i
    elif i + 1 < sql.len and sql[i] == '-' and sql[i + 1] == '-':
      i += 2
      while i < sql.len and sql[i] notin {'\r', '\n'}: inc i
    elif i + 1 < sql.len and sql[i] == '/' and sql[i + 1] == '*':
      i += 2
      while i + 1 < sql.len and not (sql[i] == '*' and sql[i + 1] == '/'): inc i
      i = min(i + 2, sql.len)
    elif sql[i] in {'\'', '"', '`', '['}:
      let quote = if sql[i] == '[': ']' else: sql[i]
      inc i
      while i < sql.len:
        if sql[i] == quote:
          if quote != ']' and i + 1 < sql.len and sql[i + 1] == quote:
            i += 2
          else:
            inc i
            break
        else:
          inc i
    elif sql[i] in {'a'..'z', 'A'..'Z', '_'}:
      let start = i
      inc i
      while i < sql.len and sql[i] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: inc i
      result.add sql[start ..< i].toUpperAscii()
    else:
      inc i

proc validateUserSql(sql: string) =
  let words = sqlWords(sql)
  if words.len == 0: return
  if words[0] in ["BEGIN", "COMMIT", "END", "ROLLBACK", "SAVEPOINT", "RELEASE"]:
    raise newException(ValueError, "sqlite: use transaction() for transaction control")
  if words[0] in ["ATTACH", "DETACH"]:
    raise newException(ValueError, "sqlite: ATTACH and DETACH are not allowed")
  if words[0] == "VACUUM" and "INTO" in words:
    raise newException(ValueError, "sqlite: VACUUM INTO is not allowed")

proc runLockedCore(db: SqliteDb; sql: string; params: openArray[SqlValue];
                   collectRows: bool; internal: bool;
                   cancelled: proc(): bool {.closure.}):
                   tuple[execution: SqlResult, rows: SqlRows] =
  if not internal: validateUserSql(sql)
  let stmt = prepareOne(db, sql)
  defer: discard sqliteApi.finalizeStmt(stmt)
  let parameterCount = int(sqliteApi.parameterCount(stmt))
  if parameterCount != params.len:
    raise newException(ValueError, "sqlite: statement needs " & $parameterCount &
      " parameters, got " & $params.len)
  for index, value in params:
    bindValue(db, stmt, index + 1, value)

  if collectRows:
    let count = int(sqliteApi.columnCount(stmt))
    for index in 0 ..< count:
      let name = sqliteApi.columnName(stmt, index.cint)
      result.rows.columns.add(if name == nil: "" else: $name)

  let changesBefore = sqliteApi.totalChanges(db)
  while true:
    if cancelled != nil and cancelled():
      raise newException(ValueError, "sqlite: operation canceled")
    let rc = sqliteApi.stepStmt(stmt)
    case rc
    of sqliteRow:
      if collectRows:
        var row = newSeqOfCap[SqlValue](result.rows.columns.len)
        for index in 0 ..< result.rows.columns.len:
          row.add readColumn(stmt, index)
        result.rows.rows.add row
    of sqliteDone:
      result.execution.lastInsertId = sqliteApi.lastInsertRowId(db)
      if sqliteApi.totalChanges(db) != changesBefore:
        result.execution.changes = int64(sqliteApi.changes(db))
      return
    else:
      raise sqliteError(db, rc)

proc isCanceled(state: ptr OperationCancellation): bool =
  if state == nil or state.cancelled == nil: return false
  try:
    result = state.cancelled()
  except CatchableError as error:
    state.failure = error
    result = true

proc sqliteProgress(userData: pointer): cint {.cdecl.} =
  if isCanceled(cast[ptr OperationCancellation](userData)): 1 else: 0

proc sqliteBusy(userData: pointer; priorCalls: cint): cint {.cdecl.} =
  let state = cast[ptr OperationCancellation](userData)
  if state == nil or state.busyTimeoutMs <= 0: return 0
  if isCanceled(state): return 0
  if priorCalls == 0: state.busyStarted = getMonoTime()
  if (getMonoTime() - state.busyStarted).inMilliseconds >=
      state.busyTimeoutMs.int64:
    return 0
  sleep(1)
  if isCanceled(state): return 0
  1

proc runLocked(db: SqliteDb; sql: string; params: openArray[SqlValue];
               collectRows: bool; internal = false;
               cancelled: proc(): bool {.closure.} = nil;
               busyTimeoutMs = 5000):
               tuple[execution: SqlResult, rows: SqlRows] =
  if cancelled == nil:
    return runLockedCore(db, sql, params, collectRows, internal, nil)

  var cancellation = OperationCancellation(cancelled: cancelled,
    busyTimeoutMs: max(0, busyTimeoutMs))
  let userData = cast[pointer](addr cancellation)
  checkSqlite(db, sqliteApi.setBusyHandler(db, sqliteBusy, userData))
  sqliteApi.setProgressHandler(db, 1000, sqliteProgress, userData)
  var operationError: ref CatchableError
  var restoreError: ref CatchableError
  try:
    result = runLockedCore(db, sql, params, collectRows, internal, cancelled)
  except CatchableError as error:
    operationError = error
  finally:
    sqliteApi.setProgressHandler(db, 0, nil, nil)
    let timeoutRc = sqliteApi.busyTimeout(db,
      min(max(0, busyTimeoutMs), high(cint).int).cint)
    if timeoutRc != sqliteOk:
      restoreError = sqliteError(db, timeoutRc)
  if cancellation.failure != nil: raise cancellation.failure
  if operationError != nil: raise operationError
  if restoreError != nil: raise restoreError

proc isClosing(db: Database): bool =
  db.handleMutex.acquire()
  result = db.closing or db.handle == nil
  db.handleMutex.release()

proc acquireOperationLock(db: Database;
                          cancelled: proc(): bool {.closure.}) =
  if cancelled == nil:
    db.mutex.acquire()
    return
  while not db.mutex.tryAcquire():
    if cancelled():
      raise newException(ValueError, "sqlite: operation canceled")
    sleep(1)
  try:
    if cancelled():
      raise newException(ValueError, "sqlite: operation canceled")
  except:
    db.mutex.release()
    raise

proc contextFailure(ctx: context.CancelCtx): ref CatchableError =
  if ctx != nil:
    result = ctx.err()
  if result == nil:
    result = context.newCanceled("sqlite: operation canceled")

proc execute*(db: Database; sql: string;
              params: openArray[SqlValue] = [];
              cancelled: proc(): bool {.closure.} = nil): SqlResult =
  ## Executes one statement and consumes rows from RETURNING clauses.
  if db == nil: raise newException(ValueError, "sqlite: database is closed")
  db.acquireOperationLock(cancelled)
  defer: db.mutex.release()
  db.requireOpen()
  let shouldStop = proc(): bool =
    db.isClosing() or (cancelled != nil and cancelled())
  runLocked(db.handle, sql, params, false, cancelled = shouldStop,
    busyTimeoutMs = db.busyTimeoutMs).execution

proc execute*(db: Database; ctx: context.CancelCtx; sql: string;
              params: openArray[SqlValue] = []): SqlResult =
  ## Executes one statement and interrupts SQLite work when `ctx` is canceled.
  if ctx != nil and ctx.done(): raise contextFailure(ctx)
  let cancelled = if ctx == nil: nil else:
      (proc(): bool = ctx.done())
  try:
    result = db.execute(sql, params, cancelled)
  except CatchableError:
    if ctx != nil and ctx.done(): raise contextFailure(ctx)
    raise

proc query*(db: Database; sql: string;
            params: openArray[SqlValue] = [];
            cancelled: proc(): bool {.closure.} = nil): SqlRows =
  ## Queries one statement, preserving column order and SQLite value types.
  if db == nil: raise newException(ValueError, "sqlite: database is closed")
  db.acquireOperationLock(cancelled)
  defer: db.mutex.release()
  db.requireOpen()
  let shouldStop = proc(): bool =
    db.isClosing() or (cancelled != nil and cancelled())
  runLocked(db.handle, sql, params, true, cancelled = shouldStop,
    busyTimeoutMs = db.busyTimeoutMs).rows

proc query*(db: Database; ctx: context.CancelCtx; sql: string;
            params: openArray[SqlValue] = []): SqlRows =
  ## Queries one statement and interrupts SQLite work when `ctx` is canceled.
  if ctx != nil and ctx.done(): raise contextFailure(ctx)
  let cancelled = if ctx == nil: nil else:
      (proc(): bool = ctx.done())
  try:
    result = db.query(sql, params, cancelled)
  except CatchableError:
    if ctx != nil and ctx.done(): raise contextFailure(ctx)
    raise

proc control(db: SqliteDb; sql: string;
             cancelled: proc(): bool {.closure.} = nil;
             busyTimeoutMs = 5000) =
  discard runLocked(db, sql, [], false, internal = true,
    cancelled = cancelled, busyTimeoutMs = busyTimeoutMs)

proc transaction*(db: Database;
                  statements: openArray[SqlStatement];
                  cancelled: proc(): bool {.closure.} = nil): seq[SqlResult] =
  ## Runs the statements in order under BEGIN IMMEDIATE and rolls back on error.
  if db == nil: raise newException(ValueError, "sqlite: database is closed")
  db.acquireOperationLock(cancelled)
  defer: db.mutex.release()
  db.requireOpen()
  if statements.len == 0: return @[]

  let shouldStop = proc(): bool =
    db.isClosing() or (cancelled != nil and cancelled())

  control(db.handle, "BEGIN IMMEDIATE", shouldStop, db.busyTimeoutMs)
  var committed = false
  try:
    for statement in statements:
      if shouldStop(): raise newException(ValueError, "sqlite: operation canceled")
      result.add runLocked(db.handle, statement.sql, statement.params, false,
        cancelled = shouldStop, busyTimeoutMs = db.busyTimeoutMs).execution
    if shouldStop(): raise newException(ValueError, "sqlite: operation canceled")
    control(db.handle, "COMMIT", shouldStop, db.busyTimeoutMs)
    committed = true
  except CatchableError:
    if not committed:
      try: control(db.handle, "ROLLBACK", busyTimeoutMs = db.busyTimeoutMs)
      except CatchableError: discard
    raise

proc transaction*(db: Database; ctx: context.CancelCtx;
                  statements: openArray[SqlStatement]): seq[SqlResult] =
  ## Runs an atomic batch and interrupts SQLite work when `ctx` is canceled.
  if ctx != nil and ctx.done(): raise contextFailure(ctx)
  let cancelled = if ctx == nil: nil else:
      (proc(): bool = ctx.done())
  try:
    result = db.transaction(statements, cancelled)
  except CatchableError:
    if ctx != nil and ctx.done(): raise contextFailure(ctx)
    raise
