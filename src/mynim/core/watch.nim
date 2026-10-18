## watch.go and watch_scan.go — public file watches and the snapshot
## engine that turns native notices into stable file events.

const
  FileCreate* = "create"
  FileWrite* = "write"
  FileRemove* = "remove"
  FileRename* = "rename"
  watchNoticeLimit = 4096

when defined(macosx):
  const defaultWatchMaxEntries = 65536
else:
  const defaultWatchMaxEntries = 8192

type
  FileOp* = string
  FileEvent* = object
    ## A change relative to the watched root. Paths use slash separators;
    ## "." names the watched file or directory itself.
    op*: FileOp
    path*: string
    oldPath*: string
    isDir*: bool
  FileWatchIgnore* = proc(path: string; isDir: bool): bool {.closure.}
  FileWatchOptions* = object
    recursive*: bool
    ignore*: FileWatchIgnore
    debounce*: Duration
    maxDelay*: Duration
    maxEntries*: int
  FileWatchResult = object
    events: seq[FileEvent]
    err: ref CatchableError
  FileWatchWaiter = ref object
    ch: system.Channel[FileWatchResult]
  FileWatcher* = ref object
    mu: Lock
    cv: Cond
    batch: seq[FileEvent]
    hasBatch: bool
    waiters: seq[FileWatchWaiter]
    stopped: bool
    stopErr: ref CatchableError
    finished: bool
    taken: bool
    raw: seq[FileWatchNotice]
    overflow: bool
    ctx: CancelCtx
    cancelCtx: proc() {.closure.}
    stopCtx: proc(): bool {.closure.}
    stopParentCtx: proc(): bool {.closure.}
    native: platform.FileWatch
    root: string
    rootDir: string
    rootName: string
    file: bool
    recursive: bool
    ignore: FileWatchIgnore
    debounceMs: int
    maxDelayMs: int
    maxEntries: int
    ready: system.Channel[ref CatchableError]
    thread: Thread[FileWatcher]

  WatchSnapshot = object
    entries: Table[string, FileInfo]
    rootDirInfo: FileInfo
  WatchScanner = ref object
    watcher: FileWatcher
    native: platform.FileWatch
    entries: Table[string, FileInfo]
    targets: Table[string, FileWatchTarget]
    ids: Table[uint64, string]
    nextID: uint64
    rootDirInfo: FileInfo
    noSubtree: bool
    subtree: bool
var
  fileWatchRegistryLock: Lock
  fileWatchRegistryStopped: bool
  activeFileWatches: seq[FileWatcher]

proc waitDone*(w: FileWatcher)

proc watchError(msg: string): ref CatchableError =
  newException(IOError, "mynim: file watch: " & msg)

proc watchClosedError(): ref CatchableError =
  newException(IOError, "EOF")

proc isFileWatchEOF*(err: ref CatchableError): bool =
  ## Reports whether next returned the end-of-watch condition.
  err != nil and err.msg == "EOF"

proc sameWatchFile(a, b: FileInfo): bool = a.id == b.id

proc watchInaccessible(err: ref CatchableError): bool =
  if err == nil or not (err of OSError):
    return false
  let code = cast[ref OSError](err).errorCode
  when defined(windows):
    code == 5'i32
  else:
    code == 1'i32 or code == 13'i32

proc slashPath(path: string): string = path.replace('\\', '/')

proc watchPath(w: FileWatcher; relative: string): string =
  if relative == ".": w.root else: w.root / relative.replace('/', DirSep)

