## secrets.nim (secrets.go): secrets as generic credentials of the
## Credential Manager, as keytar does: the target is
## "service/account", the user name the account, and they persist like
## keytar's, roaming with the user's profile on a domain. The system
## encrypts them for the user (DPAPI). The functions may be called
## from any thread.

const
  credTypeGeneric* = 1'u32
  credPersistEnterprise* = 3'u32
  errorNotFound* = 1168'u32

## credential is CREDENTIALW.
type credential* = object
  flags*, `type`*: uint32
  targetName*, comment*: ptr uint16
  lastWritten*: array[2, uint32] ## FILETIME
  credentialBlobSize*: uint32
  credentialBlob*: ptr byte
  persist*, attributeCount*: uint32
  attributes*: uint
  targetAlias*, userName*: ptr uint16

proc credTarget(service, account: string): pointer = u16(service & "/" & account)

proc credErr(op: string, e: uint): ref CatchableError =
  if uint32(e) == errorNotFound:
    return errSecretNotFound()
  newException(CatchableError, "credential manager: " & op & ": " & $e)

method setSecret*(s: w32Secrets, service, account: string,
    secret: seq[byte]) =
  var c = credential(`type`: credTypeGeneric,
    persist: credPersistEnterprise,
    userName: cast[ptr uint16](u16(account)),
    credentialBlobSize: uint32(secret.len))
  c.targetName = cast[ptr uint16](credTarget(service, account))
  if secret.len > 0:
    c.credentialBlob = unsafeAddr secret[0]
  let r = procCredWriteW(cast[uint](addr c), 0)
  if r == 0:
    raise credErr("write", osLastError().uint)

method secret*(s: w32Secrets, service, account: string):
    tuple[secret: seq[byte], err: ref CatchableError] =
  var p: uint
  if procCredReadW(cast[uint](credTarget(service, account)),
      credTypeGeneric, 0, cast[uint](addr p)) == 0:
    return (@[], credErr("read", osLastError().uint))
  defer: discard procCredFree(p)
  let c = cast[ptr credential](cast[pointer](p))
  if c.credentialBlobSize == 0 or c.credentialBlob.isNil:
    return (@[], nil)
  var out0 = newSeq[byte](c.credentialBlobSize)
  copyMem(addr out0[0], c.credentialBlob, out0.len)
  (out0, nil)

method deleteSecret*(s: w32Secrets, service, account: string) =
  if procCredDeleteW(cast[uint](credTarget(service, account)),
      credTypeGeneric, 0) == 0:
    let e = credErr("delete", osLastError().uint)
    if not e.isNil and not isErrSecretNotFound(e):
      raise e
