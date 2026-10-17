## dev.go — development vs. production.

proc isDev*(): bool =
  ## Whether the app runs in development: true unless it was built for
  ## production with `nim-xplat build`, or MYNIM_ENV=production is set.
  ## Development builds enable the web inspector by default.
  if isProduction:
    return false
  getEnv("MYNIM_ENV", getEnv("MYGO_ENV")) != "production"

## devURL returns the dev server `nim-xplat dev` points the app at, or "".
proc devURL(): string =
  if not isDev():
    return ""
  getEnv("MYNIM_DEV_URL", getEnv("MYGO_DEV_URL"))

## launchedByDev reports whether `nim-xplat dev` launched the app.
proc launchedByDev(): bool = devLaunched
