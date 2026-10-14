## notify.go: notifications through UNUserNotificationCenter, which only
## works for apps running from a bundle with an identifier.

var
  mainQueueMu: Lock
  mainQueue: seq[proc() {.closure.}]

## runOnMain runs fn on the main thread; used by callbacks the system
## delivers on background queues.
proc runOnMain*(b: Backend, fn: proc()) =
  if b.isMainThread:
    {.gcsafe.}: fn()
    return
  b.post(fn)

## post runs fn on the main thread after the current event, even when
## called there.
proc post*(b: Backend, fn: proc()) =
  withLock mainQueueMu:
    {.gcsafe.}: mainQueue.add fn
  b.signal()

proc drainMainQueue*() =
  var q: seq[proc() {.closure.}]
  withLock mainQueueMu:
    {.gcsafe.}: q = mainQueue
    mainQueue.setLen(0)
  for fn in q:
    fn()

proc registerNotificationDelegate*() =
  if not hasClass("UNUserNotificationCenter"):
    return
  discard classDef("MyGoNotificationDelegate", "NSObject",
    @["UNUserNotificationCenterDelegate"], @[
    methodDef(
      "userNotificationCenter:willPresentNotification:withCompletionHandler:",
      cast[pointer](proc(self: id, cmd: SEL, center, n: id,
                         handler: pointer) {.cdecl.} =
        # Show banners even while the app is in the foreground.
        callBlock(handler, @[uint(1 shl 1 or 1 shl 3 or 1 shl 4)])),
      "v@:@@@?"),
    methodDef(
      "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:",
      cast[pointer](proc(self: id, cmd: SEL, center, resp: id,
                         handler: pointer) {.cdecl.} =
        let ident = goString(send(
          send(send(send(resp, "notification"), "request"),
               "identifier"), "self"))
        {.gcsafe.}:
          theBackend.runOnMain(proc() =
            theBackend.h.notificationClicked(ident))
        callBlock(handler, @[])),
      "v@:@@@?"),
  ])

method notificationsSupported*(b: Backend): bool =
  let (_, packaged) = appController(b: b).`package`()
  packaged and hasClass("UNUserNotificationCenter")

## notificationCenter returns the app's notification center. It raises
## when the app does not run from a bundle: check notificationsSupported
## first.
proc notificationCenter(): id =
  send(`class`("UNUserNotificationCenter"), "currentNotificationCenter")

## attachNotificationDelegate gives the notification center the delegate
## that receives clicks, at launch: the system delivers the click that
## launched the app before the app has finished launching, and drops it
## when the center has no delegate yet.
proc attachNotificationDelegate*(b: Backend) =
  if not b.notificationsSupported:
    return
  b.notifyDelegate = alloc("MyGoNotificationDelegate")
  withPool(proc() =
    discard send(notificationCenter(), "setDelegate:",
                 argu(b.notifyDelegate)))

## unErrorNotificationsNotAllowed is UNErrorCodeNotificationsNotAllowed.
const unErrorNotificationsNotAllowed = 1

## notificationError describes an error of the notification center.
proc notificationError(err: id): ref CatchableError =
  if err.isNil:
    return nil
  if goString(send(err, "domain")) == "UNErrorDomain" and
      sendInt(err, "code") == unErrorNotificationsNotAllowed:
    return errNotificationsDenied()
  nsError(err)

## addNotification gives the system a request to show a notification.
## Its trigger is nil, which shows it at once.
proc addNotification*(b: Backend, n: Notification,
                      done: proc(err: ref CatchableError)) =
  withPool(proc() =
    let content = autorelease(alloc("UNMutableNotificationContent"))
    discard send(content, "setTitle:", argu(nsString(n.title)))
    if n.subtitle != "":
      discard send(content, "setSubtitle:", argu(nsString(n.subtitle)))
    discard send(content, "setBody:", argu(nsString(n.body)))
    if not n.silent:
      discard send(content, "setSound:",
                   argu(send(`class`("UNNotificationSound"),
                             "defaultSound")))
    if n.group != "":
      discard send(content, "setThreadIdentifier:",
                   argu(nsString(n.group)))
    let req = send(`class`("UNNotificationRequest"),
                   "requestWithIdentifier:content:trigger:",
                   argu(nsString(n.id)), argu(content), argu(nil))
    let blk = mkBlockId(proc(nsErr: id) =
      # The error is the caller's only while the block runs.
      var err: ref CatchableError
      withPool(proc() = err = notificationError(nsErr))
      {.gcsafe.}:
        theBackend.runOnMain(proc() = done(err)))
    discard send(notificationCenter(),
                 "addNotificationRequest:withCompletionHandler:",
                 argu(req), argu(blk))
    blockRelease(blk))

## notifyOptions are the permissions asked for: badge, sound and alert.
const notifyOptions = 1'u shl 0 or 1 shl 1 or 1 shl 2

method showNotification*(b: Backend, n: Notification,
                         done: proc(err: ref CatchableError)) =
  if not b.notificationsSupported:
    done(errUnsupported())
    return
  if b.notifyAnswered:
    b.addNotification(n, done)
    return
  # The system drops what it is given before the user has answered
  # whether the app may show notifications, so the first notification
  # asks and the ones shown meanwhile wait for the answer. The system
  # only prompts the first time; afterwards it answers at once, and
  # adding a notification fails when System Settings does not allow it.
  let refn = new(ref Notification)
  refn[] = n
  b.notifyWaiting.add waitingNotification(n: refn, done: done)
  if b.notifyWaiting.len > 1:
    return
  withPool(proc() =
    let blk = mkBlockIdId(proc(granted: id, err: id) =
      discard granted
      discard err
      {.gcsafe.}:
        theBackend.runOnMain(proc() =
          theBackend.notifyAnswered = true
          let waiting = theBackend.notifyWaiting
          theBackend.notifyWaiting.setLen(0)
          for w in waiting:
            theBackend.addNotification(w.n[], w.done)))
    discard send(notificationCenter(),
                 "requestAuthorizationWithOptions:completionHandler:",
                 argu(notifyOptions), argu(blk))
    blockRelease(blk))



method removeNotification*(b: Backend, ident: string) =
  if not b.notificationsSupported:
    return
  # One still waiting for the user's answer is not shown.
  var waiting: seq[waitingNotification]
  for w in b.notifyWaiting:
    if w.n.id == ident:
      w.done(nil)
    else:
      waiting.add w
  b.notifyWaiting = waiting
  withPool(proc() =
    let center = notificationCenter()
    let ids = nsArray(nsString(ident))
    discard send(center,
                 "removeDeliveredNotificationsWithIdentifiers:",
                 argu(ids))
    discard send(center,
                 "removePendingNotificationRequestsWithIdentifiers:",
                 argu(ids)))

method removeAllNotifications*(b: Backend) =
  if not b.notificationsSupported:
    return
  let waiting = b.notifyWaiting
  b.notifyWaiting.setLen(0)
  for w in waiting:
    w.done(nil)
  withPool(proc() =
    let center = notificationCenter()
    discard send(center, "removeAllDeliveredNotifications")
    discard send(center, "removeAllPendingNotificationRequests"))
