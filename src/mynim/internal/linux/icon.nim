## icon.nim: file icons come from the icon theme, as the file manager's.

var
  iconsLoaded: bool
  gFileQueryInfo*: proc(f, attributes: pointer, flags: uint32,
                       cancellable: pointer,
                       gerr: ptr pointer): pointer {.cdecl.}
  gFileInfoGetIcon*: proc(info: pointer): pointer {.cdecl.}
  gDesktopAppInfoNewFromFile*: proc(path: cstring): pointer {.cdecl.}
  gAppInfoGetIcon*: proc(info: pointer): pointer {.cdecl.}
  gtkIconThemeGetDefault*: proc(): pointer {.cdecl.}
  gtkIconThemeLookupByGicon*: proc(theme, icon: pointer, size: int32,
                                 flags: uint32): pointer {.cdecl.}
  gtkIconInfoLoadIcon*: proc(info: pointer,
                            gerr: ptr pointer): pointer {.cdecl.}

proc loadIcons*() =
  if iconsLoaded: return
  iconsLoaded = true
  mustBind(libGIO, cast[ptr pointer](addr gFileQueryInfo), "g_file_query_info")
  mustBind(libGIO, cast[ptr pointer](addr gFileInfoGetIcon), "g_file_info_get_icon")
  mustBind(libGIO, cast[ptr pointer](addr gDesktopAppInfoNewFromFile),
    "g_desktop_app_info_new_from_filename")
  mustBind(libGIO, cast[ptr pointer](addr gAppInfoGetIcon), "g_app_info_get_icon")
  mustBind(libGTK, cast[ptr pointer](addr gtkIconThemeGetDefault),
    "gtk_icon_theme_get_default")
  mustBind(libGTK, cast[ptr pointer](addr gtkIconThemeLookupByGicon),
    "gtk_icon_theme_lookup_by_gicon")
  mustBind(libGTK, cast[ptr pointer](addr gtkIconInfoLoadIcon),
    "gtk_icon_info_load_icon")

proc themeIcon(icon: pointer, size: int): seq[byte]

## fileIcon returns the icon the file manager shows for a file or a
## folder, that of its content type (GIO's standard::icon), or the icon
## of the application of a desktop entry, from the icon theme at size by
## size pixels. Where the theme has no icon of the application, a
## desktop entry gets that of its content type, as other files do.
method fileIcon*(s: shellImpl, path: string, size: int):
    tuple[png: seq[byte], err: ref CatchableError] =
  try:
    discard getFileInfo(path)
  except OSError as e:
    return (@[], e)
  loadIcons()
  if path.endsWith(".desktop"):
    let app = gDesktopAppInfoNewFromFile(cs(path))
    if not app.isNil:
      let png = themeIcon(gAppInfoGetIcon(app), size)
      gObjectUnref(app)
      if png.len > 0:
        return (png, nil)
  let f = gFileNewForPath(cs(path))
  var gerr: pointer
  let info = gFileQueryInfo(f, cs("standard::icon"), 0, nil, addr gerr)
  gObjectUnref(f)
  if info.isNil:
    return (@[], gErr(gerr))
  defer: gObjectUnref(info)
  let png = themeIcon(gFileInfoGetIcon(info), size)
  if png.len > 0:
    return (png, nil)
  (@[], newException(CatchableError,
    "mynim: the icon theme has no icon for " & path))

## themeIcon draws a GIcon from the icon theme at size by size pixels, or
## returns none where the theme has none of its names.
proc themeIcon(icon: pointer, size: int): seq[byte] =
  if icon.isNil: return @[]
  # GIO's themed icons list their generic names themselves, and GTK
  # takes GTK_ICON_LOOKUP_GENERIC_FALLBACK only with names of its own.
  const flags = 1'u32 shl 4 # GTK_ICON_LOOKUP_FORCE_SIZE
  let info = gtkIconThemeLookupByGicon(gtkIconThemeGetDefault(), icon,
    int32(size), flags)
  if info.isNil: return @[]
  defer: gObjectUnref(info)
  let pix = gtkIconInfoLoadIcon(info, nil)
  if pix.isNil: return @[]
  defer: gObjectUnref(pix)
  pngFromPixbuf(pix)
