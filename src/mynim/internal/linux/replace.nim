## replace.nim: replaceFile renames replacement over target, after giving
## it the target's permissions and, where the user may, its owner and
## group, as GIO's g_file_replace does.

method replaceFile*(b: Backend, target, replacement: string) =
  var st: Stat
  if stat(target.cstring, st) == 0:
    if chmod(replacement.cstring, st.st_mode and 0o7777.Mode) != 0:
      raiseOSError(osLastError())
    discard lchown(replacement.cstring, st.st_uid, st.st_gid)
  try:
    moveFile(replacement, target)
  except OSError as e:
    raise e
