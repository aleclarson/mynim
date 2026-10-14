## replace.nim (replace.go): ReplaceFileW, which keeps the target's
## security descriptor, attributes, alternate data streams and
## creation time, as Office's replacement does.

const
  replacefileIgnoreMergeErrors* = 0x2'u
  replacefileIgnoreACLErrors* = 0x4'u

  errorUnableToRemoveReplaced* = 1175'u32
  errorUnableToMoveReplacement* = 1176'u32
  errorSharingViolation* = 32'u32
  errorLockViolation* = 33'u32
  errorAccessDenied* = 5'u32

proc linkError(op, old, new: string, code: uint): ref CatchableError =
  newException(CatchableError, op & " " & old & " " & new &
    ": " & $code)

## replaceFile replaces target with ReplaceFileW. Another program
## holding the target open without sharing deletes (an indexer, an
## antivirus, a cloud client) gets a moment to let go.
method replaceFile*(b: WinBackend, target, replacement: string) =
  if not fileExists(target) and not dirExists(target):
    moveFile(replacement, target)
    return
  for attempt in 0 .. 9:
    if procReplaceFileW(cast[uint](u16(target)),
        cast[uint](u16(replacement)), 0,
        replacefileIgnoreMergeErrors or replacefileIgnoreACLErrors,
        0, 0) != 0:
      return
    let errno = uint32(osLastError())
    let retry = errno == errorSharingViolation or
      errno == errorLockViolation or errno == errorAccessDenied or
      errno == errorUnableToRemoveReplaced
    if not retry or attempt == 9:
      raise linkError("replace", replacement, target, errno)
    sleep(50)
