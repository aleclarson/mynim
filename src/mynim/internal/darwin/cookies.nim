## cookies.go: the WKWebsiteDataStore cookie store. NSHTTPCookie is
## built through a Set-Cookie header, the only API that accepts
## SameSite.

proc cookieStore(): tuple[s: id, err: ref CatchableError] =
  let store = send(`class`("WKWebsiteDataStore"), "defaultDataStore")
  if not sendBool(store, "respondsToSelector:",
                  argu(sel("httpCookieStore"))) or
      not sendBool(`class`("NSHTTPCookie"), "instancesRespondToSelector:",
                   argu(sel("sameSitePolicy"))):
    return (nil, newException(PlatformError,
      "mynim: cookies: requires macOS 10.15 or newer: not supported on this platform"))
  (send(store, "httpCookieStore"), nil)

proc readCookie(c: id): Cookie =
  result = Cookie(name: goString(send(c, "name")),
                  value: goString(send(c, "value")),
                  domain: goString(send(c, "domain")).toLowerAscii,
                  path: goString(send(c, "path")),
                  secure: sendBool(c, "isSecure"),
                  httpOnly: sendBool(c, "isHTTPOnly"))
  ## Foundation names only Lax and Strict, and macOS 26 gives a cookie
  ## set with SameSite=None no policy, which WebKit sends as None
  ## (coreSameSitePolicy in CookieCocoa.mm).
  result.sameSite = goString(send(c, "sameSitePolicy")).toLowerAscii
  if result.sameSite == "":
    result.sameSite = "none"
  let date = send(c, "expiresDate")
  if not date.isNil and not sendBool(c, "isSessionOnly"):
    result.expires = fromUnix(
      int64(msgFloat(date, sel("timeIntervalSince1970"))))

method listCookies*(a: appController,
    done: proc(c: seq[Cookie], err: ref CatchableError)) =
  withPool(proc() =
    let (store, err) = cookieStore()
    if err != nil:
      done(@[], err)
      return
    let blk = mkBlockId(proc(arr: id) =
      var res: seq[Cookie]
      withPool(proc() =
        for c in arrayItems(arr):
          res.add readCookie(c))
      a.b.runOnMain(proc() = done(res, nil)))
    discard send(store, "getAllCookies:", argu(blk))
    blockRelease(blk))

method setCookie*(a: appController, cookie: Cookie,
    done: proc(err: ref CatchableError)) =
  withPool(proc() =
    let (store, err) = cookieStore()
    if err != nil:
      done(err)
      return
    var host = cookie.domain
    if host.startsWith("."):
      host = host[1 .. ^1]
    if host.contains(":"):
      host = "[" & host & "]"
    let scheme = (if cookie.secure: "https" else: "http")
    var header = cookie.name & "=" & cookie.value & "; Path=" &
      cookie.path & "; SameSite=" & cookie.sameSite
    if cookie.domain.startsWith("."):
      header &= "; Domain=" & cookie.domain
    if cookie.expires != default(times.Time):
      header &= "; Expires=" & cookie.expires.format(
        "ddd, dd MMM yyyy HH:mm:ss 'GMT'", utc())
    if cookie.secure:
      header &= "; Secure"
    if cookie.httpOnly:
      header &= "; HttpOnly"
    let headers = send(`class`("NSDictionary"),
      "dictionaryWithObject:forKey:", argu(nsString(header)),
      argu(nsString("Set-Cookie")))
    let arr = send(`class`("NSHTTPCookie"),
      "cookiesWithResponseHeaderFields:forURL:", argu(headers),
      argu(nsURL(scheme & "://" & host & "/")))
    if sendInt(arr, "count") != 1:
      done(newException(PlatformError,
        "mynim: cookies: Set could not construct NSHTTPCookie"))
      return
    let native = send(arr, "objectAtIndex:", argu(0))
    let parsed = readCookie(native)
    if parsed.name != cookie.name or parsed.domain != cookie.domain or
        parsed.path != cookie.path or parsed.value != cookie.value or
        parsed.secure != cookie.secure or
        parsed.httpOnly != cookie.httpOnly or
        parsed.sameSite != cookie.sameSite:
      ## Say what differs, without the value.
      var p = parsed
      p.value = ""
      var c = cookie
      c.value = ""
      done(newException(PlatformError,
        "mynim: cookies: Set made NSHTTPCookie " & $p & " of " & $c))
      return
    let blk = mkBlockVoid(proc() =
      a.b.runOnMain(proc() = done(nil)))
    discard send(store, "setCookie:completionHandler:", argu(native),
                 argu(blk))
    blockRelease(blk))

method deleteCookie*(a: appController, key: CookieKey,
    done: proc(err: ref CatchableError)) =
  withPool(proc() =
    let (store, err) = cookieStore()
    if err != nil:
      done(err)
      return
    discard retain(store)
    let blk = mkBlockId(proc(arr: id) =
      ## The borrowed array must survive dispatch to main.
      discard retain(arr)
      a.b.runOnMain(proc() =
        withPool(proc() =
          defer: release(arr)
          var match: id
          for c in arrayItems(arr):
            if goString(send(c, "name")) == key.name and
                goString(send(c, "domain")).toLowerAscii == key.domain and
                goString(send(c, "path")) == key.path:
              if not match.isNil:
                release(store)
                done(newException(PlatformError,
                  "mynim: cookies: ambiguous cookie key"))
                return
              match = c
          if match.isNil:
            release(store)
            done(nil)
            return
          discard retain(match)
          let completion = mkBlockVoid(proc() =
            a.b.runOnMain(proc() =
              release(match)
              release(store)
              done(nil)))
          discard send(store, "deleteCookie:completionHandler:",
                       argu(match), argu(completion))
          blockRelease(completion))))
    discard send(store, "getAllCookies:", argu(blk))
    blockRelease(blk))
