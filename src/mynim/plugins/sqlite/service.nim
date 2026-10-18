## Page-owned SQLite connections and their JSON IPC wire format.

import std/[base64, json, math, os, strutils, tables]
import core/locks

import mynim as core
import mynim/plugins/sqlite/db as sqliteDb

type
  Options* = object
    ## Database files opened by pages are restricted to names in this directory.
    directory*: string
    ## SQLite lock wait in milliseconds; zero selects five seconds.
    busyTimeoutMs*: int

  Connection = ref object
    db: sqliteDb.Database
    stopPage: proc(): bool {.closure.}

  ConnectionKey = tuple[page: pointer, id: string]

  Service = ref object
    options: Options
    mutex: Lock
    connections: Table[ConnectionKey, Connection]
    closed: bool

proc readString(node: JsonNode; description: string): string =
  if node == nil or node.kind != JString:
    raise newException(ValueError, "sqlite: " & description & " must be a string")
  node.getStr()

proc readWireValue(node: JsonNode): sqliteDb.SqlValue =
  if node == nil or node.kind != JObject:
    raise newException(ValueError, "sqlite: parameter must be a value object")
  let kind = readString(node.getOrDefault("type"), "value type")
  case kind
  of "null":
    sqliteDb.nullValue()
  of "integer":
    let value = readString(node.getOrDefault("integer"), "integer value")
    try: sqliteDb.integerValue(parseBiggestInt(value))
    except ValueError:
      raise newException(ValueError, "sqlite: integer exceeds signed 64-bit range")
  of "real":
    if node.hasKey("special"):
      case readString(node["special"], "real special value")
      of "Infinity": sqliteDb.realValue(Inf)
      of "-Infinity": sqliteDb.realValue(NegInf)
      of "NaN": sqliteDb.realValue(NaN)
      else: raise newException(ValueError, "sqlite: invalid special real value")
    else:
      if not node.hasKey("real") or node["real"].kind notin {JInt, JFloat}:
        raise newException(ValueError, "sqlite: real value must be a number")
      sqliteDb.realValue(node["real"].getFloat())
  of "text":
    sqliteDb.textValue(readString(node.getOrDefault("text"), "text value"))
  of "blob":
    let encoded = readString(node.getOrDefault("blob"), "blob value")
    let bytes = decode(encoded)
    var value = newSeq[byte](bytes.len)
    for index, ch in bytes: value[index] = byte(ch)
    sqliteDb.blobValue(value)
  else:
    raise newException(ValueError, "sqlite: unsupported parameter type " & kind)

proc readParams(node: JsonNode): seq[sqliteDb.SqlValue] =
  if node == nil or node.kind != JArray:
    raise newException(ValueError, "sqlite: parameters must be an array")
  for value in node.getElems(): result.add readWireValue(value)

proc wireValue(value: sqliteDb.SqlValue): JsonNode =
  result = newJObject()
  case value.kind
  of sqliteDb.sqlNull:
    result["type"] = %"null"
  of sqliteDb.sqlInteger:
    result["type"] = %"integer"
    result["integer"] = %($value.integer)
  of sqliteDb.sqlReal:
    result["type"] = %"real"
    if classify(value.real) == fcNan:
      result["special"] = %"NaN"
    elif classify(value.real) == fcInf:
      result["special"] = %"Infinity"
    elif classify(value.real) == fcNegInf:
      result["special"] = %"-Infinity"
    else:
      result["real"] = %value.real
  of sqliteDb.sqlText:
    result["type"] = %"text"
    result["text"] = %value.text
  of sqliteDb.sqlBlob:
    result["type"] = %"blob"
    var bytes = newString(value.blob.len)
    for index, item in value.blob: bytes[index] = char(item)
    result["blob"] = %encode(bytes)

proc wireResult(value: sqliteDb.SqlResult): JsonNode =
  result = newJObject()
  result["changes"] = %value.changes
  result["lastInsertId"] = %($value.lastInsertId)

proc wireRows(value: sqliteDb.SqlRows): JsonNode =
  result = newJObject()
  result["columns"] = newJArray()
  for column in value.columns: result["columns"].add %column
  result["rows"] = newJArray()
  for row in value.rows:
    var encodedRow = newJArray()
    for cell in row: encodedRow.add wireValue(cell)
    result["rows"].add encodedRow

