## apps.nim (apps.go): the apps of the Start menu's All apps list, the
## shell's Applications folder (FOLDERID_AppsFolder).

var
  folderIDAppsFolder* = guid("1e87508d-89c2-42f0-8a7e-645a0f50ca58")
  bhidEnumItems* = guid("94f60519-2850-4924-aa5a-d15e84868039")
  iidIEnumShellItems* = guid("70629033-e363-4a28-a567-0db78006e6d7")
  iidIShellItem* = guid("43826d1e-e718-42ee-bc55-a1e261c37bfe")

const appsFolder* = "shell:AppsFolder\\"

## Applications lists the apps of the Applications folder: desktop
## apps by their shortcuts and packaged apps alike. An app's ID is
## its AppUserModelID, or for a desktop app without one, its path
## under a known folder; its path is the shell item,
## shell:AppsFolder\<ID>, which fileIcon draws and openApplication
## starts. It runs on a thread of its own, in its own COM apartment.
method applications*(b: WinBackend): tuple[apps: seq[Application],
    err: ref CatchableError] =
  var r = procCoInitializeEx(0, coinitApartmentThreaded)
  if not failed(r):
    defer: discard procCoUninitialize()
  var folder: uint
  r = procSHGetKnownFolderItem(cast[uint](addr folderIDAppsFolder), 0,
    0, cast[uint](addr iidIShellItem), cast[uint](addr folder))
  if failed(r):
    return (@[], hresultError("SHGetKnownFolderItem(AppsFolder)", r))
  defer: release(folder)
  var items: uint
  r = comCall(folder, 3, 0, cast[uint](addr bhidEnumItems),
    cast[uint](addr iidIEnumShellItems), cast[uint](addr items))
  if failed(r): ## BindToHandler
    return (@[], hresultError("enumerating the Applications folder", r))
  defer: release(items)
  const
    sigdnNormalDisplay = 0'u
    sigdnParentRelativeParsing = 0x80018001'u
  var apps: seq[Application]
  while true:
    var item: uint
    var fetched: uint32
    if comCall(items, 3, 1, cast[uint](addr item),
        cast[uint](addr fetched)) != 0 or fetched == 0:
      break ## Next: S_FALSE at the end
    var name, id: uint
    discard comCall(item, 5, sigdnNormalDisplay,
      cast[uint](addr name)) ## GetDisplayName
    discard comCall(item, 5, sigdnParentRelativeParsing,
      cast[uint](addr id)) ## its ID in the folder
    release(item)
    let a = Application(name: takeWstr(cast[pointer](name)),
      id: takeWstr(cast[pointer](id)))
    if a.name == "" or a.id == "":
      continue
    var aa = a
    aa.path = appsFolder & a.id
    apps.add aa
  (apps, nil)

## shellExecute runs the default verb of a file or URL.
proc shellExecute*(verb, path, args: string): ref CatchableError =
  let r = procShellExecuteW(0, cast[uint](u16(verb)),
    cast[uint](u16(path)),
    if args.len > 0: cast[uint](u16(args)) else: 0, 0, swShow)
  if r <= 32:
    return newException(CatchableError,
      "mynim: shell execute of " & path & " failed (" & $r & ")")
  nil

## openApplication starts an app of the Applications folder by its
## shell item, with its default verb, or any program by its path.
method openApplication*(s: w32Shell, path: string) =
  discard shellExecute("", path, "")
