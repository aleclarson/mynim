import std/[os, strutils, unittest]

import mynim/internal/ctx as context
import mynim/plugins/sqlite/db as sqliteDb

type ContextTransactionArgs = object
  db: sqliteDb.Database
  ctx: context.CancelCtx

type BusyInsertArgs = object
  db: sqliteDb.Database
  ctx: context.CancelCtx

type ContextWaitArgs = object
  db: sqliteDb.Database
  ctx: context.CancelCtx

proc rawSqliteOpen(path: cstring; db: ptr pointer; flags: cint;
                   vfs: cstring): cint {.importc: "sqlite3_open_v2", cdecl.}
proc rawSqliteExec(db: pointer; sql: cstring; callback, userData: pointer;
                   error: ptr cstring): cint {.importc: "sqlite3_exec", cdecl.}
proc rawSqliteClose(db: pointer): cint {.importc: "sqlite3_close", cdecl.}

var
  contextTransactionStarted: Channel[bool]
  contextTransactionFinished: Channel[string]
  busyInsertStarted: Channel[bool]
  busyInsertFinished: Channel[string]
  contextWaitStarted: Channel[bool]
  contextWaitFinished: Channel[string]

proc runContextTransaction(args: ContextTransactionArgs) {.thread.} =
  {.cast(gcsafe).}:
    contextTransactionStarted.send(true)
    try:
      discard args.db.transaction(args.ctx, [
        SqlStatement(sql: "INSERT INTO items VALUES (8)"),
        SqlStatement(sql:
        "WITH RECURSIVE sequence(x) AS (SELECT 1 UNION ALL " &
        "SELECT x + 1 FROM sequence WHERE x < 1000000000) " &
        "SELECT sum(x) FROM sequence")
      ])
      contextTransactionFinished.send("completed")
    except CatchableError as error:
      contextTransactionFinished.send(error.msg)

proc runBusyInsert(args: BusyInsertArgs) {.thread.} =
  {.cast(gcsafe).}:
    busyInsertStarted.send(true)
    try:
      discard args.db.execute(args.ctx, "INSERT INTO busy_items VALUES (1)")
      busyInsertFinished.send("completed")
    except CatchableError as error:
      busyInsertFinished.send(error.msg)

proc runContextWait(args: ContextWaitArgs) {.thread.} =
  {.cast(gcsafe).}:
    contextWaitStarted.send(true)
    try:
      discard args.db.query(args.ctx, "SELECT 1")
      contextWaitFinished.send("completed")
    except CatchableError as error:
      contextWaitFinished.send(error.msg)

contextTransactionStarted.open()
contextTransactionFinished.open()
busyInsertStarted.open()
busyInsertFinished.open()
contextWaitStarted.open()
contextWaitFinished.open()

