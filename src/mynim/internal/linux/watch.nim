## watch.nim: inotifyWatch watches directories with inotify, which names
## the child that changed; files are watched through their directory.

const
  IN_NONBLOCK = 0o4000'i32   # O_NONBLOCK
  IN_CLOEXEC = 0o2000000'i32 # O_CLOEXEC
  EPOLL_CLOEXEC = 0o2000000'i32
  O_DIRECTORY_L = 0o10000'i32
  O_NOFOLLOW_L = 0o20000'i32

proc pipe2(fds: ptr cint, flags: cint): cint {.
  importc: "pipe2", header: "<unistd.h>", cdecl.}

proc osErrorToCatchable*(): ref CatchableError =
  newException(CatchableError, $osErrorMsg(osLastError()))

method newFileWatch*(b: Backend,
    notify: proc(n: FileWatchNotice)):
    tuple[w: FileWatch, err: ref CatchableError] =
  let fd = inotify_init1(cint(IN_NONBLOCK or IN_CLOEXEC))
  if fd < 0:
    return (nil, osErrorToCatchable())
  let ep = epoll_create1(cint(EPOLL_CLOEXEC))
  if ep < 0:
    discard close(fd)
    return (nil, osErrorToCatchable())
  let d = inotifyWatch(fd: fd, epoll: ep)
  if pipe2(cast[ptr cint](addr d.pipe), cint(O_NONBLOCK or O_CLOEXEC)) != 0:
    discard close(fd)
    discard close(ep)
    return (nil, osErrorToCatchable())
  for f in [fd, d.pipe[0]]:
    var ev = EpollEvent(events: EPOLLIN, data: EpollData(fd: f))
    if epoll_ctl(ep, EPOLL_CTL_ADD, f, addr ev) != 0:
      d.close()
      return (nil, osErrorToCatchable())
  (watchdriver.newWatch(d, notify), nil)

proc sameFileInfo(a, b: FileInfo): bool = a.id == b.id

method add*(d: inotifyWatch, t: FileWatchTarget) {.gcsafe.} =
  if t.subtree:
    raise errUnsupported()
  if not t.directory:
    return
  let fd = posix.open(t.path.cstring,
    cint(O_RDONLY or O_DIRECTORY_L or O_NOFOLLOW_L or O_CLOEXEC), 0.Mode)
  if fd < 0:
    raiseOSError(osLastError())
  var st: Stat
  let statOK = fstat(fd, st) == 0
  discard posix.close(fd)
  if not statOK:
    raiseOSError(osLastError())
  let info = FileInfo(id: (device: st.st_dev, file: st.st_ino),
                      kind: if S_ISDIR(st.st_mode): pcDir else: pcFile,
                      size: st.st_size)
  if not sameFileInfo(info, t.info):
    raise newException(IOError, "watch target identity changed")
  let mask = uint32(IN_CREATE or IN_MODIFY or IN_CLOSE_WRITE or
    IN_ATTRIB or IN_DELETE or IN_MOVED_FROM or IN_MOVED_TO or
    IN_DELETE_SELF or IN_MOVE_SELF or IN_UNMOUNT or IN_ONLYDIR or
    IN_DONT_FOLLOW)
  let wd = inotify_add_watch(d.fd, t.path.cstring, mask)
  if wd < 0:
    raiseOSError(osLastError())
  let info2 = try: getFileInfo(t.path, followSymlink = false)
              except OSError:
                discard inotify_rm_watch(d.fd, wd)
                raise
  if not sameFileInfo(info2, t.info):
    discard inotify_rm_watch(d.fd, wd)
    raise newException(IOError, "watch target identity changed")
  var gens = d.generations.getOrDefault(wd)
  if gens.len == 0 or gens[^1].retired:
    gens.add inotifyGeneration()
  gens[^1].ids.add t.id
  d.generations[wd] = gens
  d.targets[t.id] = wd

method remove*(d: inotifyWatch, id: uint64) {.gcsafe.} =
  if not d.targets.hasKey(id): return
  let wd = d.targets[id]
  d.targets.del(id)
  for g in d.generations.getOrDefault(wd):
    for i, v in g.ids:
      if v == id:
        g.ids.delete(i)
        if g.ids.len == 0 and not g.retired:
          g.retired = true
          discard inotify_rm_watch(d.fd, wd)
        return