proc databaseName(name: string) =
  if name.len == 0 or name in [".", ".."] or
      name.contains({'/', '\\', '\0', ':', '<', '>', '"', '|', '?', '*'}) or
      name.strip() != name or name.endsWith("."):
    raise newException(ValueError,
      "sqlite: use a database file name without directories, or :memory:")
  let base = name.toUpperAscii().split('.')[0]
  if base in ["CON", "PRN", "AUX", "NUL"] or
      (base.len == 4 and base[0..2] in ["COM", "LPT"] and base[3] in {'1'..'9'}):
    raise newException(ValueError, "sqlite: database file name is reserved on Windows")

proc databasePath(service: Service; name: string; readOnly: bool): string =
  if name == ":memory:": return name
  databaseName(name)
  let directory = if service.options.directory.len > 0:
      service.options.directory
    else:
      core.app.path(core.pathUserData)
  if readOnly:
    if not dirExists(directory):
      raise newException(IOError, "sqlite: database directory does not exist")
  else:
    createDir(directory)
  result = directory / name
  try:
    let info = getFileInfo(result, followSymlink = false)
    if info.kind in {pcLinkToFile, pcLinkToDir}:
      raise newException(ValueError, "sqlite: database file may not be a symbolic link")
    if info.kind != pcFile:
      raise newException(ValueError, "sqlite: database path is not a regular file")
  except OSError:
    discard # A missing file is valid for writable opens; SQLite reports read-only misses.

proc key(context: core.CallContext; id: string): ConnectionKey =
  if context == nil or context.page == nil:
    raise newException(ValueError, "sqlite: a web page must call this method")
  (cast[pointer](context.page), id)

proc callError(context: core.CallContext; error: ref CatchableError): ref CatchableError =
  if context != nil and context.ctx.done():
    result = context.ctx.err()
    if result == nil:
      result = newException(ValueError, "sqlite: operation canceled")
  else:
    result = error

proc closeConnection(service: Service; connectionKey: ConnectionKey): ref CatchableError =
  var connection: Connection
  service.mutex.acquire()
  if service.connections.hasKey(connectionKey):
    connection = service.connections[connectionKey]
    service.connections.del(connectionKey)
  service.mutex.release()
  if connection == nil: return nil
  if connection.stopPage != nil: discard connection.stopPage()
  try:
    connection.db.close()
  except CatchableError as error:
    return error

proc lookup(service: Service; connectionKey: ConnectionKey): sqliteDb.Database =
  service.mutex.acquire()
  let connection = service.connections.getOrDefault(connectionKey)
  service.mutex.release()
  if connection == nil:
    raise newException(ValueError, "sqlite: database is closed or belongs to another page")
  result = connection.db

proc openMethod(service: Service): core.BoundMethod =
  result = proc(context: core.CallContext; args: seq[JsonNode]):
      tuple[v: JsonNode, err: ref CatchableError] =
    try:
      if args.len < 1: raise newException(ValueError, "sqlite: missing database name")
      if context == nil or context.ctx.done():
        raise newException(ValueError, "sqlite: operation canceled")
      let name = readString(args[0], "database name")
      let caller = key(context, "")
      var readOnly = false
      if args.len > 1 and args[1] != nil and args[1].kind == JObject:
        readOnly = args[1].getOrDefault("readOnly").getBool(false)
      let dbPath = databasePath(service, name, readOnly)
      let db = sqliteDb.open(dbPath, sqliteDb.OpenOptions(
        readOnly: readOnly, busyTimeoutMs: service.options.busyTimeoutMs))
      let id = core.randomText()
      let connectionKey = (caller.page, id)
      let connection = Connection(db: db)

      service.mutex.acquire()
      if service.closed:
        service.mutex.release()
        db.close()
        raise newException(ValueError, "sqlite: service is closed")
      service.connections[connectionKey] = connection
      service.mutex.release()

      let ownerContext = context.pageCtx
      let stop = ownerContext.afterDone(proc() =
        discard service.closeConnection(connectionKey))
      service.mutex.acquire()
      if service.connections.hasKey(connectionKey):
        service.connections[connectionKey].stopPage = stop
        service.mutex.release()
      else:
        service.mutex.release()
        discard stop()
      return (%id, nil)
    except CatchableError as error:
      (newJNull(), callError(context, error))

