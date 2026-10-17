import { createHash } from 'node:crypto';
import { access, mkdir, mkdtemp, readFile, readdir, rename, rm } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { getToolchain } from 'nim-toolchain';
import { runProcess } from './process.js';

const packageRoot = fileURLToPath(new URL('../..', import.meta.url));

async function sourceHash() {
  const hash = createHash('sha256');
  async function visit(relative) {
    const entries = await readdir(join(packageRoot, relative), { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name, 'en'));
    for (const entry of entries) {
      const path = join(relative, entry.name);
      if (entry.isDirectory()) await visit(path);
      else if (entry.isFile()) hash.update(path).update('\0').update(await readFile(join(packageRoot, path)));
    }
  }
  await visit('src');
  await visit('npm/lib');
  hash.update(await readFile(join(packageRoot, 'nim.cfg')));
  hash.update(await readFile(join(packageRoot, 'package.json')));
  return hash.digest('hex');
}

async function fileExists(path) {
  try {
    await access(path);
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}

async function cliExecutable(toolchain) {
  const hash = await sourceHash();
  const cache = join(dirname(toolchain.directory), 'mynim');
  const directory = join(cache, `${toolchain.version}-${process.platform}-${process.arch}-${hash}`);
  const name = process.platform === 'win32' ? 'mynim.exe' : 'mynim';
  const executable = join(directory, name);
  if (await fileExists(executable)) return executable;
  await mkdir(cache, { recursive: true });
  const temporary = await mkdtemp(join(cache, '.build-'));
  try {
    console.error('Preparing the mynim CLI...');
    const code = await runProcess(toolchain.nim, [
      'c', '-d:release', '--checks:on', '--threads:on', '-d:ssl', '--hints:off',
      '--skipUserCfg:on', '--skipParentCfg:on',
      '--path:' + join(packageRoot, 'src'),
      '--nimcache:' + join(temporary, 'nimcache'),
      '--out:' + join(temporary, name),
      join(packageRoot, 'src', 'cmd', 'mynim.nim'),
    ], { cwd: packageRoot, env: toolchain.env });
    if (code !== 0) throw new Error('Could not compile the CLI. Check that a C compiler and platform SDK are installed.');
    await rm(join(temporary, 'nimcache'), { recursive: true, force: true });
    try {
      await rename(temporary, directory);
    } catch (error) {
      if (!await fileExists(executable)) throw error;
    }
    return executable;
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

export async function runCli(args) {
  try {
    const toolchain = await getToolchain();
    const executable = await cliExecutable(toolchain);
    process.exitCode = await runProcess(executable, args, {
      env: { ...toolchain.env, MYNIM_PACKAGE_ROOT: packageRoot },
    });
  } catch (error) {
    console.error(`mynim: ${error.message}`);
    process.exitCode = 1;
  }
}