proc watchSnapshot(w: FileWatcher; previous: Table[string, FileInfo]):
    tuple[snapshot: WatchSnapshot,
    err: ref CatchableError] =
  ## Walks without following symlinks. Ignore is consulted before opening
  ## a directory, so ignored subtrees are neither traversed nor counted.
  var entries = initTable[string, FileInfo]()
  let dirInfo = try:
    getFileInfo(w.rootDir, followSymlink = false)
  except CatchableError as e:
    return (WatchSnapshot(), e)
  if dirInfo.kind != pcDir:
    return (WatchSnapshot(), watchError("watched directory was replaced"))
  result.snapshot.rootDirInfo = dirInfo
  proc preserveOld(path: string) =
    if previous.hasKey(path):
      entries[path] = previous[path]
    let prefix = path & "/"
    for oldPath, oldInfo in previous:
      if oldPath.startsWith(prefix):
        entries[oldPath] = oldInfo
  proc addEntry(path, rel: string; info: FileInfo): ref CatchableError =
    if entries.len >= w.maxEntries:
      return newException(ValueError,
        "mynim: file watch entry limit exceeded")
    entries[rel] = info
    if info.kind != pcDir or (rel != "." and not w.recursive):
      return nil
    try:
      for kind, child in walkDir(path):
        let name = extractFilename(child)
        let childRel = if rel == ".": name else: rel & "/" & name
        var childInfo: FileInfo
        try:
          childInfo = getFileInfo(child, followSymlink = false)
        except OSError as e:
          if watchInaccessible(e):
            preserveOld(childRel)
            continue
          if not fileExists(child) and not dirExists(child):
            continue
          return e
        let isDir = childInfo.kind == pcDir
        if w.ignore != nil and w.ignore(childRel, isDir):
          continue
        if entries.len >= w.maxEntries:
          return newException(ValueError,
            "mynim: file watch entry limit exceeded")
        let err = addEntry(child, childRel, childInfo)
        if err != nil:
          return err
    except CatchableError as e:
      if rel != "." and watchInaccessible(e):
        preserveOld(rel)
        return nil
      if rel != "." and not dirExists(path):
        return nil
      return e
    nil
  if w.file:
    try:
      let info = getFileInfo(w.root, followSymlink = false)
      entries["."] = info
    except OSError as e:
      ## A watched file can disappear and later be created again while
      ## its parent directory remains watched.
      if fileExists(w.root) or dirExists(w.root):
        return (WatchSnapshot(), e)
  else:
    let err = addEntry(w.root, ".", dirInfo)
    if err != nil:
      return (WatchSnapshot(), err)
  if entries.len > w.maxEntries:
    return (WatchSnapshot(), newException(ValueError,
      "mynim: file watch entry limit exceeded"))
  result.snapshot.entries = entries

proc watchGone(w: FileWatcher; rootDirInfo: FileInfo): bool =
  try:
    let current = getFileInfo(w.rootDir, followSymlink = false)
    current.kind != pcDir or not sameWatchFile(current, rootDirInfo)
  except OSError as e:
    not watchInaccessible(e)

proc recordTarget(s: WatchScanner; key: string; target: FileWatchTarget) =
  s.targets[key] = target
  s.ids[target.id] = key

proc unenroll(s: WatchScanner; key: string) =
  if s.targets.hasKey(key):
    let target = s.targets[key]
    s.targets.del(key)
    s.ids.del(target.id)
    s.native.remove(target.id)
    if key == ".":
      s.subtree = false

proc addTarget(s: WatchScanner; key, path: string; info: FileInfo;
    subtree = false): ref CatchableError =
  inc s.nextID
  let target = FileWatchTarget(id: s.nextID, path: path,
    directory: info.kind == pcDir, info: info, subtree: subtree)
  try:
    s.native.add(target)
    s.recordTarget(key, target)
    return nil
  except CatchableError as e:
    return e

proc reconcileTargets(s: WatchScanner; snapshot: WatchSnapshot):
    ref CatchableError =
  ## A subtree-capable backend gets one native target; otherwise recursive
  ## watches enroll each directory, while file watches enroll their parent.
  var desired = initTable[string, tuple[path: string, info: FileInfo,
                                        subtree: bool]]()
  if s.watcher.file:
    desired[".."] = (s.watcher.rootDir, snapshot.rootDirInfo, false)
  else:
    let rootInfo = snapshot.entries["."]
    if s.watcher.recursive and not s.noSubtree:
      if not s.subtree:
        let err = s.addTarget(".", s.watcher.root, rootInfo, true)
        if err == nil:
          s.subtree = true
        elif isErrUnsupported(err):
          s.noSubtree = true
        else:
          return err
      if s.subtree:
        desired["."] = (s.watcher.root, rootInfo, true)
    if not s.subtree:
      for path, info in snapshot.entries:
        if info.kind == pcDir and (path == "." or s.watcher.recursive):
          desired[path] = (s.watcher.watchPath(path), info, false)
    when defined(windows):
      let parent = parentDir(s.watcher.root)
      if parent != s.watcher.root:
        try:
          desired[".."] = (parent,
            getFileInfo(parent, followSymlink = false), false)
        except CatchableError as e:
          return e
  var stale: seq[string]
  for key, old in s.targets:
    if not desired.hasKey(key) or
        not sameWatchFile(old.info, desired[key].info) or
        old.path != desired[key].path or old.subtree != desired[key].subtree:
      stale.add key
  for key in stale:
    s.unenroll(key)
  var keys: seq[string]
  for key in desired.keys: keys.add key
  keys.sort()
  for key in keys:
    if s.targets.hasKey(key):
      continue
    let item = desired[key]
    let err = s.addTarget(key, item.path, item.info, item.subtree)
    if err != nil:
      return err