method wait*(d: inotifyWatch): seq[FileWatchNotice] {.gcsafe.} =
  var events: array[2, EpollEvent]
  var n: cint
  while true:
    n = epoll_wait(d.epoll, addr events[0], 2, -1)
    if not (n < 0 and osLastError().cint == EINTR):
      break
  if n < 0:
    raiseOSError(osLastError())
  for i in 0 ..< int(n):
    let e = events[i]
    if cint(e.data.fd) == d.pipe[0]:
      var b: array[256, byte]
      while true:
        let r = posix.read(d.pipe[0], addr b[0], 256)
        if r < 0 and osLastError().cint == EINTR: continue
        break
      continue
    var buf: array[65536, byte]
    while true:
      let size = posix.read(d.fd, addr buf[0], buf.len)
      if size < 0 and osLastError().cint == EINTR: continue
      if size < 0 and osLastError().cint == EAGAIN: break
      if size < 0:
        raiseOSError(osLastError())
      if size == 0:
        raise newException(IOError, "inotify stream ended")
      # Re-parse with the raw masks; the record's kind is decided here.
      var off = 0
      while off < size:
        if size - off < 16:
          raise newException(IOError, "truncated inotify record")
        let wd = cast[ptr int32](unsafeAddr buf[off])[]
        let mask = cast[ptr uint32](unsafeAddr buf[off + 4])[]
        let length = int(cast[ptr uint32](unsafeAddr buf[off + 12])[])
        var name = ""
        if length > 0:
          var `end` = -1
          for j in 0 ..< length:
            if buf[off + 16 + j] == 0:
              `end` = j; break
          if `end` < 0:
            raise newException(IOError, "unterminated inotify name")
          name = newString(`end`)
          for j in 0 ..< `end`:
            name[j] = char(buf[off + 16 + j])
        if (mask and IN_Q_OVERFLOW) != 0:
          result.add FileWatchNotice(err: errFileWatchOverflow())
          off += 16 + length
          continue
        var gens = d.generations.getOrDefault(cint(wd))
        if gens.len == 0:
          off += 16 + length
          continue
        let g = gens[0]
        if (mask and IN_IGNORED) != 0:
          if gens.len == 1:
            d.generations.del(cint(wd))
          else:
            d.generations[cint(wd)] = gens[1 .. ^1]
          if not g.retired:
            # The directory's filesystem was unmounted, or inotify
            # dropped the watch for another reason.
            for id in g.ids:
              result.add FileWatchNotice(target: id, kind: fileWatchLost)
              d.targets.del(id)
          off += 16 + length
          continue
        if g.retired or g.ids.len == 0:
          off += 16 + length
          continue
        var notice = FileWatchNotice(target: g.ids[^1], name: name)
        if (mask and IN_UNMOUNT) != 0:
          off += 16 + length
          continue # IN_IGNORED follows
        elif (mask and IN_MOVED_FROM) != 0:
          notice.kind = fileWatchMoveFrom
        elif (mask and IN_MOVED_TO) != 0:
          notice.kind = fileWatchMoveTo
        elif (mask and IN_CREATE) != 0:
          notice.kind = fileWatchCreate
        elif (mask and (IN_DELETE or IN_DELETE_SELF)) != 0:
          notice.kind = fileWatchRemove
        elif (mask and (IN_MODIFY or IN_CLOSE_WRITE or IN_ATTRIB)) != 0:
          notice.kind = fileWatchWrite
        # A deleted directory's automatic IN_IGNORED is expected;
        # retain its removal hint instead of turning it into stream
        # loss.
        if (mask and IN_DELETE_SELF) != 0:
          g.retired = true
        result.add notice
        off += 16 + length

method wake*(d: inotifyWatch) {.gcsafe.} =
  withLock d.mu:
    if not d.closed:
      var b = [1'u8]
      while true:
        let r = posix.write(d.pipe[1], addr b[0], 1)
        if r < 0 and osLastError().cint == EINTR: continue
        break

method close*(d: inotifyWatch) {.gcsafe.} =
  withLock d.mu:
    d.closed = true
    discard posix.close(d.fd)
    discard posix.close(d.pipe[0])
    discard posix.close(d.pipe[1])
    discard posix.close(d.epoll)