proc executeMethod(service: Service): core.BoundMethod =
  result = proc(context: core.CallContext; args: seq[JsonNode]):
      tuple[v: JsonNode, err: ref CatchableError] =
    try:
      if args.len != 3: raise newException(ValueError, "sqlite: Execute expects id, SQL and parameters")
      let connectionKey = key(context, readString(args[0], "connection id"))
      let db = service.lookup(connectionKey)
      if context.ctx.done(): raise newException(ValueError, "sqlite: operation canceled")
      let value = db.execute(readString(args[1], "SQL"), readParams(args[2]),
        proc(): bool = context.ctx.done())
      (wireResult(value), nil)
    except CatchableError as error:
      (newJNull(), callError(context, error))

proc queryMethod(service: Service): core.BoundMethod =
  result = proc(context: core.CallContext; args: seq[JsonNode]):
      tuple[v: JsonNode, err: ref CatchableError] =
    try:
      if args.len != 3: raise newException(ValueError, "sqlite: Query expects id, SQL and parameters")
      let connectionKey = key(context, readString(args[0], "connection id"))
      let db = service.lookup(connectionKey)
      if context.ctx.done(): raise newException(ValueError, "sqlite: operation canceled")
      let value = db.query(readString(args[1], "SQL"), readParams(args[2]),
        proc(): bool = context.ctx.done())
      (wireRows(value), nil)
    except CatchableError as error:
      (newJNull(), callError(context, error))

proc transactionMethod(service: Service): core.BoundMethod =
  result = proc(context: core.CallContext; args: seq[JsonNode]):
      tuple[v: JsonNode, err: ref CatchableError] =
    try:
      if args.len != 2: raise newException(ValueError, "sqlite: Transaction expects id and statements")
      let connectionKey = key(context, readString(args[0], "connection id"))
      let db = service.lookup(connectionKey)
      if args[1].kind != JArray: raise newException(ValueError, "sqlite: statements must be an array")
      var statements: seq[sqliteDb.SqlStatement]
      for statement in args[1].getElems():
        if statement.kind != JObject:
          raise newException(ValueError, "sqlite: statement must be an object")
        let sql = readString(statement.getOrDefault("sql"), "statement SQL")
        let values = readParams(statement.getOrDefault("args"))
        statements.add sqliteDb.SqlStatement(sql: sql, params: values)
      if context.ctx.done(): raise newException(ValueError, "sqlite: operation canceled")
      let values = db.transaction(statements, proc(): bool = context.ctx.done())
      var wire = newJArray()
      for value in values: wire.add wireResult(value)
      (wire, nil)
    except CatchableError as error:
      (newJNull(), callError(context, error))

proc closeMethod(service: Service): core.BoundMethod =
  result = proc(context: core.CallContext; args: seq[JsonNode]):
      tuple[v: JsonNode, err: ref CatchableError] =
    try:
      if args.len != 1: raise newException(ValueError, "sqlite: Close expects a connection id")
      let error = service.closeConnection(key(context, readString(args[0], "connection id")))
      (newJNull(), error)
    except CatchableError as error:
      (newJNull(), error)

proc shutdown(service: Service) =
  var connections: seq[Connection]
  service.mutex.acquire()
  service.closed = true
  for _, connection in service.connections: connections.add connection
  service.connections.clear()
  service.mutex.release()
  for connection in connections:
    if connection.stopPage != nil: discard connection.stopPage()
    try: connection.db.close()
    except CatchableError: discard

proc newSqlitePlugin*(options: Options): core.Plugin =
  ## Creates a page plugin. Its databases live in options.directory or app data.
  var service = Service(options: options, connections: initTable[ConnectionKey, Connection]())
  service.mutex.initLock()
  result.name = "sqlite"
  result.service = @[
    ("Open", openMethod(service)),
    ("Execute", executeMethod(service)),
    ("Query", queryMethod(service)),
    ("Transaction", transactionMethod(service)),
    ("Close", closeMethod(service)),
  ]
  result.setup = proc(): ref CatchableError =
    discard core.app.onQuit(proc() = service.shutdown())
    nil

proc newSqlitePlugin*(): core.Plugin =
  ## Creates the default SQLite page plugin.
  newSqlitePlugin(Options())