proc validWatchNoticeName(name: string; subtree: bool): bool =
  if '\0' in name:
    return false
  when defined(windows):
    if '\\' in name:
      return false
  if not subtree and '/' in name:
    return false
  for part in name.split('/'):
    if part == "" or part == "." or part == "..":
      return false
  true

proc scanMark(s: WatchScanner; notice: FileWatchNotice;
    writes: var HashSet[string]; needsScan: var bool): ref CatchableError =
  if notice.err != nil:
    if isErrFileWatchOverflow(notice.err):
      needsScan = true
      return nil
    if notice.target != 0 and not s.ids.hasKey(notice.target):
      return nil
    return notice.err
  if not s.ids.hasKey(notice.target):
    return nil
  let key = s.ids[notice.target]
  if key == "..":
    if notice.kind == fileWatchLost:
      s.unenroll("..")
      needsScan = true
      return nil
    if s.watcher.file:
      if notice.name != "" and notice.name != s.watcher.rootName:
        return nil
      needsScan = true
      if notice.kind == fileWatchWrite:
        writes.incl "."
      return nil
    when defined(windows):
      if notice.name != "" and notice.name != extractFilename(s.watcher.root):
        return nil
      needsScan = true
      return nil
  if notice.kind == fileWatchLost:
    s.unenroll(key)
    needsScan = true
    return nil
  let target = s.targets[key]
  let targetListable = target.directory and
    (key == "." or s.watcher.recursive)
  if notice.name == "" or not targetListable:
    needsScan = true
    if notice.kind == fileWatchWrite and (s.watcher.file or not target.directory):
      writes.incl(if s.watcher.file: "." else: key)
    return nil
  if not validWatchNoticeName(notice.name, target.subtree):
    return newException(ValueError,
      "mynim: invalid name in a file watch notice")
  var child = if key == ".": notice.name else: key & "/" & notice.name
  child = slashPath(child)
  needsScan = true
  if notice.kind == fileWatchWrite:
    writes.incl child
  nil

proc sameContents(a, b: FileInfo): bool =
  a.size == b.size and a.lastWriteTime == b.lastWriteTime

