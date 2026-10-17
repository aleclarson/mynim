import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { delimiter, join, resolve } from 'node:path';
import { installRelease } from './lib/install.js';

const release = JSON.parse(readFileSync(new URL('./release.json', import.meta.url)));

/** The exact upstream Nim version installed by this package. */
export const nimVersion = release.version;

function defaultCacheDir() {
  if (process.env.NIM_TOOLCHAIN_CACHE) return process.env.NIM_TOOLCHAIN_CACHE;
  if (process.platform === 'darwin') return join(homedir(), 'Library', 'Caches', 'nim-toolchain');
  if (process.platform === 'win32') {
    return join(process.env.LOCALAPPDATA || join(homedir(), 'AppData', 'Local'), 'nim-toolchain', 'Cache');
  }
  return join(process.env.XDG_CACHE_HOME || join(homedir(), '.cache'), 'nim-toolchain');
}

/**
 * Download and verify the pinned Nim distribution if it is not cached.
 * Returns absolute tool paths and an environment that uses this compiler for
 * child processes, including compilers launched by Nimble.
 *
 * @param {{ cacheDir?: string }} [options] User-owned cache directory.
 * @throws For unsupported platforms or cache paths, failed downloads, or checksum mismatches.
 */
export async function getToolchain({ cacheDir = defaultCacheDir() } = {}) {
  const platform = `${process.platform}-${process.arch}`;
  const asset = release.platforms[platform];
  if (!asset) throw new Error(`Nim ${nimVersion} is not packaged for ${platform}.`);
  if (process.platform === 'linux' && !process.report.getReport().header.glibcVersionRuntime) {
    throw new Error('nim-toolchain requires glibc on Linux; use a system Nim installation on musl/Alpine.');
  }
  cacheDir = resolve(cacheDir);
  // Bundled Nimble 0.24.1 interpolates the compiler path into a shell command.
  // Reject paths it cannot quote safely rather than letting compilation fail later.
  if (/[\s'"`$;&|<>()*?\[\]{}!]/u.test(cacheDir) || (process.platform !== 'win32' && cacheDir.includes('\\'))) {
    throw new Error('The bundled Nimble requires a cache path without spaces or shell metacharacters. Set NIM_TOOLCHAIN_CACHE to such a directory.');
  }

  const directory = await installRelease({
    cacheDir,
    version: nimVersion,
    platform,
    url: `https://github.com/nim-lang/nightlies/releases/download/${release.tag}/${asset.file}`,
    sha256: asset.sha256,
  });
  const binDirectory = join(directory, 'bin');
  const extension = process.platform === 'win32' ? '.exe' : '';
  const env = { ...process.env };
  const pathKey = Object.keys(env).find(key => key.toUpperCase() === 'PATH') || 'PATH';
  env[pathKey] = binDirectory + delimiter + (env[pathKey] || '');

  return {
    version: nimVersion,
    directory,
    binDirectory,
    nim: join(binDirectory, 'nim' + extension),
    nimble: join(binDirectory, 'nimble' + extension),
    nimsuggest: join(binDirectory, 'nimsuggest' + extension),
    env,
  };
}
