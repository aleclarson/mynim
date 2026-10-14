## network.nim: GNetworkMonitor is a singleton GLib keeps up to date, so
## a status is a plain read and its network-changed signal drives the
## event.

## status reads the monitor's current view. The first call creates the
## singleton, on the main thread.
method status*(n: networkImpl): platform.NetworkStatus =
  let m = gNetworkMonitorGetDefault()
  if m.isNil: return platform.NetworkStatus()
  platform.NetworkStatus(
    online: gNetworkMonitorGetNetworkAvailable(m),
    constrained: gNetworkMonitorGetNetworkMetered(m))

## watch connects network-changed. The core calls it once.
method watch*(n: networkImpl) =
  let m = gNetworkMonitorGetDefault()
  if not m.isNil:
    discard connect(m, "network-changed", cbNetworkChanged, nil)
