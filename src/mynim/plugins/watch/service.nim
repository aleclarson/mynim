## Page-owned file watches, restricted to roots granted by the app.

import std/[json, os, strutils, tables, times, unicode]
import core/locks

import mynim as core
import mynim/internal/platform as platform

type
  IgnoreFile* = proc(path: string; isDir: bool): bool {.closure.}

  Root* = object
    ## A file or directory pages may watch under the supplied alias.
    path*: string
    recursive*: bool
    ignore*: IgnoreFile

  Request* = object
    root*, path*: string
    recursive*: bool
    debounceMs: int

  ResolveRoot* = proc(ctx: core.CancelCtx; name: string):
      tuple[root: Root, found: bool] {.closure.}

  AllowWatch* = proc(ctx: core.CancelCtx; request: Request): bool {.closure.}

  Options* = object
    roots*: Table[string, Root]
    resolve*: ResolveRoot
    allow*: AllowWatch
    maxWatchesPerPage*, maxWatches*: int

  WatchFailure = object of CatchableError
    code: string

  ActiveWatch = ref object
    page: pointer
    ctx: core.CancelCtx

  Service = ref object
    options: Options
    roots: Table[string, Root]
    identities: Table[string, FileInfo]
    mutex: Lock
    active: seq[ActiveWatch]

const
  codeDenied = "denied"
  codeLimit = "limit"
  codeNotFound = "not-found"
  codeUnsupported = "unsupported"
  codeEncoding = "path-encoding"
  codeIo = "io"
  defaultWatchesPerPage = 8
  defaultWatches = 128

proc fail(code: string): ref WatchFailure =
  result = newException(WatchFailure, "filesystem watch " &
    code.replace('-', ' '))
  result.code = code

proc validAlias(name: string): bool =
  if name.len == 0 or name.len > 64 or name[0] notin {'a'..'z'}:
    return false
  for ch in name:
    if ch notin {'a'..'z', '0'..'9', '-'}: return false
  true

proc validRelativePath(path: string): bool =
  if path == ".": return true
  if path.len == 0 or path[0] == '/' or '\\' in path or '\0' in path:
    return false
  when defined(windows):
    if ':' in path: return false
  for part in path.split('/'):
    if part.len == 0 or part in [".", ".."]: return false
  true

proc canonicalRoot(root: Root): tuple[root: Root, info: FileInfo] =
  if not isAbsolute(root.path): raise fail(codeDenied)
  let path = try: expandFilename(root.path)
    except OSError: raise
    except CatchableError: raise fail(codeDenied)
  let info = getFileInfo(path, followSymlink = false)
  if info.kind notin {pcDir, pcFile}: raise fail(codeDenied)
  var current = parentDir(path)
  while current.len > 0 and current != path:
    let parentInfo = getFileInfo(current, followSymlink = false)
    if parentInfo.kind != pcDir: raise fail(codeDenied)
    let parent = parentDir(current)
    if parent == current: break
    current = parent
  result.root = root
  result.root.path = path
  result.info = info

proc resolveTarget(root: Root; relative: string):
    tuple[path: string, isDir: bool] =
  if relative == ".":
    let info = getFileInfo(root.path, followSymlink = false)
    if info.kind notin {pcDir, pcFile}: raise fail(codeDenied)
    return (root.path, info.kind == pcDir)
  var current = root.path
  let parts = relative.split('/')
  for i, part in parts:
    current = current / part
    let info = getFileInfo(current, followSymlink = false)
    if info.kind notin {pcDir, pcFile}: raise fail(codeDenied)
    if i < parts.high and info.kind != pcDir: raise fail(codeDenied)
    if i == parts.high: return (current, info.kind == pcDir)

proc samePath(a, b: string): bool =
  when defined(windows): a.toLowerAscii() == b.toLowerAscii()
  else: a == b

