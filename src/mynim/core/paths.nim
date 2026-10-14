## paths.go — well known directories. PathName lives in types.nim.

proc resourcesDir(exe, wd: string): string =
  ## The resource directory of the executable exe, given the working
  ## directory wd.
  var exe = exe
  try:
    exe = expandSymlink(exe)
  except OSError:
    discard
  let dir = exe.parentDir()
  if dir.lastPathPart() == "MacOS" and
      dir.parentDir().lastPathPart() == "Contents":
    return dir.parentDir() / "Resources"
  # nimble run and test builds produce temporary executables; take the
  # working directory's resources then.
  var d = dir
  for i in 0..<3:
    if d.lastPathPart().startsWith("go-build") or
        d.lastPathPart().startsWith("nimble") or
        d.lastPathPart().startsWith("nimcache"):
      return wd / "resources"
    d = d.parentDir()
  dir

proc userDir(home: string; name: PathName): string =
  ## Resolves the user's standard folders, honoring the XDG user dirs
  ## configuration on Linux.
  let folder = case name
    of pathDesktop: "Desktop"
    of pathDocuments: "Documents"
    of pathDownloads: "Downloads"
    of pathMusic: "Music"
    of pathPictures: "Pictures"
    of pathVideos:
      when defined(macosx): "Movies" else: "Videos"
    else: ""
  when defined(linux):
    let key = case name
      of pathDesktop: "XDG_DESKTOP_DIR"
      of pathDocuments: "XDG_DOCUMENTS_DIR"
      of pathDownloads: "XDG_DOWNLOAD_DIR"
      of pathMusic: "XDG_MUSIC_DIR"
      of pathPictures: "XDG_PICTURES_DIR"
      of pathVideos: "XDG_VIDEOS_DIR"
      else: ""
    let config = getEnv("XDG_CONFIG_HOME", home / ".config")
    try:
      for line in readFile(config / "user-dirs.dirs").splitLines():
        let eq = line.strip().find('=')
        if eq > 0 and line[0..<eq] == key:
          return line[eq + 1..^1].strip(chars = {'"'})
            .replace("$HOME", home)
    except IOError:
      discard
  home / folder

proc defaultPath(name: PathName): tuple[path: string, create: bool] =
  let home = getHomeDir().strip(trailing = true, chars = {'/'})
  case name
  of pathHome:
    (home, false)
  of pathAppData:
    (getConfigDir().strip(trailing = true, chars = {'/'}), false)
  of pathUserData:
    (getConfigDir() / app.name(), true)
  of pathCache:
    (getCacheDir() / app.name(), true)
  of pathLogs:
    when defined(macosx):
      (home / "Library" / "Logs" / app.name(), true)
    else:
      (getConfigDir() / app.name() / "logs", true)
  of pathTemp:
    (getTempDir().strip(trailing = true, chars = {'/'}), false)
  of pathResources:
    (resourcesDir(getAppFilename(), getCurrentDir()), false)
  of pathExe:
    (getAppFilename(), false)
  of pathDesktop, pathDocuments, pathDownloads, pathMusic, pathPictures,
     pathVideos:
    (userDir(home, name), false)

proc path*(a: Application; name: PathName): string =
  ## Returns a well known directory, for example where to store user
  ## data:
  ##
  ##   let dir = app.path(pathUserData)
  a.mu.acquire()
  let override = a.paths.getOrDefault(name)
  a.mu.release()
  if override != "":
    return override
  let (p, create) = defaultPath(name)
  if create:
    createDir(p)
  p

proc setPath*(a: Application; name: PathName; path: string) =
  ## Overrides a directory returned by path.
  a.mu.acquire()
  a.paths[name] = path
  a.mu.release()
