## cookies.nim: cookies of the default web context through WebKitGTK and
## libsoup. The two libsoup ABI generations share no pointer types, so
## SoupCookie code paths pick functions per generation (soup3).

var
  cookieManager*: proc(c: pointer): pointer {.cdecl.}
  cookieList*: proc(m, cancellable, cb, data: pointer) {.cdecl.}
  cookieListFinish*: proc(m, res: pointer, gerr: ptr pointer): pointer {.cdecl.}
  cookieAdd*, cookieDelete*: proc(m, cookie, cancellable, cb,
                                  data: pointer) {.cdecl.}
  cookieAddFinish*, cookieDeleteFinish*: proc(m, res: pointer,
    gerr: ptr pointer): int32 {.cdecl.}
  soupCookieNew*: proc(name, value, domain, path: cstring,
                       maxAge: int32): pointer {.cdecl.}
  soupCookieFree*: proc(c: pointer) {.cdecl.}
  soupCookieCopy*: proc(c: pointer): pointer {.cdecl.}
  soupCookieName*, soupCookieValue*, soupCookieDomain*, soupCookiePath*,
    soupCookieExpires*: proc(c: pointer): pointer {.cdecl.}
  soupCookieSecure*, soupCookieHTTPOnly*, soupCookieSameSite*:
    proc(c: pointer): int32 {.cdecl.}
  soupCookieSetSecure*, soupCookieSetHTTPOnly*, soupCookieSetSameSite*:
    proc(c: pointer, v: int32) {.cdecl.}
  soupCookieSetExpires*: proc(c, date: pointer) {.cdecl.}
  cookieDateNew*: proc(t: int64): pointer {.cdecl.}
  cookieDateUnix*: proc(d: pointer): int64 {.cdecl.}
  cookieDateFree*: proc(d: pointer) {.cdecl.}
  cookieListFree*: proc(list: pointer) {.cdecl.}

## cbAsyncReady routes GIO async completions through pending.
var cbAsyncReady*: pointer =
  cast[pointer](proc(source, res, data: pointer) {.cdecl.} =
    let fn = pending.take(data)
    if not fn.isNil:
      fn(source, res))

proc bindCookies*() =
  discard bindFunc(libWebKit, cast[ptr pointer](addr cookieManager),
    "webkit_web_context_get_cookie_manager")
  discard bindFunc(libWebKit, cast[ptr pointer](addr cookieList),
    "webkit_cookie_manager_get_all_cookies")
  discard bindFunc(libWebKit, cast[ptr pointer](addr cookieListFinish),
    "webkit_cookie_manager_get_all_cookies_finish")
  discard bindFunc(libWebKit, cast[ptr pointer](addr cookieAdd),
    "webkit_cookie_manager_add_cookie")
  discard bindFunc(libWebKit, cast[ptr pointer](addr cookieAddFinish),
    "webkit_cookie_manager_add_cookie_finish")
  discard bindFunc(libWebKit, cast[ptr pointer](addr cookieDelete),
    "webkit_cookie_manager_delete_cookie")
  discard bindFunc(libWebKit, cast[ptr pointer](addr cookieDeleteFinish),
    "webkit_cookie_manager_delete_cookie_finish")
  discard bindFunc(libSoup, cast[ptr pointer](addr soupCookieNew),
    "soup_cookie_new")
  discard bindFunc(libSoup, cast[ptr pointer](addr soupCookieFree),
    "soup_cookie_free")
  discard bindFunc(libSoup, cast[ptr pointer](addr soupCookieCopy),
    "soup_cookie_copy")
  discard bindFunc(libSoup, cast[ptr pointer](addr soupCookieName),
    "soup_cookie_get_name")
  discard bindFunc(libSoup, cast[ptr pointer](addr soupCookieValue),
    "soup_cookie_get_value")
  discard bindFunc(libSoup, cast[ptr pointer](addr soupCookieDomain),
    "soup_cookie_get_domain")
  discard bindFunc(libSoup, cast[ptr pointer](addr soupCookiePath),
    "soup_cookie_get_path")
  discard bindFunc(libSoup, cast[ptr pointer](addr soupCookieExpires),
    "soup_cookie_get_expires")
  discard bindFunc(libSoup, cast[ptr pointer](addr soupCookieSecure),
    "soup_cookie_get_secure")
  discard bindFunc(libSoup, cast[ptr pointer](addr soupCookieHTTPOnly),
    "soup_cookie_get_http_only")
  discard bindFunc(libSoup, cast[ptr pointer](addr soupCookieSameSite),
    "soup_cookie_get_same_site_policy")
  discard bindFunc(libSoup, cast[ptr pointer](addr soupCookieSetSecure),
    "soup_cookie_set_secure")
  discard bindFunc(libSoup, cast[ptr pointer](addr soupCookieSetHTTPOnly),
    "soup_cookie_set_http_only")
  discard bindFunc(libSoup, cast[ptr pointer](addr soupCookieSetSameSite),
    "soup_cookie_set_same_site_policy")
  discard bindFunc(libSoup, cast[ptr pointer](addr soupCookieSetExpires),
    "soup_cookie_set_expires")
  discard bindFunc(libGLib, cast[ptr pointer](addr cookieListFree),
    "g_list_free")
  # GLib 2.80 gdatetime.h and libsoup 2.74 soup-date.h: Soup3 uses
  # refcounted GDateTime, Soup2 copied SoupDate; time_t is 64-bit on our
  # supported Linux amd64/arm64 targets. Never share their pointer
  # types.
  if soup3:
    discard bindFunc(libGLib, cast[ptr pointer](addr cookieDateNew),
      "g_date_time_new_from_unix_utc")
    discard bindFunc(libGLib, cast[ptr pointer](addr cookieDateUnix),
      "g_date_time_to_unix")
    discard bindFunc(libGLib, cast[ptr pointer](addr cookieDateFree),
      "g_date_time_unref")
  else:
    discard bindFunc(libSoup, cast[ptr pointer](addr cookieDateNew),
      "soup_date_new_from_time_t")
    discard bindFunc(libSoup, cast[ptr pointer](addr cookieDateUnix),
      "soup_date_to_time_t")
    discard bindFunc(libSoup, cast[ptr pointer](addr cookieDateFree),
      "soup_date_free")