proc missingPath(error: ref CatchableError): bool =
  if error == nil or not (error of OSError): return false
  let code = cast[ref OSError](error).errorCode
  when defined(windows): code == 2'i32 or code == 3'i32
  else: code == 2'i32

proc errorCode(error: ref CatchableError): string =
  if error == nil: return codeIo
  if error of WatchFailure:
    return cast[ref WatchFailure](error).code
  if platform.isErrUnsupported(error): return codeUnsupported
  if missingPath(error): return codeNotFound
  if "entry limit exceeded" in error.msg: return codeLimit
  codeIo

proc outcome(code = ""): JsonNode =
  result = newJObject()
  if code.len > 0:
    result["code"] = %code
    result["message"] = %("filesystem watch " & code.replace('-', ' '))

proc parseRequest(value: JsonNode): Request =
  if value == nil or value.kind != JObject: raise fail(codeDenied)
  if not value.hasKey("root") or value["root"].kind != JString:
    raise fail(codeDenied)
  result.root = value["root"].getStr()
  if value.hasKey("path"):
    if value["path"].kind != JString: raise fail(codeDenied)
    result.path = value["path"].getStr()
  if result.path.len == 0: result.path = "."
  if value.hasKey("recursive"):
    if value["recursive"].kind != JBool: raise fail(codeDenied)
    result.recursive = value["recursive"].getBool()
  if value.hasKey("debounceMs"):
    if value["debounceMs"].kind != JInt: raise fail(codeDenied)
    result.debounceMs = value["debounceMs"].getInt()

proc combineRelative(base, child: string): string =
  if base == ".": return child
  if child == ".": return base
  base & "/" & child

proc fileEvent(value: core.FileEvent): JsonNode =
  result = newJObject()
  result["op"] = %value.op
  result["path"] = %value.path
  if value.oldPath.len > 0: result["oldPath"] = %value.oldPath
  result["isDir"] = %value.isDir

proc eventPart(events: openArray[core.FileEvent]): JsonNode =
  result = newJObject()
  result["type"] = %"events"
  var values = newJArray()
  for item in events: values.add fileEvent(item)
  result["events"] = values

proc validUtf8(events: openArray[core.FileEvent]): bool =
  for item in events:
    if item.path.validateUtf8() >= 0 or item.oldPath.validateUtf8() >= 0:
      return false
  true

proc pageKey(context: core.CallContext): pointer =
  cast[pointer](context.page)

proc activeCount(service: Service; page: pointer): int =
  for watch in service.active:
    if watch.page == page and not watch.ctx.done(): inc result

proc removeActive(service: Service; active: ActiveWatch) =
  service.mutex.acquire()
  for i, item in service.active:
    if item == active:
      service.active.delete(i)
      break
  service.mutex.release()

proc findRoot(service: Service; context: core.CallContext; name: string):
    tuple[root: Root, info: FileInfo] =
  if not validAlias(name): raise fail(codeDenied)
  if service.roots.hasKey(name):
    let configured = service.roots[name]
    let canonical = canonicalRoot(configured)
    let identity = service.identities[name]
    if identity.kind == pcDir and canonical.info.id != identity.id:
      raise fail(codeIo)
    return canonical
  if service.options.resolve == nil: raise fail(codeDenied)
  let resolved = service.options.resolve(context.ctx, name)
  if not resolved.found: raise fail(codeDenied)
  canonicalRoot(resolved.root)

