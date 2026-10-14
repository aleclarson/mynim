## watch.go: kqueue vnode watches: a descriptor opened for events only
## (O_EVTONLY) per target, which doesn't keep a volume from being
## unmounted. A directory reports that its entries changed but not
## which, so the core lists it again.

import posix/kqueue
import std/oserrors

var oEvtonly {.importc: "O_EVTONLY", header: "<fcntl.h>", nodecl.}: cint
var oNofollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>", nodecl.}: cint

proc closeOnExec(fd: cint) =
  discard posix.fcntl(fd, F_SETFD, FD_CLOEXEC)

proc setNonblock(fd: cint) =
  discard posix.fcntl(fd, F_SETFL, O_NONBLOCK)

proc posixErrno(): ref CatchableError =
  newOSError(osLastError())

method newFileWatch*(b: Backend, notify: proc(n: FileWatchNotice)):
    tuple[w: FileWatch, err: ref CatchableError] =
  let q = kqueue()
  if q < 0:
    return (nil, posixErrno())
  closeOnExec(q)
  let d = vnodeWatch(queue: q,
                     files: initTable[uint64, cint](),
                     ids: initTable[cint, uint64]())
  initLock(d.mu)
  if posix.pipe(d.pipe) < 0:
    discard posix.close(q)
    return (nil, posixErrno())
  for fd in d.pipe:
    closeOnExec(fd)
    setNonblock(fd)
  var change: KEvent
  EV_SET(addr change, d.pipe[0].uint, EVFILT_READ.cshort,
         (EV_ADD or EV_CLEAR).cushort, 0, 0, nil)
  if kevent(q, addr change, 1, nil, 0, nil) < 0:
    d.close()
    return (nil, posixErrno())
  (newWatch(d, notify), nil)

method add*(d: vnodeWatch, t: FileWatchTarget) {.gcsafe.} =
  if t.subtree:
    raise errUnsupported()
  if not t.directory and t.info.kind != pcFile:
    return
  let fd = posix.open(t.path.cstring,
                      oEvtonly or O_CLOEXEC or oNofollow, 0.Mode)
  if fd < 0:
    raise posixErrno()
  var st: Stat
  if fstat(fd, st) < 0:
    discard posix.close(fd)
    raise posixErrno()
  let same = st.st_dev == t.info.id.device and st.st_ino == t.info.id.file
  if not same:
    discard posix.close(fd)
    raise newException(IOError, "watch target identity changed")
  var change: KEvent
  EV_SET(addr change, fd.uint, EVFILT_VNODE.cshort,
         (EV_ADD or EV_CLEAR or EV_RECEIPT).cushort,
         (NOTE_WRITE or NOTE_EXTEND or NOTE_ATTRIB or NOTE_LINK or
          NOTE_RENAME or NOTE_DELETE or NOTE_REVOKE).cuint, 0, nil)
  var receipt: array[1, KEvent]
  var err = 0.cint
  while true:
    err = (if kevent(d.queue, addr change, 1, addr receipt[0], 1,
                     nil) < 0: cint(osLastError()) else: 0)
    if err != EINTR.cint:
      break
  if err == 0 and (receipt[0].flags and EV_ERROR.cushort) != 0 and
      receipt[0].data != 0:
    err = receipt[0].data.cint
  if err != 0:
    discard posix.close(fd)
    raise newException(OSError, "watch: " & $err & " " & $strerror(err))
  d.files[t.id] = fd
  d.ids[fd] = t.id

method remove*(d: vnodeWatch, id: uint64) {.gcsafe.} =
  if d.files.hasKey(id):
    let fd = d.files[id]
    d.ids.del(fd)
    d.files.del(id)
    discard posix.close(fd)

method wait*(d: vnodeWatch): seq[FileWatchNotice] {.gcsafe.} =
  var events: array[128, KEvent]
  var n: cint
  while true:
    n = kevent(d.queue, nil, 0, addr events[0], 128, nil)
    if n >= 0 or osLastError() != OSErrorCode(EINTR):
      break
  if n < 0:
    raise posixErrno()
  for i in 0 ..< n:
    let e = events[i]
    if e.ident == d.pipe[0].uint:
      var buf: array[256, byte]
      while true:
        let r = posix.read(d.pipe[0], addr buf[0], buf.len)
        if r < 0 and osLastError() == OSErrorCode(EINTR):
          continue
        break
      continue
    if d.ids.hasKey(e.ident.cint):
      var notice = FileWatchNotice(target: d.ids[e.ident.cint])
      if ((e.flags and EV_ERROR.cushort) != 0 and e.data != 0) or
          (e.fflags and NOTE_REVOKE.cuint) != 0:
        ## The volume went away, or kqueue gave up on the descriptor.
        notice.kind = fileWatchLost
      elif (e.fflags and (NOTE_WRITE or NOTE_EXTEND or NOTE_ATTRIB or
          NOTE_LINK).cuint) != 0:
        notice.kind = fileWatchWrite
      result.add notice

method wake*(d: vnodeWatch) {.gcsafe.} =
  withLock d.mu:
    if not d.closed:
      var b = byte(1)
      while true:
        let w = posix.write(d.pipe[1], addr b, 1)
        if w < 0 and osLastError() == OSErrorCode(EINTR):
          continue
        break

method close*(d: vnodeWatch) {.gcsafe.} =
  withLock d.mu:
    d.closed = true
    for _, f in d.files:
      discard posix.close(f)
    discard posix.close(d.pipe[0])
    discard posix.close(d.pipe[1])
    discard posix.close(d.queue)