proc linuxCookieManager(operation, needs: string,
    available: bool): tuple[m: pointer, err: ref CatchableError] =
  let werr = webKit()
  if not werr.isNil:
    return (nil, newException(CatchableError,
      "mynim: cookies: " & operation & ": " & werr.msg))
  if not available or cookieManager.isNil or soupCookieNew.isNil or
      soupCookieFree.isNil:
    return (nil, newException(CatchableError,
      "mynim: cookies: " & operation & " needs " & needs & ": " &
      errUnsupported().msg))
  (cookieManager(webkitWebContextGetDefault()), nil)

proc freeCookies(cookies: seq[pointer]) =
  for c in cookies:
    soupCookieFree(c)

## allCookies lists the cookies of the default web context. done owns
## the SoupCookies and frees them.
proc allCookies(operation: string,
    done: proc(cookies: seq[pointer], err: ref CatchableError)) =
  let (manager, err) = linuxCookieManager(operation,
    "WebKitGTK 2.42 or newer",
    not cookieList.isNil and not cookieListFinish.isNil and
    not cookieListFree.isNil and not soupCookieName.isNil and
    not soupCookieValue.isNil and not soupCookieDomain.isNil and
    not soupCookiePath.isNil and not soupCookieExpires.isNil and
    not soupCookieSecure.isNil and not soupCookieHTTPOnly.isNil and
    not cookieDateUnix.isNil)
  if not err.isNil:
    done(@[], err)
    return
  let request = pending.add(proc(source, res: pointer) =
    var ge: pointer
    let list = cookieListFinish(source, res, addr ge)
    # WebKit transfers the GList (data, next, prev) and its cookies.
    var cookies: seq[pointer]
    var node = list
    while not node.isNil:
      cookies.add field[pointer](node, 0)
      node = field[pointer](node, 8)
    cookieListFree(list)
    let e = gErr(ge)
    if not e.isNil:
      freeCookies(cookies)
      done(@[], newException(CatchableError,
        "mynim: cookies: " & operation & ": " & e.msg))
      return
    done(cookies, nil))
  cookieList(manager, nil, cbAsyncReady, request)

