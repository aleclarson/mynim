## team.go: a piece of work on several cores — the thread asking for
## it, and helpers waiting for work, shared by every team.

type
  team = object
    ## do does a part of the work as a member, 0 for the thread asking:
    ## set once per run. It must not run a team.
    `do`*: proc(member, part: int) {.gcsafe.}
    parts: int
    next: Atomic[int32]
    pending: Atomic[int32]

  share = object
    t: ptr team
    member: int

var
  helped: Channel[share]
  helpers: Atomic[int32]
  hiring: Lock
  helpersStarted: bool

proc work(t: ptr team, member: int) {.gcsafe.} =
  var p = t.next.fetchAdd(1, moRelaxed) - 1
  while p < t.parts:
    t.do(member, p)
    p = t.next.fetchAdd(1, moRelaxed) - 1

proc help() {.thread.} =
  {.cast(gcsafe).}:
    while true:
      let s = helped.recv()
      work(s.t, s.member)
      discard s.t.pending.fetchSub(1, moAcquire)

proc hire(n: int) =
  if helpers.load(moRelaxed) >= int32(n):
    return
  hiring.acquire()
  defer: hiring.release()
  while helpers.load(moRelaxed) < int32(n):
    discard helpers.fetchAdd(1, moRelaxed)
    var th: Thread[void]
    createThread(th, help)

proc run*(t: var team, members, parts: int) =
  ## Does parts parts of the work on members cores at most.
  let members = max(min(min(members, parts), maxWorkers), 1)
  t.parts = parts
  t.next.store(0, moRelaxed)
  t.pending.store(int32(members - 1), moRelaxed)
  hire(members - 1)
  for m in 1 ..< members:
    helped.send(share(t: addr t, member: m))
  work(addr t, 0)
  while t.pending.load(moAcquire) > 0:
    discard

helped.open()
hiring.initLock()
