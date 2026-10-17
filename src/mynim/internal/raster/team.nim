## team.go: a piece of work on several cores — the thread asking for
## it, and helpers waiting for work, shared by every team.

type
  team = object
    ## work does a part of the work as a member, 0 for the thread asking.
    ## It is a non-capturing callback set once per run; it must not run a team.
    work*: proc(context: pointer; member, part: int) {.gcsafe, nimcall.}
    context*: pointer
    parts: int
    next: Atomic[int32]

  share = object
    t: ptr team
    member: int

proc work(t: ptr team, member: int) {.gcsafe.} =
  var p = t.next.fetchAdd(1, moRelaxed)
  while p < t.parts:
    t.work(t.context, member, p)
    p = t.next.fetchAdd(1, moRelaxed)

proc help(s: share) {.thread.} =
  {.cast(gcsafe).}:
    work(s.t, s.member)

proc run*(t: var team, members, parts: int) =
  ## Does parts parts of the work on members cores at most.
  let members = max(min(min(members, parts), maxWorkers), 1)
  t.parts = parts
  t.next.store(0, moRelaxed)
  var helpers: array[maxWorkers - 1, Thread[share]]
  var started = 0
  try:
    for m in 1 ..< members:
      createThread(helpers[started], help, share(t: addr t, member: m))
      inc started
    work(addr t, 0)
  finally:
    for i in 0 ..< started:
      joinThread(helpers[i])
