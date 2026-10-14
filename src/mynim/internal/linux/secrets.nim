## secrets.nim: secrets keep in the Secret Service (GNOME Keyring,
## KWallet, KeePassXC…) through libsecret, with keytar's schema: the
## generic one, whose attributes are the service and account. libsecret
## loads with the first secret, independently of GTK, so secrets work
## before Init and from any thread: its synchronous calls run their own
## main context.

var libsecretOnce: bool
var secretLib: secretAPI

proc loadSecret(): secretAPI =
  if not libsecretOnce:
    libsecretOnce = true
    secretLib = secretAPI()
    var (glib, err) = openLib("libglib-2.0.so.0")
    if not err.isNil:
      secretLib.err = err
      return secretLib
    let (lib, err2) = openLib("libsecret-1.so.0")
    if not err2.isNil:
      secretLib.err = newException(CatchableError, err2.msg &
        " (install libsecret: libsecret-1-0 on Debian/Ubuntu, libsecret on Fedora)")
      return secretLib
    mustBind(glib, cast[ptr pointer](addr secretLib.hashTableNewFull),
      "g_hash_table_new_full")
    mustBind(glib, cast[ptr pointer](addr secretLib.hashTableInsert),
      "g_hash_table_insert")
    mustBind(glib, cast[ptr pointer](addr secretLib.hashTableUnref),
      "g_hash_table_unref")
    mustBind(glib, cast[ptr pointer](addr secretLib.strdup), "g_strdup")
    mustBind(glib, cast[ptr pointer](addr secretLib.free), "g_free")
    mustBind(glib, cast[ptr pointer](addr secretLib.errorFree),
      "g_error_free")
    for (p, name) in [(addr secretLib.strHash, "g_str_hash"),
                      (addr secretLib.strEqual, "g_str_equal"),
                      (addr secretLib.freeFn, "g_free")]:
      p[] = glib.symAddr(name)
      if p[].isNil:
        secretLib.err = newException(CatchableError,
          "mynim: missing symbol " & name)
        return secretLib
    let ok = bindFunc(lib, cast[ptr pointer](addr secretLib.schemaNewv),
        "secret_schema_newv") and
      bindFunc(lib, cast[ptr pointer](addr secretLib.schemaUnref),
        "secret_schema_unref") and
      bindFunc(lib, cast[ptr pointer](addr secretLib.valueNew),
        "secret_value_new") and
      bindFunc(lib, cast[ptr pointer](addr secretLib.valueGet),
        "secret_value_get") and
      bindFunc(lib, cast[ptr pointer](addr secretLib.valueUnref),
        "secret_value_unref") and
      bindFunc(lib, cast[ptr pointer](addr secretLib.passwordStoreSync),
        "secret_password_storev_binary_sync") and
      bindFunc(lib, cast[ptr pointer](addr secretLib.passwordLookupSync),
        "secret_password_lookupv_binary_sync") and
      bindFunc(lib, cast[ptr pointer](addr secretLib.passwordClearSync),
        "secret_password_clearv_sync")
    if not ok:
      secretLib.err = newException(CatchableError,
        "libsecret is too old: secrets need libsecret 0.19 or later")
      return secretLib
    let types = secretLib.hashTableNewFull(secretLib.strHash,
      secretLib.strEqual, secretLib.freeFn, nil)
    discard secretLib.hashTableInsert(types,
      secretLib.strdup(cs("service")), nil) # SECRET_SCHEMA_ATTRIBUTE_STRING
    discard secretLib.hashTableInsert(types,
      secretLib.strdup(cs("account")), nil)
    secretLib.schema = secretLib.schemaNewv(
      cs("org.freedesktop.Secret.Generic"), 0, types) # SECRET_SCHEMA_NONE
    secretLib.hashTableUnref(types)
  secretLib

## attributes returns a new hash table with the attributes of the secret
## of service and account, which the caller unrefs.
proc attributes(s: secretAPI, service, account: string): pointer =
  let t = s.hashTableNewFull(s.strHash, s.strEqual, s.freeFn, s.freeFn)
  discard s.hashTableInsert(t, s.strdup(cs("service")), s.strdup(cs(service)))
  discard s.hashTableInsert(t, s.strdup(cs("account")), s.strdup(cs(account)))
  t

## gErr converts and frees a GError without needing GTK's bindings.
proc gErrSecret(s: secretAPI, e: pointer): ref CatchableError =
  if e.isNil: return nil
  let msg = goStr(field[pointer](e, 8))
  s.errorFree(e)
  newException(CatchableError, "secret service: " & msg)

method setSecret*(s: secretsImpl, service, account: string,
    secret: seq[byte]) =
  let api = loadSecret()
  if not api.err.isNil: raise api.err
  let attrs = api.attributes(service, account)
  defer: api.hashTableUnref(attrs)
  var data = secret
  if data.len == 0:
    data = @[0'u8] # a valid pointer for an empty secret
  let value = api.valueNew(addr data[0], data.len,
    cs("application/octet-stream"))
  defer: api.valueUnref(value)
  var gerr: pointer
  if not api.passwordStoreSync(api.schema, attrs, nil,
      cast[pointer](cs(service & "/" & account)), value, nil, addr gerr):
    let err = api.gErrSecret(gerr)
    if not err.isNil:
      raise err
    raise newException(CatchableError,
      "secret service: cannot store the secret")

method secret*(s: secretsImpl, service, account: string):
    tuple[data: seq[byte], err: ref CatchableError] =
  let api = loadSecret()
  if not api.err.isNil: return (@[], api.err)
  let attrs = api.attributes(service, account)
  defer: api.hashTableUnref(attrs)
  var gerr: pointer
  let value = api.passwordLookupSync(api.schema, attrs, nil, addr gerr)
  let err = api.gErrSecret(gerr)
  if not err.isNil:
    if not value.isNil: api.valueUnref(value)
    return (@[], err)
  if value.isNil:
    return (@[], errSecretNotFound())
  defer: api.valueUnref(value)
  var n: uint
  let p = api.valueGet(value, addr n)
  if p.isNil or n == 0:
    return (@[], nil)
  let base = cast[ptr UncheckedArray[byte]](cast[ptr pointer](addr p)[])
  (@(toOpenArray(base, 0, int(n) - 1)), nil)

method deleteSecret*(s: secretsImpl, service, account: string) =
  let api = loadSecret()
  if not api.err.isNil: raise api.err
  let attrs = api.attributes(service, account)
  defer: api.hashTableUnref(attrs)
  var gerr: pointer
  discard api.passwordClearSync(api.schema, attrs, nil, addr gerr)
    # false without an error: nothing to delete
  let err = api.gErrSecret(gerr)
  if not err.isNil: raise err
