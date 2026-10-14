## files.nim: files dropped on a window have no paths in browsers: the
## backend reads them as they drop and keeps them at paths of its own,
## as /mygo-drop/3/photo.png, which fileDrop gives, and which
## open/readFile/stat/readDir read, through the fs object the wasm
## runtime calls (wasm_exec.js's, whose functions fail there): the
## backend answers for its paths and passes the others on.

## dropRoot is the directory of the files dropped, one directory for
## each drop.
const dropRoot = "/mygo-drop"

## keptDrops is how many drops the backend keeps the files of: the
## oldest go, with their memory.
const keptDrops = 16

## add keeps the files of a drop, by name, and returns their paths.
proc add*(d: var dropped, names: seq[string],
          data: seq[seq[byte]]): seq[string] =
  inc d.n
  let dir = dropRoot & "/" & $d.n
  d.drops.add dir
  if d.drops.len > keptDrops:
    let old = d.drops[0]
    d.drops.delete(0)
    for p in toSeq(keys(d.files)):
      if p.startsWith(old & "/"):
        d.files.del(p)
  let now = getTime()
  result = @[]
  for i, name in names:
    # A name is a file's, never a path: browsers give no folders.
    let safe = name.replace("/", "_")
    var p = dir & "/" & safe
    var k = 2
    while d.files.hasKey(p):
      p = dir & "/" & $k & "-" & safe
      inc k
    d.files[p] = droppedFile(data: data[i], time: now)
    result.add p

## isDir reports whether p is the root of the drops or a drop's
## directory.
proc isDir*(d: var dropped, p: string): bool =
  p == dropRoot or p in d.drops

## list returns the names in directory p.
proc list*(d: var dropped, p: string): seq[string] =
  result = @[]
  if p == dropRoot:
    for dir in d.drops:
      result.add lastPathPart(dir)
    return
  for f in keys(d.files):
    if parentDir(f) == p:
      result.add lastPathPart(f)
  result.sort()

## jsTrueDir/jsFalseDir are the isDirectory methods of stats: of
## directories and of files.
var
  jsTrueDir: JsValue
  jsFalseDir: JsValue

## statOf returns the stat of a file dropped, or of a directory for nil,
## as Node's fs gives it.
proc statOf(f: droppedFile, t: Time): JsValue =
  var mode = 0o40555
  var size = 0 # a directory, read only
  if not f.isNil:
    mode = 0o100444
    size = f.data.len
  let ms = float64(t.toUnix() * 1000 + t.nanosecond div 1_000_000)
  let st = jsObj()
  for (k, v) in [("dev", 0), ("ino", 0), ("nlink", 1), ("uid", 0),
               ("gid", 0), ("rdev", 0), ("blksize", 4096)]:
    jsSet(st, k, jsValueOf(v))
  jsSet(st, "mode", jsValueOf(mode))
  jsSet(st, "size", jsValueOf(size))
  jsSet(st, "blocks", jsValueOf((size + 511) div 512))
  for k in ["atimeMs", "mtimeMs", "ctimeMs"]:
    jsSet(st, k, jsValueOf(ms))
  jsSet(st, "isDirectory",
        if f.isNil: jsTrueDir else: jsFalseDir)
  st

## fsError returns an error of Node's fs, which the syscall layer reads
## the code of.
proc fsError(code: string): JsValue =
  let e = jsNew(jsGet(jsGlobal(), "Error"), [jsValueOf(code)])
  jsSet(e, "code", jsValueOf(code))
  e

proc ours(fs: JsValue, p: JsValue): tuple[path: string, ok: bool] =
  if jsType(p) != jsStringT:
    return ("", false)
  let s = normalizedPath(jsString(p))
  (s, s == dropRoot or s.startsWith(dropRoot & "/"))

