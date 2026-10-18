import std/[os, strutils, unittest]

import mynim/plugins/sqlite/db as sqliteDb

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
