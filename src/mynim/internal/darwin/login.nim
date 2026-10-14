## login.go: starting at login — on macOS 13 and later the app is a login
## item of the user through SMAppService (System Settings > General >
## Login Items); on macOS 12 a launch agent opens it. Both need an app
## bundle.

## SMAppService statuses.
const
  smNotRegistered = 0
  smEnabled = 1
  smRequiresApproval = 2

## mainAppService returns the SMAppService of the app, or 0 before
## macOS 13.
proc mainAppService(): id =
  if not hasClass("SMAppService"):
    return nil
  send(`class`("SMAppService"), "mainAppService")

proc bundlePath(): string =
  let path = goString(send(send(`class`("NSBundle"), "mainBundle"),
                           "bundlePath"))
  if not path.endsWith(".app"):
    raise newException(ValueError,
      "mynim: starting at login needs an app bundle; run the app with " &
      "mynim dev or build it with mynim build")
  path

proc launchAgentPath(appID: string): string =
  getHomeDir() / "Library" / "LaunchAgents" / (appID & ".plist")

proc xmlEscape(s: string): string =
  s.multiReplace({"&": "&amp;", "<": "&lt;", ">": "&gt;",
                  "\"": "&quot;", "'": "&apos;"})

## setLaunchAgent adds or removes a launch agent that opens the app at
## login.
proc setLaunchAgent(open: bool, appID, app, arg: string) =
  let path = launchAgentPath(appID)
  if not open:
    try:
      removeFile(path)
    except OSError as e:
      if not fileExists(path):
        discard
      else:
        raise e
    return
  let plist = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>""" & xmlEscape(appID) & """</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>-a</string>
		<string>""" & xmlEscape(app) & """</string>
		<string>--args</string>
		<string>""" & xmlEscape(arg) & """</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
"""
  createDir(parentDir(path))
  writeFile(path, plist)

method setOpenAtLogin*(a: appController, open: bool, id, name,
                       arg: string) =
  var err: ref CatchableError = nil
  withPool(proc() =
    var app: string
    try:
      app = bundlePath()
    except CatchableError as e:
      err = e
      return
    let svc = mainAppService()
    if svc.isNil:
      try:
        setLaunchAgent(open, id, app, arg)
      except CatchableError as e:
        err = e
      return
    if not open and sendInt(svc, "status") == smNotRegistered:
      return
    var selector = "unregisterAndReturnError:"
    if open:
      selector = "registerAndReturnError:"
    var nserr: id
    if not sendBool(svc, selector, argu(cast[pointer](addr nserr))):
      err = newException(ValueError, "mynim: " &
        goString(send(nserr, "localizedDescription")))
      return
    if open and sendInt(svc, "status") == smRequiresApproval:
      err = newException(ValueError, "mynim: allow " & name &
        " to open at login in System Settings > General > Login Items"))
  if err != nil:
    raise err

method openAtLogin*(a: appController, id, name, arg: string): bool =
  var ok = false
  withPool(proc() =
    try:
      discard bundlePath()
    except CatchableError:
      return
    let svc = mainAppService()
    if not svc.isNil:
      ok = sendInt(svc, "status") == smEnabled
      return
    ok = fileExists(launchAgentPath(id)))
  ok

## openedAtLogin reports whether the launch Apple Event said the app was
## started as a login item, recorded in applicationWillFinishLaunching:.
method openedAtLogin*(a: appController): bool = a.b.openedAtLogin

## launchedAsLoginItem reports whether the Apple Event being handled, the
## one that launched the app, marks it as started at login.
proc launchedAsLoginItem(): bool =
  const keyAEPropData = 'p'.uint32 shl 24 or 'r'.uint32 shl 16 or
                        'd'.uint32 shl 8 or 't'.uint32
  const keyAELaunchedAsLogInItem = 'l'.uint32 shl 24 or 'g'.uint32 shl 16 or
                                 'i'.uint32 shl 8 or 't'.uint32
  let ev = send(send(`class`("NSAppleEventManager"),
                     "sharedAppleEventManager"), "currentAppleEvent")
  if ev.isNil:
    return false
  let prop = send(ev, "paramDescriptorForKeyword:", argu(keyAEPropData))
  not prop.isNil and
    uint32(cast[uint](send(prop, "enumCodeValue"))) ==
      keyAELaunchedAsLogInItem

