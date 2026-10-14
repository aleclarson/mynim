## secrets.go: secretsImpl as generic passwords of the login Keychain, the
## service and account as keytar does. It uses the file-based keychain:
## the data protection one needs a signed app with a
## keychain-access-groups entitlement (unsigned builds get
## errSecMissingEntitlement).

type secretsImpl = ref object of Secrets

const
  errSecItemNotFound = -25300
  errSecDuplicateItem = -25299

## The Security framework, loaded with the first secret.
type
  KeychainAPI = object
    err*: ref CatchableError
    add*: proc(query, res: pointer): int32 {.cdecl.}
    copy*: proc(query, res: pointer): int32 {.cdecl.}
    update*: proc(query, attrs: pointer): int32 {.cdecl.}
    delete*: proc(query: pointer): int32 {.cdecl.}
    message*: proc(status: int32, reserved: pointer): pointer {.cdecl.}
    `class`*, genericPassword*: id
    service*, account*, label*: id
    valueData*, returnData*: id
    matchLimit*, matchLimitOne*, cfTrue*: id

var keychainLoaded = false
var keychainAPI: KeychainAPI

proc keychain(): KeychainAPI =
  if not keychainLoaded:
    keychainLoaded = true
    let lib = dlopen(
      "/System/Library/Frameworks/Security.framework/Security",
      rtldGlobal or rtldNow)
    if lib.isNil:
      keychainAPI.err = newException(IOError,
        "cannot load the Security framework")
      return keychainAPI
    keychainAPI.add = cast[typeof keychainAPI.add](
      mustDlsym(lib, "SecItemAdd"))
    keychainAPI.copy = cast[typeof keychainAPI.copy](
      mustDlsym(lib, "SecItemCopyMatching"))
    keychainAPI.update = cast[typeof keychainAPI.update](
      mustDlsym(lib, "SecItemUpdate"))
    keychainAPI.delete = cast[typeof keychainAPI.delete](
      mustDlsym(lib, "SecItemDelete"))
    keychainAPI.message = cast[typeof keychainAPI.message](
      mustDlsym(lib, "SecCopyErrorMessageString"))
    keychainAPI.`class` = constString(lib, "kSecClass")
    keychainAPI.genericPassword = constString(lib,
                                              "kSecClassGenericPassword")
    keychainAPI.service = constString(lib, "kSecAttrService")
    keychainAPI.account = constString(lib, "kSecAttrAccount")
    keychainAPI.label = constString(lib, "kSecAttrLabel")
    keychainAPI.valueData = constString(lib, "kSecValueData")
    keychainAPI.returnData = constString(lib, "kSecReturnData")
    keychainAPI.matchLimit = constString(lib, "kSecMatchLimit")
    keychainAPI.matchLimitOne = constString(lib, "kSecMatchLimitOne")
    keychainAPI.cfTrue = constString(libCFH, "kCFBooleanTrue")
  keychainAPI

## query returns an autoreleased dictionary that finds the item of
## service and account.
proc query(k: KeychainAPI, service, account: string): id =
  let q = send(`class`("NSMutableDictionary"), "dictionary")
  proc set(key, v: id) =
    discard send(q, "setObject:forKey:", argu(v), argu(key))
  set(k.`class`, k.genericPassword)
  set(k.service, nsString(service))
  set(k.account, nsString(account))
  q

## status converts an OSStatus into an error with the system's message.
proc status(k: KeychainAPI, op: string, s: int32): ref CatchableError =
  case s
  of 0:
    return nil
  of errSecItemNotFound:
    return errSecretNotFound()
  else:
    discard
  var msg = ""
  let str = k.message(s, nil)
  if not str.isNil:
    msg = goString(id(str))
    cfRelease(str)
  if msg == "":
    msg = "unknown error"
  newException(ValueError,
    "keychain: " & op & ": " & msg & " (OSStatus " & $s & ")")

method setSecret*(s: secretsImpl, service, account: string,
                  secret: openArray[byte]) =
  let k = keychain()
  if k.err != nil:
    raise k.err
  var err: ref CatchableError = nil
  let bytes = @secret
  withPool(proc() =
    let data = nsData(bytes)
    let update = send(`class`("NSMutableDictionary"), "dictionary")
    discard send(update, "setObject:forKey:", argu(data),
                 argu(k.valueData))
    var st = k.update(k.query(service, account), update)
    if st != errSecItemNotFound:
      err = k.status("update", st)
      return
    let add = k.query(service, account)
    discard send(add, "setObject:forKey:", argu(data), argu(k.valueData))
    discard send(add, "setObject:forKey:", argu(nsString(service)),
                 argu(k.label))
    st = k.add(add, nil)
    if st == errSecDuplicateItem:
      # Added by another thread or process since the update.
      st = k.update(k.query(service, account), update)
      err = k.status("update", st)
    else:
      err = k.status("add", st))
  if err != nil:
    raise err

method secret*(s: secretsImpl, service, account: string): seq[byte] =
  let k = keychain()
  if k.err != nil:
    raise k.err
  var err: ref CatchableError = nil
  var res: seq[byte]
  withPool(proc() =
    let q = k.query(service, account)
    discard send(q, "setObject:forKey:", argu(k.cfTrue),
                 argu(k.returnData))
    discard send(q, "setObject:forKey:", argu(k.matchLimitOne),
                 argu(k.matchLimit))
    var data: pointer
    let st = k.copy(q, addr data)
    err = k.status("read", st)
    if err != nil:
      return
    if data.isNil:
      err = newException(IOError, "keychain: read: no data")
      return
    res = goBytes(id(data))
    cfRelease(data))
  if err != nil:
    raise err
  res

method deleteSecret*(s: secretsImpl, service, account: string) =
  let k = keychain()
  if k.err != nil:
    raise k.err
  var err: ref CatchableError = nil
  withPool(proc() =
    let st = k.delete(k.query(service, account))
    err = k.status("delete", st)
    if isErrSecretNotFound(err):
      err = nil)
  if err != nil:
    raise err
