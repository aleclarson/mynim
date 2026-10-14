## deeplink.go: the URL schemes of a bundle are declared in its
## Info.plist (CFBundleURLTypes), which Launch Services registers. What
## an app can do at run time is become the default handler of one of
## them.

## declaresScheme reports whether the Info.plist of bundle lists
## scheme. Must run in a pool.
proc declaresScheme(bundle: id, scheme: string): bool =
  for t in arrayItems(send(bundle, "objectForInfoDictionaryKey:",
                           argu(nsString("CFBundleURLTypes")))):
    for s in arrayItems(send(t, "objectForKey:",
                             argu(nsString("CFBundleURLSchemes")))):
      if toLowerAscii(goString(s)) == toLowerAscii(scheme):
        return true

method registerURLScheme*(a: appController, scheme, id, name: string) =
  var err: ref CatchableError = nil
  withPool(proc() =
    let bundle = send(`class`("NSBundle"), "mainBundle")
    if not declaresScheme(bundle, scheme):
      err = newException(ValueError,
        "mynim: the app does not declare the URL scheme " &
        scheme.escape() &
        ": list it in urlSchemes in mynim.config.ts")
      return
    let status = lsSetDefaultHandlerForURLScheme(nsString(scheme),
                                send(bundle, "bundleIdentifier"))
    if status != 0:
      err = newException(ValueError,
        "mynim: cannot handle the URL scheme " & scheme.escape() &
        " (Launch Services error " & $status & ")"))
  if err != nil:
    raise err

## unregisterURLScheme is not supported: the scheme belongs to the
## bundle.
method unregisterURLScheme*(a: appController, scheme, id,
                            name: string) =
  raise errUnsupported()

method isURLSchemeRegistered*(a: appController, scheme, id,
                              name: string): bool =
  var res: bool
  withPool(proc() =
    let handler = lsCopyDefaultHandlerForURLScheme(nsString(scheme))
    if handler.isNil:
      return
    defer: cfRelease(handler)
    res = toLowerAscii(goString(handler)) ==
      toLowerAscii(goString(send(send(`class`("NSBundle"), "mainBundle"),
                    "bundleIdentifier"))))

  res