proc diffWatchEntries(before, after: Table[string, FileInfo];
    writes: HashSet[string]): seq[FileEvent] =
  var removed = initTable[string, FileInfo]()
  var created = initTable[string, FileInfo]()
  for path, old in before:
    if not after.hasKey(path) or not sameWatchFile(old, after[path]):
      removed[path] = old
  for path, current in after:
    if not before.hasKey(path) or not sameWatchFile(before[path], current):
      created[path] = current
  var oldPaths: seq[string]
  for path in removed.keys: oldPaths.add path
  oldPaths.sort()
  var paired = initTable[string, string]()
  var groups = initTable[string, seq[FileEvent]]()
  proc uniqueIdentity(entries: Table[string, FileInfo]; info: FileInfo): bool =
    var matches = 0
    for _, candidate in entries:
      if sameWatchFile(candidate, info):
        inc matches
        if matches > 1: return false
    matches == 1
  for oldPath in oldPaths:
    let old = removed[oldPath]
    var match = ""
    var count = 0
    for newPath, info in created:
      if sameWatchFile(old, info):
        match = newPath
        inc count
    if count != 1 or not uniqueIdentity(before, old) or
        not uniqueIdentity(after, old) or after.hasKey(oldPath) or
        before.hasKey(match):
      continue
    var descendant = false
    var parent = parentDir(oldPath)
    while parent != "" and parent != ".":
      if paired.hasKey(parent) and
          match == paired[parent] & oldPath[ parent.len .. ^1 ]:
        descendant = true
        break
      let next = parentDir(parent)
      if next == parent: break
      parent = next
    paired[oldPath] = match
    removed.del(oldPath)
    let moved = created[match]
    created.del(match)
    var events: seq[FileEvent]
    if not descendant:
      events.add FileEvent(op: FileRename, oldPath: oldPath,
        path: match, isDir: old.kind == pcDir)
    if moved.kind != pcDir and
        (writes.contains(oldPath) or writes.contains(match) or
         not sameContents(old, moved)):
      events.add FileEvent(op: FileWrite, path: match)
    groups[match] = events
  var paths = initHashSet[string]()
  for path in before.keys: paths.incl path
  for path in after.keys: paths.incl path
  for path in paths:
    var events: seq[FileEvent]
    if removed.hasKey(path):
      events.add FileEvent(op: FileRemove, path: path,
        isDir: removed[path].kind == pcDir)
    if created.hasKey(path):
      events.add FileEvent(op: FileCreate, path: path,
        isDir: created[path].kind == pcDir)
    if before.hasKey(path) and after.hasKey(path) and
        before[path].kind != pcDir and sameWatchFile(before[path], after[path]) and
        (writes.contains(path) or not sameContents(before[path], after[path])):
      events.add FileEvent(op: FileWrite, path: path)
    if events.len > 0:
      groups[path] = events
  var groupPaths: seq[string]
  for path in groups.keys: groupPaths.add path
  groupPaths.sort()
  for path in groupPaths:
    result.add groups[path]

proc watchGoneEvent(s: WatchScanner): seq[FileEvent] =
  if s.entries.hasKey("."):
    result.add FileEvent(op: FileRemove, path: ".",
      isDir: s.entries["."].kind == pcDir)

proc scannerUpdate(s: WatchScanner; writes: HashSet[string]):
    tuple[events: seq[FileEvent], gone: bool,
          err: ref CatchableError] =
  if s.watcher.watchGone(s.rootDirInfo):
    return (s.watchGoneEvent(), true, nil)
  let (fresh, scanErr) = s.watcher.watchSnapshot(s.entries)
  if scanErr != nil:
    if s.watcher.watchGone(s.rootDirInfo):
      return (s.watchGoneEvent(), true, nil)
    return (@[], false, scanErr)
  if not sameWatchFile(fresh.rootDirInfo, s.rootDirInfo):
    return (s.watchGoneEvent(), true, nil)
  if s.watcher.file and fresh.entries.hasKey(".") and
      s.entries.hasKey(".") and
      not sameWatchFile(fresh.entries["."], s.entries["."]):
    s.entries = fresh.entries
    s.rootDirInfo = fresh.rootDirInfo
    let err = s.reconcileTargets(fresh)
    if err != nil: return (@[], false, err)
    return (@[FileEvent(op: FileWrite, path: ".")], false, nil)
  let events = diffWatchEntries(s.entries, fresh.entries, writes)
  let targetErr = s.reconcileTargets(fresh)
  if targetErr != nil:
    return (@[], false, targetErr)
  s.entries = fresh.entries
  s.rootDirInfo = fresh.rootDirInfo
  (events, false, nil)

proc requestStop(w: FileWatcher; err: ref CatchableError = nil;
    clearPending = true) =
  var waiters: seq[FileWatchWaiter]
  var replyErr = err
  w.mu.acquire()
  if not w.stopped:
    w.stopped = true
    w.stopErr = err
    if clearPending:
      w.batch.setLen(0)
      w.hasBatch = false
    waiters = w.waiters
    w.waiters.setLen(0)
  elif clearPending:
    w.batch.setLen(0)
    w.hasBatch = false
  w.mu.release()
  if replyErr == nil:
    replyErr = watchClosedError()
  for waiter in waiters:
    deliver(waiter.ch, FileWatchResult(err: replyErr))

