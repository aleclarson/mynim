## apps.nim: the applications the desktop knows.

var
  appsLoaded: bool
  gAppInfoGetAll*: proc(): pointer {.cdecl.}
  gAppInfoShouldShow*: proc(info: pointer): bool {.cdecl.}
  gAppInfoGetDisplayName*: proc(info: pointer): pointer {.cdecl.}
  gAppInfoLaunch*: proc(info, files, ctx: pointer,
                       gerr: ptr pointer): bool {.cdecl.}
  gDesktopAppInfoGetFilename*: proc(info: pointer): pointer {.cdecl.}
  gdkDisplayGetAppLaunchContext*: proc(d: pointer): pointer {.cdecl.}

proc loadApps*() =
  if appsLoaded: return
  appsLoaded = true
  loadIcons() # g_desktop_app_info_new_from_filename
  mustBind(libGIO, cast[ptr pointer](addr gAppInfoGetAll),
    "g_app_info_get_all")
  mustBind(libGIO, cast[ptr pointer](addr gAppInfoShouldShow),
    "g_app_info_should_show")
  mustBind(libGIO, cast[ptr pointer](addr gAppInfoGetDisplayName),
    "g_app_info_get_display_name")
  mustBind(libGIO, cast[ptr pointer](addr gAppInfoLaunch),
    "g_app_info_launch")
  mustBind(libGIO, cast[ptr pointer](addr gDesktopAppInfoGetFilename),
    "g_desktop_app_info_get_filename")
  mustBind(libGDK, cast[ptr pointer](addr gdkDisplayGetAppLaunchContext),
    "gdk_display_get_app_launch_context")

## applications lists the applications of the desktop entries that menus
## show (g_app_info_should_show: not NoDisplay or Hidden, and meant for
## this desktop), with their names in the user's language, their desktop
## file IDs and the paths of their entries. GIO is thread-safe.
method applications*(b: Backend):
    tuple[apps: seq[platform.Application], err: ref CatchableError] =
  loadApps()
  var apps: seq[platform.Application]
  var list = gAppInfoGetAll()
  var l = list
  while not l.isNil:
    let info = field[pointer](l, 0) # GList: data, next, prev
    if gAppInfoShouldShow(info):
      let path = goStr(gDesktopAppInfoGetFilename(info))
      if path != "":
        apps.add platform.Application(
          name: goStr(gAppInfoGetDisplayName(info)),
          id: goStr(gAppInfoGetID(info)),
          path: path)
    gObjectUnref(info)
    l = field[pointer](l, 8)
  gListFree(list)
  (apps, nil)

## openApplication launches the application of a desktop entry, with the
## display's launch context, which gives it startup notification or the
## activation token that lets it take the focus.
method openApplication*(s: shellImpl, path: string) =
  loadApps()
  let info = gDesktopAppInfoNewFromFile(cs(path))
  if info.isNil:
    raise newException(CatchableError,
      "mynim: " & path & " is not a desktop entry of an application")
  defer: gObjectUnref(info)
  let ctx = gdkDisplayGetAppLaunchContext(gdkDisplayGetDefault())
  defer: gObjectUnref(ctx)
  var gerr: pointer
  if not gAppInfoLaunch(info, nil, ctx, addr gerr):
    raise gErr(gerr)
