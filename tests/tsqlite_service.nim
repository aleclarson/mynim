import std/[base64, json, os, unittest]

import mynim as core
import mynim/internal/ctx
import mynim/plugins/sqlite/service

type TestPage = typeof(default(core.CallContext).page)

proc makeContext(page: TestPage; pageCtx: CancelCtx): core.CallContext =
  core.CallContext(page: page, pageCtx: pageCtx, ctx: pageCtx)

proc invoke(plugin: core.Plugin; methodIndex: int; context: core.CallContext;
            args: seq[JsonNode]): tuple[v: JsonNode, err: ref CatchableError] =
  plugin.service[methodIndex].fn(context, args)

suite "SQLite page plugin":
  test "wire calls work and connections are page-owned":
    let directory = getTempDir() / ("mynim-sqlite-service-" & $getCurrentProcessId())
    if dirExists(directory): removeDir(directory)
    let plugin = newSqlitePlugin(Options(directory: directory))
    let page = TestPage()
    let context = makeContext(page, newCtx())
    let opened = invoke(plugin, 0, context, @[%"notes.db", %*{"readOnly": false}])
    check opened.err == nil
    let id = opened.v.getStr()

    let created = invoke(plugin, 1, context, @[
      %id,
      %"CREATE TABLE notes (body TEXT, data BLOB)",
      newJArray(),
    ])
    check created.err == nil

    let inserted = invoke(plugin, 1, context, @[
      %id,
      %"INSERT INTO notes VALUES (?, ?)",
      %*[
        {"type": "text", "text": "hello"},
        {"type": "blob", "blob": encode("\x00\xff")},
      ],
    ])
    check inserted.err == nil
    check inserted.v["changes"].getInt() == 1

    let queried = invoke(plugin, 2, context, @[
      %id, %"SELECT body, data FROM notes", newJArray(),
    ])
    check queried.err == nil
    check queried.v["columns"] == %*["body", "data"]
    check queried.v["rows"][0][0] == %*{"type": "text", "text": "hello"}
    check queried.v["rows"][0][1] == %*{"type": "blob", "blob": encode("\x00\xff")}

    let createdCounters = invoke(plugin, 1, context, @[
      %id, %"CREATE TABLE counters (value INTEGER UNIQUE)", newJArray(),
    ])
    check createdCounters.err == nil
    let committed = invoke(plugin, 3, context, @[
      %id,
      %*[
        {"sql": "INSERT INTO counters VALUES (?)", "args": [{"type": "integer", "integer": "1"}]},
        {"sql": "INSERT INTO counters VALUES (?)", "args": [{"type": "integer", "integer": "2"}]},
      ],
    ])
    check committed.err == nil
    check committed.v.len == 2
    check committed.v[0]["changes"].getInt() == 1

    let otherPage = makeContext(TestPage(), newCtx())
    let denied = invoke(plugin, 2, otherPage, @[
      %id, %"SELECT 1", newJArray(),
    ])
    check denied.err != nil

    let closed = invoke(plugin, 4, context, @[%id])
    check closed.err == nil
    let afterClose = invoke(plugin, 2, context, @[
      %id, %"SELECT 1", newJArray(),
    ])
    check afterClose.err != nil
    removeDir(directory)

  test "navigation closes page-owned databases":
    let directory = getTempDir() / ("mynim-sqlite-cancel-" & $getCurrentProcessId())
    if dirExists(directory): removeDir(directory)
    let plugin = newSqlitePlugin(Options(directory: directory))
    let pageCtx = newCtx()
    let context = makeContext(TestPage(), pageCtx)
    let opened = invoke(plugin, 0, context, @[%"nav.db", %*{}])
    check opened.err == nil
    pageCtx.cancel()
    let result = invoke(plugin, 2, context, @[
      opened.v, %"SELECT 1", newJArray(),
    ])
    check result.err != nil
    removeDir(directory)

  test "rejects paths, symlinks and Windows device names":
    let directory = getTempDir() / ("mynim-sqlite-names-" & $getCurrentProcessId())
    if dirExists(directory): removeDir(directory)
    createDir(directory)
    let plugin = newSqlitePlugin(Options(directory: directory))
    let context = makeContext(TestPage(), newCtx())
    for name in ["../escape.db", "a/b.db", "CON.txt", "bad."]:
      let opened = invoke(plugin, 0, context, @[%name, %*{}])
      check opened.err != nil
    when not defined(windows):
      let target = directory / "target.db"
      writeFile(target, "")
      createSymlink(target, directory / "link.db")
      let linked = invoke(plugin, 0, context, @[%"link.db", %*{}])
      check linked.err != nil
    removeDir(directory)
