import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { access, mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

async function isInstalled(directory, sha256, platform) {
  try {
    if (await readFile(join(directory, '.nim-toolchain'), 'utf8') !== sha256) return false;
    const extension = platform.startsWith('win32-') ? '.exe' : '';
    for (const tool of ['nim', 'nimble', 'nimsuggest']) {
      await access(join(directory, 'bin', tool + extension));
    }
    await access(join(directory, 'lib', 'system.nim'));
    await access(join(directory, 'config', 'nim.cfg'));
    return true;
  } catch (error) {
    if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return false;
    throw error;
  }
}

async function extract(archive, directory) {
  await new Promise((resolve, reject) => {
    const child = spawn('tar', ['-xf', archive, '-C', directory], { stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', error => reject(new Error(`Cannot extract Nim: tar is required (${error.message}).`)));
    child.on('close', code => {
      if (code === 0) resolve();
      else reject(new Error(`Cannot extract Nim: ${stderr.trim() || `tar exited with ${code}`}`));
    });
  });
}

export async function installRelease({ cacheDir, version, platform, url, sha256 }) {
  // Each process extracts privately; only a complete installation becomes visible.
  // The digest separates different builds of the same upstream version.
  const directory = join(cacheDir, `${version}-${platform}-${sha256}`);
  if (await isInstalled(directory, sha256, platform)) return directory;
  await mkdir(cacheDir, { recursive: true });
  const temporary = await mkdtemp(join(cacheDir, '.download-'));
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(120_000) });
    if (!response.ok) throw new Error(`Cannot download Nim ${version}: HTTP ${response.status}.`);
    const archive = join(temporary, url.endsWith('.zip') ? 'nim.zip' : 'nim.tar.xz');
    await pipeline(Readable.fromWeb(response.body), createWriteStream(archive, { flags: 'wx' }));
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(archive)) hash.update(chunk);
    const actual = hash.digest('hex');
    if (actual !== sha256) {
      throw new Error(`Nim ${version} checksum mismatch: expected ${sha256}, received ${actual}.`);
    }

    const extracted = join(temporary, 'extracted');
    await mkdir(extracted);
    await extract(archive, extracted);
    const roots = await readdir(extracted, { withFileTypes: true });
    if (roots.length !== 1 || !roots[0].isDirectory()) {
      throw new Error(`Nim ${version} archive must contain a single toolchain directory.`);
    }
    const source = join(extracted, roots[0].name);
    await writeFile(join(source, '.nim-toolchain'), sha256);
    if (!await isInstalled(source, sha256, platform)) {
      throw new Error(`Nim ${version} archive is missing compiler, tools, standard library, or configuration.`);
    }
    try {
      await rename(source, directory);
    } catch (error) {
      // Another process may have installed the same verified release first.
      if (!await isInstalled(directory, sha256, platform)) throw error;
    }
    return directory;
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}
