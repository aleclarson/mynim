## A small SQLite C API binding used by the SQLite plugin and native apps.
## The SQLite shared library is loaded at runtime; no header or cgo binding is
## required to compile Mynim.

import std/[dynlib, locks, math, strutils]

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
    library: LibHandle
    openV2: OpenV2
    closeDb: CloseDb
    errorMessage: ErrorMessage
    extendedCode: ExtendedCode
    extendedResults: ExtendedResults
    busyTimeout: BusyTimeout
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
    closing: bool

var sqliteApi: SqliteApi
var sqliteApiReady = false
var sqliteApiError = ""
var sqliteApiLock: Lock
initLock(sqliteApiLock)

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

proc loadFunction[T](lib: LibHandle; name: string): T =
  let address = symAddr(lib, name)
  if address == nil:
    raise newException(LibraryError, "sqlite: missing symbol " & name)
  cast[T](address)

proc loadSqliteApi() =
  sqliteApiLock.acquire()
  defer: sqliteApiLock.release()
  if sqliteApiReady:
    if sqliteApiError.len > 0:
      raise newException(LibraryError, sqliteApiError)
    return
  sqliteApiReady = true

  when defined(macosx):
    const names = [
      "libsqlite3.dylib",
      "/usr/lib/libsqlite3.dylib",
      "/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib",
      "/usr/local/opt/sqlite/lib/libsqlite3.dylib",
    ]
  elif defined(windows):
    const names = ["sqlite3.dll", "winsqlite3.dll"]
  else:
    const names = ["libsqlite3.so.0", "libsqlite3.so"]

  var lib: LibHandle
  for name in names:
    lib = loadLib(name)
    if lib != nil: break
  if lib == nil:
    sqliteApiError = "sqlite: could not load a system SQLite library"
    raise newException(LibraryError, sqliteApiError)

  try:
    sqliteApi = SqliteApi(
      library: lib,
      openV2: loadFunction[OpenV2](lib, "sqlite3_open_v2"),
      closeDb: loadFunction[CloseDb](lib, "sqlite3_close"),
      errorMessage: loadFunction[ErrorMessage](lib, "sqlite3_errmsg"),
      extendedCode: loadFunction[ExtendedCode](lib, "sqlite3_extended_errcode"),
      extendedResults: loadFunction[ExtendedResults](lib, "sqlite3_extended_result_codes"),
      busyTimeout: loadFunction[BusyTimeout](lib, "sqlite3_busy_timeout"),
      prepareV2: loadFunction[PrepareV2](lib, "sqlite3_prepare_v2"),
      finalizeStmt: loadFunction[FinalizeStmt](lib, "sqlite3_finalize"),
      parameterCount: loadFunction[ParameterCount](lib, "sqlite3_bind_parameter_count"),
      bindNull: loadFunction[BindNull](lib, "sqlite3_bind_null"),
      bindInt64: loadFunction[BindInt64](lib, "sqlite3_bind_int64"),
      bindDouble: loadFunction[BindDouble](lib, "sqlite3_bind_double"),
      bindText: loadFunction[BindText](lib, "sqlite3_bind_text"),
      bindBlob: loadFunction[BindBlob](lib, "sqlite3_bind_blob"),
      stepStmt: loadFunction[StepStmt](lib, "sqlite3_step"),
      columnCount: loadFunction[ColumnCount](lib, "sqlite3_column_count"),
      columnName: loadFunction[ColumnName](lib, "sqlite3_column_name"),
      columnType: loadFunction[ColumnType](lib, "sqlite3_column_type"),
      columnInt64: loadFunction[ColumnInt64](lib, "sqlite3_column_int64"),
      columnDouble: loadFunction[ColumnDouble](lib, "sqlite3_column_double"),
      columnText: loadFunction[ColumnText](lib, "sqlite3_column_text"),
      columnBlob: loadFunction[ColumnBlob](lib, "sqlite3_column_blob"),
      columnBytes: loadFunction[ColumnBytes](lib, "sqlite3_column_bytes"),
      changes: loadFunction[Changes](lib, "sqlite3_changes"),
      totalChanges: loadFunction[TotalChanges](lib, "sqlite3_total_changes"),
      lastInsertRowId: loadFunction[LastInsertRowId](lib, "sqlite3_last_insert_rowid"),
      interrupt: loadFunction[Interrupt](lib, "sqlite3_interrupt"),
    )
  except CatchableError as error:
    unloadLib(lib)
    sqliteApiError = error.msg
    raise

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

proc open*(path: string; options = OpenOptions()): Database =
  ## Opens a database path or `:memory:` and enables foreign-key constraints.
  if path.len == 0 or '\0' in path:
    raise newException(ValueError, "sqlite: database path must be nonempty and contain no NUL")
  loadSqliteApi()
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

proc runLocked(db: SqliteDb; sql: string; params: openArray[SqlValue];
               collectRows: bool; internal = false;
               cancelled: proc(): bool {.closure.} = nil):
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

proc isClosing(db: Database): bool =
  db.handleMutex.acquire()
  result = db.closing or db.handle == nil
  db.handleMutex.release()

proc execute*(db: Database; sql: string;
              params: openArray[SqlValue] = [];
              cancelled: proc(): bool {.closure.} = nil): SqlResult =
  ## Executes one statement and consumes rows from RETURNING clauses.
  if db == nil: raise newException(ValueError, "sqlite: database is closed")
  db.mutex.acquire()
  defer: db.mutex.release()
  db.requireOpen()
  let shouldStop = proc(): bool =
    db.isClosing() or (cancelled != nil and cancelled())
  runLocked(db.handle, sql, params, false, cancelled = shouldStop).execution

proc query*(db: Database; sql: string;
            params: openArray[SqlValue] = [];
            cancelled: proc(): bool {.closure.} = nil): SqlRows =
  ## Queries one statement, preserving column order and SQLite value types.
  if db == nil: raise newException(ValueError, "sqlite: database is closed")
  db.mutex.acquire()
  defer: db.mutex.release()
  db.requireOpen()
  let shouldStop = proc(): bool =
    db.isClosing() or (cancelled != nil and cancelled())
  runLocked(db.handle, sql, params, true, cancelled = shouldStop).rows

proc control(db: SqliteDb; sql: string) =
  discard runLocked(db, sql, [], false, internal = true)

proc transaction*(db: Database;
                  statements: openArray[SqlStatement];
                  cancelled: proc(): bool {.closure.} = nil): seq[SqlResult] =
  ## Runs the statements in order under BEGIN IMMEDIATE and rolls back on error.
  if db == nil: raise newException(ValueError, "sqlite: database is closed")
  db.mutex.acquire()
  defer: db.mutex.release()
  db.requireOpen()
  if statements.len == 0: return @[]

  let shouldStop = proc(): bool =
    db.isClosing() or (cancelled != nil and cancelled())

  control(db.handle, "BEGIN IMMEDIATE")
  var committed = false
  try:
    for statement in statements:
      if shouldStop(): raise newException(ValueError, "sqlite: operation canceled")
      result.add runLocked(db.handle, statement.sql, statement.params, false,
        cancelled = shouldStop).execution
    if shouldStop(): raise newException(ValueError, "sqlite: operation canceled")
    control(db.handle, "COMMIT")
    committed = true
  except CatchableError:
    if not committed:
      try: control(db.handle, "ROLLBACK")
      except CatchableError: discard
    raise