suite "SQLite database API":
  test "binds typed values and copies row data":
    let db = sqliteDb.open(":memory:")
    defer: db.close()
    discard db.execute("PRAGMA foreign_keys")
    discard db.execute("CREATE TABLE values_test (n INTEGER, r REAL, t TEXT, b BLOB)")
    let inserted = db.execute(
      "INSERT INTO values_test VALUES (?, ?, ?, ?)",
      [integerValue(high(int64)), realValue(1.25),
       textValue("a\0b"), blobValue([0'u8, 127'u8, 255'u8])])
    check inserted.changes == 1
    check inserted.lastInsertId == 1

    let rows = db.query("SELECT n, r, t, b FROM values_test")
    check rows.columns == @["n", "r", "t", "b"]
    check rows.rows.len == 1
    check rows.rows[0][0] == integerValue(high(int64))
    check rows.rows[0][1] == realValue(1.25)
    check rows.rows[0][2] == textValue("a\0b")
    check rows.rows[0][3] == blobValue([0'u8, 127'u8, 255'u8])

    let empty = db.query("SELECT '' AS value, X'' AS value, NULL AS value")
    check empty.columns == @["value", "value", "value"]
    check empty.rows[0][0] == textValue("")
    check empty.rows[0][1] == blobValue([])
    check empty.rows[0][2] == nullValue()

  test "rejects multiple statements before running the first":
    let db = sqliteDb.open(":memory:")
    defer: db.close()
    expect ValueError:
      discard db.execute("CREATE TABLE first_table(x); CREATE TABLE second_table(x)")
    let rows = db.query("SELECT name FROM sqlite_master WHERE type='table'")
    check rows.rows.len == 0
    expect ValueError:
      discard db.execute("SELECT 1", [integerValue(1)])

  test "blocks transaction control and SQL that can escape the data directory":
    let db = sqliteDb.open(":memory:")
    defer: db.close()
    for sql in [
      "-- hidden prefix\nBEGIN",
      "COMMIT",
      "ATTACH DATABASE 'outside.db' AS outside",
      "DETACH DATABASE outside",
      "VACUUM INTO 'outside.db'",
    ]:
      expect ValueError:
        discard db.execute(sql)

  test "transactions commit all results or roll back the batch":
    let db = sqliteDb.open(":memory:")
    defer: db.close()
    discard db.execute("CREATE TABLE events (value TEXT UNIQUE NOT NULL)")
    let committed = db.transaction([
      SqlStatement(sql: "INSERT INTO events VALUES (?)", params: @[textValue("a")]),
      SqlStatement(sql: "INSERT INTO events VALUES (?)", params: @[textValue("b")]),
    ])
    check committed.len == 2
    check committed[0].changes == 1
    check committed[1].changes == 1

    expect SqliteError:
      discard db.transaction([
        SqlStatement(sql: "INSERT INTO events VALUES (?)", params: @[textValue("c")]),
        SqlStatement(sql: "INSERT INTO events VALUES (?)", params: @[textValue("a")]),
      ])
    let rows = db.query("SELECT value FROM events ORDER BY value")
    check rows.rows == @[@[textValue("a")], @[textValue("b")]]
    check db.transaction([]).len == 0

  test "a canceled transaction rolls back prior statements":
    let db = sqliteDb.open(":memory:")
    defer: db.close()
    discard db.execute("CREATE TABLE items(value INTEGER)")
    var checks = 0
    let canceled = proc(): bool =
      inc checks
      checks >= 3
    expect ValueError:
      discard db.transaction([
        SqlStatement(sql: "INSERT INTO items VALUES (1)"),
        SqlStatement(sql: "INSERT INTO items VALUES (2)"),
      ], canceled)
    check db.query("SELECT count(*) FROM items").rows[0][0] == integerValue(0)

  test "direct operations accept contexts and cancel active SQLite work":
    let ctx = context.newCtx()
    let db = sqliteDb.open(ctx, ":memory:")
    defer: db.close()
    discard db.execute(ctx, "CREATE TABLE items(value INTEGER)")
    let committed = db.transaction(ctx, [
      SqlStatement(sql: "INSERT INTO items VALUES (?)", params: @[integerValue(7)])
    ])
    check committed.len == 1
    check db.query(ctx, "SELECT value FROM items").rows[0][0] == integerValue(7)

    let cancelCtx = context.newCtx()
    var worker: Thread[ContextTransactionArgs]
    createThread(worker, runContextTransaction,
      ContextTransactionArgs(db: db, ctx: cancelCtx))
    discard contextTransactionStarted.recv()
    sleep(10)

    let waitCtx = context.newCtx()
    var waiter: Thread[ContextWaitArgs]
    createThread(waiter, runContextWait, ContextWaitArgs(db: db, ctx: waitCtx))
    discard contextWaitStarted.recv()
    sleep(10)
    waitCtx.cancel()
    var waitReceived = false
    var waitMessage = ""
    for _ in 0 ..< 1000:
      let response = contextWaitFinished.tryRecv()
      if response.dataAvailable:
        waitReceived = true
        waitMessage = response.msg
        break
      sleep(1)
    if not waitReceived: cancelCtx.cancel()
    joinThread(waiter)
    check waitReceived
    check "canceled" in waitMessage
    if waitReceived:
      check not contextTransactionFinished.tryRecv().dataAvailable

    cancelCtx.cancel()

    var received = false
    var message = ""
    for _ in 0 ..< 1000:
      let response = contextTransactionFinished.tryRecv()
      if response.dataAvailable:
        received = true
        message = response.msg
        break
      sleep(1)
    if not received:
      db.interrupt()
      for _ in 0 ..< 1000:
        let response = contextTransactionFinished.tryRecv()
        if response.dataAvailable:
          message = response.msg
          break
        sleep(1)
    joinThread(worker)
    check received
    check "canceled" in message
    check db.query(ctx, "SELECT value FROM items").rows ==
      @[@[integerValue(7)]]

  test "cancellation interrupts a SQLite file-lock wait":
    let path = getTempDir() / ("mynim-sqlite-busy-" &
      $getCurrentProcessId() & ".db")
    if fileExists(path): removeFile(path)
    let db = sqliteDb.open(path, OpenOptions(busyTimeoutMs: 5000))
    discard db.execute("CREATE TABLE busy_items(value INTEGER)")
    var lockDb: pointer
    check rawSqliteOpen(path.cstring, addr lockDb,
      0x00000002.cint or 0x00000004.cint or 0x00010000.cint, nil) == 0
    check rawSqliteExec(lockDb, "BEGIN IMMEDIATE", nil, nil, nil) == 0

    let ctx = context.newCtx()
    var worker: Thread[BusyInsertArgs]
    createThread(worker, runBusyInsert, BusyInsertArgs(db: db, ctx: ctx))
    discard busyInsertStarted.recv()
    sleep(20)
    ctx.cancel()

    var received = false
    var message = ""
    for _ in 0 ..< 1000:
      let response = busyInsertFinished.tryRecv()
      if response.dataAvailable:
        received = true
        message = response.msg
        break
      sleep(1)
    if not received:
      discard rawSqliteExec(lockDb, "ROLLBACK", nil, nil, nil)
      for _ in 0 ..< 1000:
        let response = busyInsertFinished.tryRecv()
        if response.dataAvailable:
          message = response.msg
          break
        sleep(1)
    joinThread(worker)
    discard rawSqliteExec(lockDb, "ROLLBACK", nil, nil, nil)
    discard rawSqliteClose(lockDb)
    db.close()
    if fileExists(path): removeFile(path)
    check received
    check "canceled" in message

  test "requires valid UTF-8 database paths":
    for invalid in ["\xff", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80"]:
      expect ValueError:
        discard sqliteDb.open(":memory:" & invalid)

    let path = getTempDir() / ("mynim-sqlite-\xc3\xa9-" &
      $getCurrentProcessId() & ".db")
    defer:
      if fileExists(path): removeFile(path)
    let db = sqliteDb.open(path)
    db.close()

  test "supports read-only opens and idempotent close":
    let path = getTempDir() / ("mynim-sqlite-" & $getCurrentProcessId() & ".db")
    if fileExists(path): removeFile(path)
    block:
      let writable = sqliteDb.open(path)
      discard writable.execute("CREATE TABLE items(value TEXT)")
      writable.close()
      writable.close()
    let readonly = sqliteDb.open(path, OpenOptions(readOnly: true))
    expect SqliteError:
      discard readonly.execute("INSERT INTO items VALUES ('no')")
    check readonly.query("SELECT count(*) FROM items").rows[0][0] == integerValue(0)
    readonly.close()
    expect ValueError:
      discard readonly.query("SELECT 1")
    removeFile(path)

  test "reports SQLite constraint codes":
    let db = sqliteDb.open(":memory:")
    defer: db.close()
    discard db.execute("CREATE TABLE unique_values(value TEXT UNIQUE)")
    discard db.execute("INSERT INTO unique_values VALUES ('x')")
    try:
      discard db.execute("INSERT INTO unique_values VALUES ('x')")
      check false
    except SqliteError as error:
      check error.code == 19
      check error.extendedCode == 2067
      check error.msg.contains("UNIQUE constraint failed")

  test "bundled build includes FTS5 and R*Tree without loadable extensions":
    let db = sqliteDb.open(":memory:")
    defer: db.close()
    discard db.execute("CREATE VIRTUAL TABLE documents USING fts5(body)")
    discard db.execute("INSERT INTO documents VALUES ('searchable text')")
    check db.query("SELECT body FROM documents WHERE documents MATCH 'searchable'")
      .rows[0][0] == textValue("searchable text")

    discard db.execute("CREATE VIRTUAL TABLE points USING rtree(id, left, right)")
    discard db.execute("INSERT INTO points VALUES (1, 2.0, 3.0)")
    check db.query("SELECT id FROM points WHERE left <= 2.0 AND right >= 2.0")
      .rows[0][0] == integerValue(1)
    expect SqliteError:
      discard db.execute("SELECT load_extension('missing')")
