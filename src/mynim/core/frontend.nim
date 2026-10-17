## frontend.go — the app's frontend: the web UI it ships, served on the
## mygo scheme.
##
## Windows load it with URLs without a scheme, such as "/" or
## "/settings" (see WindowOptions.url), which resolve against:
##
##   - the dev server at devUrl (mygo.config.ts) while `nim-xplat dev`
##     runs the app;
##   - otherwise mygo://localhost/, which serves the frontendDist
##     files `nim-xplat build` embeds into the app (see setFrontend).
##
## The mygo scheme serves the frontend unless the app handles it
## itself with protocol.handle.
##
## The wire names — the "mygo" scheme, MYGO_* environment variables —
## keep Go's spelling: the bridge runtime and the CLI conventions are
## the same protocol.

const frontendScheme = "mygo"

var frontend: tuple[mu: Lock, fsys: Fs]
initLock(frontend.mu)

proc setFrontend*(fsys: Fs) =
  ## Serves fsys as the app's frontend at mygo://localhost/. Paths
  ## without a file extension that match no file serve index.html, for
  ## client-side routing.
  ##
  ## `nim-xplat build` calls it with the frontendDist files it embeds into
  ## the app, so apps rarely need to. Call it to ship a frontend
  ## without the mynim CLI, e.g. from vfs.mapFs.
  acquire(frontend.mu)
  frontend.fsys = fsys
  release(frontend.mu)

proc frontendFs(): Fs =
  acquire(frontend.mu)
  result = frontend.fsys
  release(frontend.mu)

## resolveURL resolves a URL without a scheme against the frontend.
proc resolveURL(raw: string): tuple[url: string, err: ref CatchableError] =
  let parsed = try: parseUri(raw)
    except CatchableError as e: return ("", e)
  if parsed.scheme != "":
    return (raw, nil)
  var base = frontendScheme & "://localhost/"
  let d = devURL()
  if d != "":
    base = d
  let b = try: parseUri(base)
    except CatchableError as e: return ("", e)
  ($combine(b, parsed), nil)

## isDevOrigin reports whether origin ("scheme://host") is the dev
## server's.
proc isDevOrigin(origin: string): bool =
  let d = devURL()
  if d == "":
    return false
  let u = try: parseUri(d)
    except CatchableError: return false
  cmpIgnoreCase(u.scheme & "://" & u.hostname &
    (if u.port != "": ":" & u.port else: ""), origin) == 0