## installFiles has the fs object answer for the paths of the files
## dropped.
proc installFiles*() =
  let fs = jsGet(jsGlobal(), "fs")
  if jsIsUndefined(fs):
    return
  jsTrueDir = jsFuncOf(proc(this: JsValue, args: seq[JsValue]): JsValue =
    jsTrueV)
  jsFalseDir = jsFuncOf(proc(this: JsValue, args: seq[JsValue]): JsValue =
    jsFalseV)

  # The flags of opening to write, as the fs object numbers them (-1 in
  # browsers, where it writes nothing).
  var writes = 0
  for flag in ["O_WRONLY", "O_RDWR", "O_CREAT", "O_TRUNC", "O_APPEND"]:
    let v = jsGet(jsGet(fs, "constants"), flag)
    if jsType(v) == jsNumber:
      writes = writes or jsInt(v)

  proc wrap(name: string,
            fn: proc(args: seq[JsValue], cb: JsValue): bool) =
    let orig = jsGet(fs, name)
    jsSet(fs, name, jsFuncOf(
      proc(this: JsValue, args: seq[JsValue]): JsValue =
        if args.len > 0 and fn(args[0 ..< ^1], args[^1]):
          return jsUndef
        # through to the fs object's own function
        jsCall(orig, "apply", [this, jsArrayOf(args)])))

  proc stat(args: seq[JsValue], cb: JsValue): bool =
    let (p, ok) = ours(fs, args[0])
    if not ok:
      return false
    if drops.isDir(p):
      discard jsInvoke(cb, [jsNullV, statOf(nil, getTime())])
    elif drops.files.hasKey(p):
      let f = drops.files[p]
      discard jsInvoke(cb, [jsNullV, statOf(f, f.time)])
    else:
      discard jsInvoke(cb, [fsError("ENOENT")])
    true

  wrap("stat", stat)
  wrap("lstat", stat)
  wrap("open", proc(args: seq[JsValue], cb: JsValue): bool =
    let (p, ok) = ours(fs, args[0])
    if not ok:
      return false
    let f = if drops.files.hasKey(p): drops.files[p] else: nil
    if f.isNil and not drops.isDir(p):
      discard jsInvoke(cb, [fsError("ENOENT")])
    elif args.len > 1 and jsType(args[1]) == jsNumber and
        (jsInt(args[1]) and writes) != 0:
      discard jsInvoke(cb, [fsError("EROFS")])
    else:
      inc drops.fd
      drops.fds[drops.fd] = webOpenFile(path: p, f: f)
      discard jsInvoke(cb, [jsNullV, jsValueOf(drops.fd)])
    true)

  proc fd(v: JsValue): webOpenFile =
    if jsType(v) != jsNumber:
      return nil
    drops.fds.getOrDefault(jsInt(v))

  wrap("fstat", proc(args: seq[JsValue], cb: JsValue): bool =
    let o = fd(args[0])
    if o.isNil:
      return false
    if o.f.isNil:
      discard jsInvoke(cb, [jsNullV, statOf(nil, getTime())])
    else:
      discard jsInvoke(cb, [jsNullV, statOf(o.f, o.f.time)])
    true)
  wrap("read", proc(args: seq[JsValue], cb: JsValue): bool =
    let o = fd(args[0])
    if o.isNil:
      return false
    if o.f.isNil:
      discard jsInvoke(cb, [fsError("EISDIR")])
      return true
    let buf = args[1]
    let offset = jsInt(args[2])
    let length = jsInt(args[3])
    var at = o.at
    var advance = true
    if args.len > 4 and jsType(args[4]) == jsNumber:
      at = jsInt(args[4]) # pread
      advance = false
    let n = min(length, max(o.f.data.len - at, 0))
    if n > 0:
      let sub = jsCall(buf, "subarray",
                       [jsValueOf(offset), jsValueOf(offset + n)])
      var bytes = o.f.data[at ..< at + n]
      jsCopyToJS(sub, bytes)
      if advance:
        o.at = at + n
    discard jsInvoke(cb, [jsNullV, jsValueOf(n)])
    true)
  wrap("close", proc(args: seq[JsValue], cb: JsValue): bool =
    if fd(args[0]).isNil:
      return false
    drops.fds.del(jsInt(args[0]))
    discard jsInvoke(cb, [jsNullV])
    true)
  wrap("readdir", proc(args: seq[JsValue], cb: JsValue): bool =
    let (p, ok) = ours(fs, args[0])
    if not ok:
      return false
    if not drops.isDir(p):
      discard jsInvoke(cb, [fsError("ENOTDIR")])
      return true
    var vals: seq[JsValue]
    for name in drops.list(p):
      vals.add jsValueOf(name)
    discard jsInvoke(cb, [jsNullV, jsArrayOf(vals)])
    true)
