## Shared cache paths for verified native assets used by apps and the CLI.

import std/os

proc nativeAssetCacheRoot*(): string =
  let override = getEnv("MYNIM_NATIVE_CACHE_DIR")
  if override.len > 0:
    return absolutePath(override)
  getCacheDir() / "mygo" / "natives"

proc nativeAssetCachePath*(cacheRoot, sha256, name: string): string =
  cacheRoot / sha256 / name