proc watcherNotice(w: FileWatcher; notice: FileWatchNotice) =
  w.mu.acquire()
  if w.stopped or w.ctx.done():
    w.mu.release()
    return
  if notice.err != nil and not isErrFileWatchOverflow(notice.err):
    while w.raw.len >= watchNoticeLimit and not w.stopped and not w.ctx.done():
      w.mu.release()
      sleep(1)
      w.mu.acquire()
    if not w.stopped and not w.ctx.done():
      w.raw.add notice
  elif w.raw.len < watchNoticeLimit:
    w.raw.add notice
  else:
    w.overflow = true
  w.mu.release()

proc emitWatchEvents(w: FileWatcher; events: seq[FileEvent]) =
  if events.len == 0: return
  var waiter: FileWatchWaiter
  w.mu.acquire()
  if w.stopped:
    w.mu.release()
    return
  if w.waiters.len == 0:
    w.batch.add events
    w.hasBatch = true
  else:
    waiter = w.waiters[0]
    w.waiters.delete(0)
  w.mu.release()
  if waiter != nil:
    deliver(waiter.ch, FileWatchResult(events: events))

proc watchWaiting(w: FileWatcher): bool =
  w.mu.acquire()
  result = w.hasBatch
  w.mu.release()

proc finishWatch(w: FileWatcher; err: ref CatchableError;
    clearPending = true) =
  w.requestStop(err, clearPending)
  if w.stopCtx != nil:
    discard w.stopCtx()
  if w.stopParentCtx != nil:
    discard w.stopParentCtx()
  if w.cancelCtx != nil:
    w.cancelCtx()
  w.mu.acquire()
  w.finished = true
  w.cv.broadcast()
  w.mu.release()
  fileWatchRegistryLock.acquire()
  for i, active in activeFileWatches:
    if active == w:
      activeFileWatches.delete(i)
      break
  fileWatchRegistryLock.release()

proc runFileWatch(w: FileWatcher) {.thread.} =
  {.cast(gcsafe).}:
    var terminal: ref CatchableError
    var keepFinalBatch = false
    defer:
      w.native.close()
      w.finishWatch(terminal, clearPending = not keepFinalBatch)
    var scanner = WatchScanner(watcher: w, native: w.native,
      entries: initTable[string, FileInfo](),
      targets: initTable[string, FileWatchTarget](),
      ids: initTable[uint64, string]())
    try:
      if w.ctx.done():
        let err = w.ctx.err()
        raise(if err != nil: err else: newCanceled())
      let (initial, initialErr) = w.watchSnapshot(
        initTable[string, FileInfo]())
      if initialErr != nil: raise initialErr
      scanner.entries = initial.entries
      scanner.rootDirInfo = initial.rootDirInfo
      let targetErr = scanner.reconcileTargets(initial)
      if targetErr != nil: raise targetErr
      deliver(w.ready, nil)
    except CatchableError as e:
      terminal = e
      deliver(w.ready, e)
      return

    var scheduled = false
    var due = false
    var firstAt = getTime()
    var deadline = getTime()
    var pendingWrites = initHashSet[string]()
    while true:
      if w.ctx.done():
        break
      var notices: seq[FileWatchNotice]
      var overflow, taken, stopped: bool
      w.mu.acquire()
      notices = w.raw
      w.raw.setLen(0)
      overflow = w.overflow
      w.overflow = false
      taken = w.taken
      w.taken = false
      stopped = w.stopped
      w.mu.release()
      if stopped: break
      var scanPending = overflow
      for notice in notices:
        let markErr = scanner.scanMark(notice, pendingWrites, scanPending)
        if markErr != nil:
          terminal = markErr
          break
      if terminal != nil: break
      if scanPending:
        let now = getTime()
        if not scheduled:
          firstAt = now
        scheduled = true
        deadline = min(now + initDuration(milliseconds = int64(w.debounceMs)),
          firstAt + initDuration(milliseconds = int64(w.maxDelayMs)))
      if scheduled and getTime() >= deadline:
        scheduled = false
        if w.watchWaiting():
          due = true
        else:
          let (events, gone, updateErr) = scanner.scannerUpdate(pendingWrites)
          if updateErr != nil:
            terminal = updateErr
            break
          pendingWrites.clear()
          w.emitWatchEvents(events)
          due = false
          if gone:
            keepFinalBatch = true
            return
      if taken and due and not scheduled and not w.watchWaiting():
        let (events, gone, updateErr) = scanner.scannerUpdate(pendingWrites)
        if updateErr != nil:
          terminal = updateErr
          break
        pendingWrites.clear()
        w.emitWatchEvents(events)
        due = false
        if gone:
          keepFinalBatch = true
          return
      sleep(5)

