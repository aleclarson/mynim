## network.go: Network.framework, a C API: no Objective-C objects, no
## reference counting beyond the monitor itself, and blocks instead of a
## delegate.

var
  nwPathMonitorCreate: proc(): pointer {.cdecl.}
  nwPathMonitorSetUpdateHandler: proc(monitor, handler: pointer) {.cdecl.}
  nwPathMonitorSetQueue: proc(monitor, queue: pointer) {.cdecl.}
  nwPathMonitorStart: proc(monitor: pointer) {.cdecl.}
  nwPathGetStatus: proc(path: pointer): int32 {.cdecl.}
  nwPathIsExpensive: proc(path: pointer): bool {.cdecl.}
  nwPathIsConstrained: proc(path: pointer): bool {.cdecl.}
  dispatchQueueCreate: proc(label: cstring, attr: pointer): pointer {.cdecl.}

## nw_path_status_satisfied: the path has a usable route to send and
## receive data on.
const nwPathStatusSatisfied = 1

## networkMonitor is the app's single path monitor, started by the first
## status or watch. Its handler runs on a queue of its own, so that
## status can wait on the main thread for the first path, which the
## monitor reports asynchronously, as Chromium's
## NetworkChangeNotifierApple waits for its first connection type.
type NetworkMonitor = object
  started: bool
  firstPath: bool ## set with the first path
  mu: Lock
  status: NetworkStatus
  watching: bool ## on the main thread

var networkMonitor: NetworkMonitor
var nmLock: Lock

type macNetwork = ref object of Network
  b: Backend

method network*(b: Backend): Network = macNetwork(b: b)

## startNetworkMonitor creates and starts the monitor once.
## Network.framework is loaded only then, by apps that ask.
proc startNetworkMonitor() =
  withLock nmLock:
    if networkMonitor.started:
      return
    networkMonitor.started = true
    let lib = mustDlopen(
      "/System/Library/Frameworks/Network.framework/Network")
    nwPathMonitorCreate = cast[typeof nwPathMonitorCreate](
      mustDlsym(lib, "nw_path_monitor_create"))
    nwPathMonitorSetUpdateHandler =
      cast[typeof nwPathMonitorSetUpdateHandler](
        mustDlsym(lib, "nw_path_monitor_set_update_handler"))
    nwPathMonitorSetQueue = cast[typeof nwPathMonitorSetQueue](
      mustDlsym(lib, "nw_path_monitor_set_queue"))
    nwPathMonitorStart = cast[typeof nwPathMonitorStart](
      mustDlsym(lib, "nw_path_monitor_start"))
    nwPathGetStatus = cast[typeof nwPathGetStatus](
      mustDlsym(lib, "nw_path_get_status"))
    nwPathIsExpensive = cast[typeof nwPathIsExpensive](
      mustDlsym(lib, "nw_path_is_expensive"))
    nwPathIsConstrained = cast[typeof nwPathIsConstrained](
      mustDlsym(lib, "nw_path_is_constrained"))
    dispatchQueueCreate = cast[typeof dispatchQueueCreate](
      mustDlsym(rtldDefault, "dispatch_queue_create"))

    let m = nwPathMonitorCreate()
    if m.isNil:
      withLock networkMonitor.mu:
        networkMonitor.firstPath = true
      return
    # The handler runs on the monitor's serial queue, never on the main
    # thread, and touches no Objective-C object.
    var first = true
    let blk = mkBlockId(proc(path: id) =
      let s = NetworkStatus(
        online: nwPathGetStatus(path) == nwPathStatusSatisfied,
        constrained: nwPathIsExpensive(path) or nwPathIsConstrained(path))
      withLock networkMonitor.mu:
        networkMonitor.status = s
        networkMonitor.firstPath = true
      if first:
        first = false
        return
      theBackend.post(proc() =
        if networkMonitor.watching:
          theBackend.h.networkChanged(s)))
    # The monitor copies the handler.
    nwPathMonitorSetUpdateHandler(m, blk)
    blockRelease(blk)
    nwPathMonitorSetQueue(m, dispatchQueueCreate("mynim.network", nil))
    # The monitor lives as long as the app.
    nwPathMonitorStart(m)

## status returns the status of the monitor's latest path.
method status*(n: macNetwork): NetworkStatus =
  startNetworkMonitor()
  # The first path comes within milliseconds; never hang the app on a
  # monitor that does not answer.
  let deadline = epochTime() + 1.0
  while true:
    var got = false
    withLock networkMonitor.mu:
      got = networkMonitor.firstPath
    if got or epochTime() >= deadline:
      break
    sleep(1)
  withLock networkMonitor.mu:
    result = networkMonitor.status

## watch reports the paths after the first to AppHandler.NetworkChanged.
method watch*(n: macNetwork) =
  networkMonitor.watching = true
  startNetworkMonitor()

