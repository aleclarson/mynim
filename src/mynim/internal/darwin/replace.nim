## replace.go: -[NSFileManager replaceItemAtURL:withItemAtURL:…],
## NSDocument's safe save: the target keeps its permissions, creation
## date, extended attributes (Finder tags, Finder info) and ACLs, and
## its identity, so that aliases still find it.

method replaceFile*(b: Backend, target, replacement: string) =
  if not fileExists(target) and not symlinkExists(target):
    moveFile(replacement, target)
    return
  loadFrameworks()
  var err: ref CatchableError = nil
  withPool(proc() =
    let fm = send(`class`("NSFileManager"), "defaultManager")
    var nsErr: id
    let ok = sendBool(fm,
      "replaceItemAtURL:withItemAtURL:backupItemName:options:resultingItemURL:error:",
      argu(fileURL(target)), argu(fileURL(replacement)), argu(nil),
      argu(0), argu(nil), argu(cast[pointer](addr nsErr)))
    if not ok:
      var msg = "cannot replace the file"
      if not nsErr.isNil:
        msg = goString(send(nsErr, "localizedDescription"))
      err = newException(IOError,
        "replace: " & replacement & " -> " & target & ": " & msg))
  if err != nil:
    raise err