proc watch(service: Service; context: core.CallContext; request: Request;
           channel: core.Channel[JsonNode]): JsonNode =
  try:
    if context == nil or context.page == nil: return outcome(codeDenied)
    if not validAlias(request.root) or not validRelativePath(request.path):
      return outcome(codeDenied)
    if request.debounceMs > 60000: return outcome(codeLimit)

    let granted = service.findRoot(context, request.root)
    let (target, isDir) = resolveTarget(granted.root, request.path)
    if (request.recursive and not granted.root.recursive) or
        (not granted.root.recursive and request.path != "." and
         (isDir or '/' in request.path)):
      return outcome(codeDenied)
    if service.options.allow != nil and
        not service.options.allow(context.ctx, request):
      return outcome(codeDenied)
    if context.ctx.done(): return outcome()

    let active = ActiveWatch(page: pageKey(context), ctx: context.ctx)
    service.mutex.acquire()
    let overLimit = service.active.len >= service.options.maxWatches or
      service.activeCount(active.page) >= service.options.maxWatchesPerPage
    if not overLimit: service.active.add active
    service.mutex.release()
    if overLimit: return outcome(codeLimit)
    defer: service.removeActive(active)

    var options = core.FileWatchOptions(recursive: request.recursive,
      debounce: initDuration(milliseconds = int64(request.debounceMs)))
    if granted.root.ignore != nil:
      let base = request.path
      let ignore = granted.root.ignore
      options.ignore = proc(path: string; directory: bool): bool =
        ignore(combineRelative(base, path), directory)
    let (watcher, startError) = core.watchFiles(context.ctx, target, options)
    if startError != nil:
      return outcome(errorCode(startError))
    if watcher == nil: return outcome(codeIo)
    defer:
      discard watcher.close()
      watcher.waitDone()
    if not samePath(watcher.root, target): return outcome(codeDenied)
    if channel.send(%*{"type": "ready"}) != nil: return outcome()

    while not context.ctx.done():
      let (events, nextError) = watcher.next(context.ctx)
      if nextError != nil:
        if core.isFileWatchEOF(nextError) or context.ctx.done(): return outcome()
        return outcome(errorCode(nextError))
      if not validUtf8(events): return outcome(codeEncoding)
      if channel.send(eventPart(events)) != nil: return outcome()
    outcome()
  except CatchableError as error:
    if context != nil and context.ctx != nil and context.ctx.done():
      return outcome()
    outcome(errorCode(error))

proc watchMethod(service: Service): core.BoundMethod =
  result = proc(context: core.CallContext; args: seq[JsonNode]):
      tuple[v: JsonNode, err: ref CatchableError] =
    let channel = core.channelArg[JsonNode](context, 0)
    if channel == nil:
      return (outcome(codeDenied), nil)
    try:
      if args.len == 0: raise fail(codeDenied)
      let request = parseRequest(args[0])
      (service.watch(context, request, channel), nil)
    except CatchableError as error:
      (outcome(errorCode(error)), nil)

proc newWatchPlugin*(options: Options): core.Plugin =
  ## Creates the page watch plugin with explicitly granted roots.
  var configured = options
  configured.roots = initTable[string, Root]()
  for name, root in options.roots:
    configured.roots[name] = root
  if configured.maxWatchesPerPage == 0:
    configured.maxWatchesPerPage = defaultWatchesPerPage
  if configured.maxWatches == 0:
    configured.maxWatches = defaultWatches
  let service = Service(options: configured,
    roots: initTable[string, Root](), identities: initTable[string, FileInfo]())
  service.mutex.initLock()
  result.name = "watch"
  result.service = @[("Watch", watchMethod(service))]
  result.setup = proc(): ref CatchableError =
    if service.options.maxWatchesPerPage < 0 or service.options.maxWatches < 0:
      return newException(ValueError, "watch: negative quota")
    for name, root in service.options.roots:
      if not validAlias(name):
        return newException(ValueError, "watch: invalid root alias " & name.escape())
      try:
        let canonical = canonicalRoot(root)
        service.roots[name] = canonical.root
        service.identities[name] = canonical.info
      except CatchableError as error:
        return newException(ValueError,
          "watch: root " & name.escape() & ": " & error.msg)
    core.bindChannels("plugin:watch", "Watch", [1])
    nil

proc newWatchPlugin*(): core.Plugin =
  ## Creates the page watch plugin without granted roots.
  newWatchPlugin(Options(maxWatchesPerPage: defaultWatchesPerPage,
    maxWatches: defaultWatches))
