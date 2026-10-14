## network.nim (network.go): the connectivity hint of Windows 10 2004
## and later.

## NL_NETWORK_CONNECTIVITY_LEVEL_HINT and
## NL_NETWORK_CONNECTIVITY_COST_HINT.
const
  nlConnectivityLevelUnknown* = 0
  nlConnectivityLevelInternetAccess* = 3
  nlConnectivityLevelConstrainedInternet* = 4
  nlConnectivityCostVariable* = 3

## nlNetworkConnectivityHint mirrors NL_NETWORK_CONNECTIVITY_HINT of
## nldef.h: the connectivity level and cost are C enums (int, 4 bytes
## each), followed by three BOOLEANs.
type nlNetworkConnectivityHint* = object
  level*, cost*: int32
  approachingLimit*, overLimit*, roaming*: uint8

## networkHandle is the registration of the hint's changes, which
## lives as long as the app.
var networkHandle: uint

method network*(b: WinBackend): Network = w32Network(b: b)

## Status reads the system's connectivity hint, the aggregate of what
## the Network Connectivity Status Indicator found out on every
## interface.
method status*(n: w32Network): NetworkStatus =
  var h: nlNetworkConnectivityHint
  if procGetNetworkConnectivityHint.isNil:
    ## An older Windows does not tell. Assume the connection works
    ## and is not metered, as the browsers do.
    return NetworkStatus(online: true)
  if procGetNetworkConnectivityHint(cast[uint](addr h)) != 0:
    return NetworkStatus(online: true)
  NetworkStatus(
    online: h.level == nlConnectivityLevelInternetAccess or
      h.level == nlConnectivityLevelConstrainedInternet or
      h.level == nlConnectivityLevelUnknown,
    constrained: h.cost == nlConnectivityCostVariable)

proc networkChangedCb(ctx, hint: uint): uint {.stdcall.} =
  postMessage(theBackend.appHwnd, wmAppNetwork, 0, 0)
  0

## watch asks to be told when the connectivity hint changes. The core
## calls it once, after the application window exists.
method watch*(n: w32Network) =
  if procNotifyNetworkConnectivityHintChange.isNil:
    return
  ## The callback runs on a thread of the system's, so it only posts
  ## to the application window, and the main thread reads the hint
  ## again. Its second parameter is the hint by value, which amd64
  ## passes as a pointer and arm64 in two registers, so it is not
  ## read.
  discard procNotifyNetworkConnectivityHintChange(
    cast[uint](networkChangedCb), 0, 0, cast[uint](addr networkHandle))
