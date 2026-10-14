## secrets.go — small secrets in the system's credential store.


## errSecretNotFound is what secrets.get fails with when no secret is
## stored for the key (platform.errSecretNotFound).
##
## maxSecretSize is the largest secret secrets.set stores, in bytes: the
## most the Windows Credential Manager keeps, so that an app behaves the
## same everywhere.
const maxSecretSize* = 2560

## maxSecretKeyLen is the longest key, in bytes, well within the
## Credential Manager's 513 characters for the user name.
const maxSecretKeyLen = 256

proc checkSecretKey(key: string) =
  if key == "":
    raise newException(ValueError, "mynim: empty secret key")
  if key.len > maxSecretKeyLen:
    raise newException(ValueError,
      "mynim: secret key has " & $key.len & " bytes, more than " &
      $maxSecretKeyLen)
  if '\x00' in key:
    raise newException(ValueError,
      "mynim: secret key " & key.escape() & " contains NUL")

proc wrapSecretErr(err: ref CatchableError): ref CatchableError =
  ## Keeps errSecretNotFound as is and names the store in other errors.
  if err == nil: return nil
  if err of PlatformError and err.msg == "mynim: secret not found":
    return err
  if err.msg.startsWith("mynim: ") or err.msg.startsWith("mygo: "):
    return err
  newException(ValueError, "mynim: secrets: " & err.msg)

proc offMain*[T](fn: proc(): T {.closure.}): T =
  ## Runs fn, which may block for long, e.g. while the system asks the
  ## user something, without blocking the event loop: on the main thread
  ## of a running app fn runs on another thread while await handles
  ## native events. Elsewhere, before run and after the loop stopped, it
  ## runs fn directly.
  if not isMainThread() or not app.initialized or loop.stopped():
    return fn()
  type Ctx = object
    ch: system.Channel[bool]
    v: T
    fn: proc(): T {.closure.}
  let ctx = cast[ptr Ctx](allocShared0(sizeof(Ctx)))
  ctx.ch.open()
  ctx.fn = fn
  var t: Thread[ptr Ctx]
  createThread(t, proc(c: ptr Ctx) {.thread.} =
    {.cast(gcsafe).}:
      c.v = c.fn()
      c.ch.send(true)
      backend().wake(), ctx)
  discard ctx.ch.await()
  ctx.ch.close()
  joinThread(t)
  result = move(ctx.v)
  deallocShared(ctx)

proc set*(s: SecretsModule; key: string; value: seq[byte]) =
  ## Stores value under key, replacing what it had. The key must not be
  ## empty or longer than 256 bytes; the value may be at most
  ## maxSecretSize bytes.
  checkSecretKey(key)
  if value.len > maxSecretSize:
    raise newException(ValueError,
      "mynim: secret " & key.escape() & " has " & $value.len &
      " bytes, more than maxSecretSize (" & $maxSecretSize & ")")
  let service = appID()
  let err = offMain(proc(): ref CatchableError =
    try:
      backend().secrets().setSecret(service, key, value)
      nil
    except CatchableError as e:
      wrapSecretErr(e))
  if err != nil: raise err

proc get*(s: SecretsModule; key: string): seq[byte] =
  ## The secret stored under key, or raises errSecretNotFound.
  checkSecretKey(key)
  let service = appID()
  let (v, err) = offMain(proc(): tuple[v: seq[byte], err: ref CatchableError] =
    let (v, e) = backend().secrets().secret(service, key)
    (v, wrapSecretErr(e)))
  if err != nil: raise err
  v

proc delete*(s: SecretsModule; key: string) =
  ## Removes the secret stored under key. Deleting a key without a
  ## secret is not an error.
  checkSecretKey(key)
  let service = appID()
  let err = offMain(proc(): ref CatchableError =
    try:
      backend().secrets().deleteSecret(service, key)
      nil
    except CatchableError as e:
      wrapSecretErr(e))
  if err != nil: raise err