proc watchFilesImpl(ctx: CancelCtx; path: string; opts: FileWatchOptions):
    tuple[watcher: FileWatcher, err: ref CatchableError] =
  ## Watches an existing file or directory. Events are snapshots of what
  ## changed; recursive scans do not follow symbolic links.
  needsApp("WatchFiles")
  if ctx == nil:
    return (nil, newException(ValueError, "mynim: nil watch context"))
  if path == "":
    return (nil, newException(ValueError, "mynim: empty watch path"))
  if opts.maxEntries < 0:
    return (nil, newException(ValueError, "mynim: negative watch limit"))
  if ctx.done():
    let err = ctx.err()
    return (nil, if err != nil: err else: newCanceled())
  let absolute = try: expandFilename(path)
    except CatchableError as e: return (nil, e)
  let info = try: getFileInfo(absolute, followSymlink = false)
    except CatchableError as e: return (nil, e)
  let isFile = info.kind != pcDir
  let rootDir = if isFile: parentDir(absolute) else: absolute
  let debounce = if opts.debounce == initDuration():
      initDuration(milliseconds = 50)
    else: opts.debounce
  let debounceMs = max(0, int(debounce.inMilliseconds))
  let maxDelay = if opts.maxDelay == initDuration():
      initDuration(milliseconds = 500)
    else: opts.maxDelay
  let maxDelayMs = max(debounceMs, int(maxDelay.inMilliseconds))
  let w = FileWatcher(root: absolute, rootDir: rootDir,
    rootName: extractFilename(absolute), file: isFile,
    recursive: opts.recursive, ignore: opts.ignore,
    debounceMs: debounceMs, maxDelayMs: maxDelayMs,
    maxEntries: if opts.maxEntries == 0: defaultWatchMaxEntries
                else: opts.maxEntries)
  initLock(w.mu)
  initCond(w.cv)
  ## Use an independent lifecycle context. withCancel forms a strong
  ## parent/child cycle in this subset of context.Context because canceled
  ## children remain in their parent's child list.
  let life = newCtx()
  let lifePtr = cast[pointer](life)
  let cancelLife = proc() = cast[CancelCtx](lifePtr).cancel()
  let stopParent = ctx.afterDone(proc() =
    cast[CancelCtx](lifePtr).cancel())
  w.ctx = life
  w.cancelCtx = cancelLife
  ## CancelCtx retains stopped callbacks as no-ops. Capture only a raw
  ## pointer here so the callback does not keep a strong context -> watch
  ## -> context cycle alive.
  let watchPtr = cast[pointer](w)
  w.stopParentCtx = stopParent
  w.stopCtx = life.afterDone(proc() =
    cast[FileWatcher](watchPtr).requestStop())
  if life.done():
    cancelLife()
    discard w.stopCtx()
    if w.stopParentCtx != nil: discard w.stopParentCtx()
    let err = ctx.err()
    return (nil, if err != nil: err else: newCanceled())
  fileWatchRegistryLock.acquire()
  if fileWatchRegistryStopped:
    fileWatchRegistryLock.release()
    cancelLife()
    discard w.stopCtx()
    if w.stopParentCtx != nil: discard w.stopParentCtx()
    return (nil, watchError("application has stopped"))
  activeFileWatches.add w
  fileWatchRegistryLock.release()
  ## The backend retains its callback for the lifetime of its native
  ## watcher, which is stored on w. Use a raw pointer to avoid a strong
  ## w -> native -> callback -> w ownership cycle.
  let nativeWatchPtr = cast[pointer](w)
  let (native, nativeErr) = backend().newFileWatch(proc(n: FileWatchNotice) =
    cast[FileWatcher](nativeWatchPtr).watcherNotice(n))
  if nativeErr != nil or native == nil:
    fileWatchRegistryLock.acquire()
    for i, active in activeFileWatches:
      if active == w:
        activeFileWatches.delete(i)
        break
    fileWatchRegistryLock.release()
    cancelLife()
    discard w.stopCtx()
    discard w.stopParentCtx()
    if nativeErr != nil: return (nil, nativeErr)
    return (nil, watchError("backend returned no watcher"))
  w.native = native
  w.ready.open()
  createThread(w.thread, runFileWatch, w)
  let startErr = await(w.ready)
  w.ready.close()
  if startErr != nil:
    w.waitDone()
    return (nil, startErr)
  (w, nil)