method listCookies*(a: appController,
    done: proc(c: seq[Cookie], err: ref CatchableError)) =
  allCookies("List", proc(cookies: seq[pointer],
      err: ref CatchableError) =
    if not err.isNil:
      done(@[], err)
      return
    var values = newSeqOfCap[Cookie](cookies.len)
    for c in cookies:
      var o = Cookie(
        name: goStr(soupCookieName(c)),
        value: goStr(soupCookieValue(c)),
        domain: goStr(soupCookieDomain(c)),
        path: goStr(soupCookiePath(c)),
        secure: soupCookieSecure(c) != 0,
        httpOnly: soupCookieHTTPOnly(c) != 0)
      let d = soupCookieExpires(c)
      if not d.isNil:
        o.expires = fromUnix(cookieDateUnix(d))
      if not soupCookieSameSite.isNil:
        case soupCookieSameSite(c)
        of 0: o.sameSite = "none"
        of 1: o.sameSite = "lax"
        of 2: o.sameSite = "strict"
        else: discard
      values.add o
    freeCookies(cookies)
    done(values, nil))

proc cookieFinishError(operation: string, ok: int32,
    ge: pointer): ref CatchableError =
  let e = gErr(ge)
  if not e.isNil:
    return newException(CatchableError,
      "mynim: cookies: " & operation & ": " & e.msg)
  if ok == 0:
    return newException(CatchableError,
      "mynim: cookies: " & operation & " failed")
  nil

method setCookie*(a: appController, c: Cookie,
    done: proc(err: ref CatchableError)) =
  let (manager, err) = linuxCookieManager("Set",
    "WebKitGTK 2.20 and libsoup 2.70 or newer",
    not cookieAdd.isNil and not cookieAddFinish.isNil and
    not soupCookieSetSecure.isNil and not soupCookieSetHTTPOnly.isNil and
    not soupCookieSetSameSite.isNil and not soupCookieSetExpires.isNil and
    not cookieDateNew.isNil and not cookieDateFree.isNil)
  if not err.isNil:
    done(err)
    return
  let native = soupCookieNew(cs(c.name), cs(c.value), cs(c.domain),
    cs(c.path), -1)
  if native.isNil:
    done(newException(CatchableError,
      "mynim: cookies: Set could not construct SoupCookie"))
    return
  soupCookieSetSecure(native, int32(c.secure))
  soupCookieSetHTTPOnly(native, int32(c.httpOnly))
  var policy = 1'i32
  if c.sameSite == "none": policy = 0
  elif c.sameSite == "strict": policy = 2
  soupCookieSetSameSite(native, policy)
  if c.expires.toUnix != 0:
    let date = cookieDateNew(c.expires.toUnix)
    if date.isNil:
      soupCookieFree(native)
      done(newException(CatchableError,
        "mynim: cookies: Set cannot represent expiration"))
      return
    soupCookieSetExpires(native, date)
    cookieDateFree(date)
  let request = pending.add(proc(source, res: pointer) =
    var ge: pointer
    let ok = cookieAddFinish(source, res, addr ge)
    soupCookieFree(native)
    done(cookieFinishError("Set", ok, ge)))
  cookieAdd(manager, native, nil, cbAsyncReady, request)

method deleteCookie*(a: appController, key: CookieKey,
    done: proc(err: ref CatchableError)) =
  if cookieDelete.isNil or cookieDeleteFinish.isNil or
      soupCookieCopy.isNil:
    done(newException(CatchableError,
      "mynim: cookies: Delete needs WebKitGTK 2.42 or newer: " &
      errUnsupported().msg))
    return
  # libsoup deletes the cookie of the same name, path and value: find
  # the stored one, whose value the key lacks.
  allCookies("Delete", proc(cookies: seq[pointer],
      err: ref CatchableError) =
    if not err.isNil:
      done(err)
      return
    defer: freeCookies(cookies)
    var match: pointer
    for c in cookies:
      if goStr(soupCookieName(c)) == key.name and
          goStr(soupCookieDomain(c)).toLower == key.domain and
          goStr(soupCookiePath(c)) == key.path:
        if not match.isNil:
          done(newException(CatchableError,
            "mynim: cookies: ambiguous cookie key"))
          return
        match = c
    if match.isNil:
      done(nil)
      return
    let matched = soupCookieCopy(match)
    let request = pending.add(proc(source, res: pointer) =
      var ge: pointer
      let ok = cookieDeleteFinish(source, res, addr ge)
      soupCookieFree(matched)
      done(cookieFinishError("Delete", ok, ge)))
    cookieDelete(cookieManager(webkitWebContextGetDefault()), matched,
      nil, cbAsyncReady, request))
