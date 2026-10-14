## apps.go: the .app bundles of the app folders.

## appDirs are the folders apps are installed in, as Spotlight and
## Launchpad find them: apps in a folder of their own one level down too.
proc appDirs(): seq[string] =
  result = @[
    "/Applications",
    "/System/Applications",
    "/System/Library/CoreServices/Applications",
  ]
  let home = getHomeDir()
  if home != "":
    result.add home / "Applications"

## applications finds the .app bundles in the folders apps are installed
## in and those one level down (Utilities, an app's folder), without
## looking inside bundles, and Finder (which is in CoreServices), each
## once: an app a symbolic link points to, as /Applications/Safari.app
## does, is listed at the link, which fileIcon draws without the badge of
## links. Each has the name Finder shows (localized, without .app) and
## its bundle identifier, or its path without one.
method applications*(b: Backend): seq[platform.Application] =
  var paths: seq[string]
  var seen: HashSet[string]
  proc add(p: string) =
    var real = p
    try:
      real = expandFilename(p)
    except OSError:
      discard
    if real notin seen:
      seen.incl(real)
      paths.add(p)
  for dir in appDirs():
    var entries: seq[tuple[kind: PathComponent, path: string]]
    try:
      for e in walkDir(dir):
        entries.add e
    except OSError:
      discard
    for e in entries:
      if e.path.endsWith(".app"):
        add(e.path)
        continue
      if e.kind != pcDir and e.kind != pcLinkToDir:
        continue
      try:
        for s in walkDir(e.path):
          if s.path.endsWith(".app"):
            add(s.path)
      except OSError:
        discard
  add("/System/Library/CoreServices/Finder.app")

  var apps: seq[platform.Application]
  withPool(proc() =
    let fm = send(`class`("NSFileManager"), "defaultManager")
    for p in paths:
      let ns = nsString(p)
      let bundle = send(`class`("NSBundle"), "bundleWithPath:", argu(ns))
      if bundle.isNil:
        continue
      var a = platform.Application(
        # Finder shows .app where the user has it show all extensions;
        # Launchpad and Spotlight never do.
        name: goString(send(fm, "displayNameAtPath:", argu(ns))),
        id: goString(send(bundle, "bundleIdentifier")),
        path: p)
      if a.name.endsWith(".app"):
        a.name.setLen(a.name.len - 4)
      if a.id == "":
        a.id = p # as Steam's shortcuts to games, which have none
      apps.add(a))
  apps

## openApplication starts an app, or brings it to the front.
method openApplication*(s: shellImpl, path: string) = s.openPath(path)