proc watchFiles*(ctx: CancelCtx; path: string; opts = FileWatchOptions()):
    tuple[watcher: FileWatcher, err: ref CatchableError] {.gcsafe.} =
  ## File watchers may be started from workers before the app event loop
  ## begins; shared state and the backend singleton are lock-protected.
  {.cast(gcsafe).}:
    result = watchFilesImpl(ctx, path, opts)

proc root*(w: FileWatcher): string = w.root

proc nextImpl(w: FileWatcher; ctx: CancelCtx):
    tuple[events: seq[FileEvent], err: ref CatchableError] =
  ## Waits for the next debounced batch. Canceling ctx cancels this wait,
  ## not the watch. The main thread continues pumping native events.
  if ctx == nil:
    return (@[], newException(ValueError, "mynim: nil wait context"))
  if ctx.done():
    let err = ctx.err()
    return (@[], if err != nil: err else: newCanceled())
  let waiter = FileWatchWaiter()
  waiter.ch.open()
  w.mu.acquire()
  if w.hasBatch:
    let events = w.batch
    w.batch.setLen(0)
    w.hasBatch = false
    w.taken = true
    w.mu.release()
    waiter.ch.close()
    return (events, nil)
  if w.stopped:
    let err = if w.stopErr != nil: w.stopErr else: watchClosedError()
    w.mu.release()
    waiter.ch.close()
    return (@[], err)
  w.waiters.add waiter
  w.mu.release()
  let watchPtr = cast[pointer](w)
  let waitCtxPtr = cast[pointer](ctx)
  let stop = ctx.afterDone(proc() =
    var found = false
    let watch = cast[FileWatcher](watchPtr)
    watch.mu.acquire()
    for i, current in watch.waiters:
      if current == waiter:
        watch.waiters.delete(i)
        found = true
        break
    watch.mu.release()
    if found:
      let err = cast[CancelCtx](waitCtxPtr).err()
      deliver(waiter.ch, FileWatchResult(err: if err != nil: err else: newCanceled())))
  let res = await(waiter.ch)
  discard stop()
  waiter.ch.close()
  (res.events, res.err)

proc next*(w: FileWatcher; ctx: CancelCtx):
    tuple[events: seq[FileEvent], err: ref CatchableError] {.gcsafe.} =
  ## The watcher state is protected by its mutex, and Channel delivery
  ## is thread-safe; Next is safe to call from application workers.
  {.cast(gcsafe).}:
    result = nextImpl(w, ctx)

proc closeImpl(w: FileWatcher): ref CatchableError =
  ## Stops the watch and discards events not already returned by next.
  w.requestStop()
  w.cancelCtx()
  nil

proc close*(w: FileWatcher): ref CatchableError {.gcsafe.} =
  {.cast(gcsafe).}:
    result = closeImpl(w)

proc err*(w: FileWatcher): ref CatchableError =
  w.mu.acquire()
  result = w.stopErr
  w.mu.release()

proc waitDone*(w: FileWatcher) =
  ## Waits for the worker to return.
  w.mu.acquire()
  while not w.finished:
    w.cv.wait(w.mu)
  w.mu.release()

proc stopFileWatches() =
  fileWatchRegistryLock.acquire()
  fileWatchRegistryStopped = true
  var all: seq[FileWatcher]
  for w in activeFileWatches:
    all.add w
  fileWatchRegistryLock.release()
  for w in all:
    discard w.close()
  for w in all:
    w.waitDone()
