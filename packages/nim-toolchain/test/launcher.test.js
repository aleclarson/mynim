import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { copyFile, link, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { delimiter, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { getToolchain } from '../index.js';

const release = JSON.parse(await readFile(new URL('../release.json', import.meta.url)));
const launcher = fileURLToPath(new URL('../bin/nim.js', import.meta.url));

async function cachedNode(t) {
  const temporary = await mkdtemp(join(tmpdir(), 'nim-launcher-test-'));
  t.after(() => rm(temporary, { recursive: true, force: true }));
  const platform = `${process.platform}-${process.arch}`;
  const asset = release.platforms[platform];
  if (!asset) throw new Error(`No launcher fixture for ${platform}`);
  const directory = join(temporary, `${release.version}-${platform}-${asset.sha256}`);
  const bin = join(directory, 'bin');
  for (const name of ['bin', 'lib', 'config']) await mkdir(join(directory, name), { recursive: true });
  const extension = process.platform === 'win32' ? '.exe' : '';
  if (process.platform !== 'win32') {
    await symlink(process.execPath, join(bin, 'nim'));
  } else {
    try {
      await link(process.execPath, join(bin, 'nim.exe'));
    } catch (error) {
      if (error.code !== 'EXDEV' && error.code !== 'EPERM') throw error;
      await copyFile(process.execPath, join(bin, 'nim.exe'));
    }
  }
  for (const name of ['nimble', 'nimsuggest']) await writeFile(join(bin, name + extension), 'fixture');
  await writeFile(join(directory, 'lib', 'system.nim'), '# fixture');
  await writeFile(join(directory, 'config', 'nim.cfg'), '# fixture');
  await writeFile(join(directory, '.nim-toolchain'), asset.sha256);
  return { temporary, bin, env: { ...process.env, NIM_TOOLCHAIN_CACHE: temporary } };
}

test('the launcher preserves arguments, working directory, PATH, and exit status', async t => {
  const fixture = await cachedNode(t);
  const workingDir = join(fixture.temporary, 'working directory with spaces');
  await mkdir(workingDir);
  const script = `
    const key = Object.keys(process.env).find(key => key.toUpperCase() === 'PATH');
    console.log(JSON.stringify({ args: process.argv.slice(1), cwd: process.cwd(), path: process.env[key] }));
    process.exitCode = 23;
  `;
  const result = spawnSync(process.execPath, [launcher, '-e', script, '--', 'argument with spaces', '--literal'], {
    cwd: workingDir,
    env: fixture.env,
    encoding: 'utf8',
  });
  assert.equal(result.status, 23, result.stderr);
  const output = JSON.parse(result.stdout);
  assert.deepEqual(output.args, ['argument with spaces', '--literal']);
  // macOS may resolve /var to /private/var when returning the working directory.
  assert.ok(output.cwd.endsWith('working directory with spaces'));
  assert.equal(output.path.split(delimiter)[0], fixture.bin);
});

test('cache paths that bundled Nimble cannot quote fail before a download', async () => {
  for (const name of ['cache with spaces', 'cache;echo', 'cache$variable', "cache'quote"]) {
    await assert.rejects(getToolchain({ cacheDir: join(tmpdir(), name) }), /Set NIM_TOOLCHAIN_CACHE/);
  }
});

test('SIGTERM is forwarded to a running compiler', { skip: process.platform === 'win32', timeout: 10_000 }, async t => {
  const fixture = await cachedNode(t);
  const child = spawn(process.execPath, [launcher, '-e', `
    process.on('SIGTERM', () => process.exit(42));
    console.log('ready');
    setInterval(() => {}, 1000);
  `], { env: fixture.env, stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(() => { if (child.exitCode === null) child.kill('SIGKILL'); });
  const exited = new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('exit', (code, signal) => resolve({ code, signal }));
  });
  await new Promise((resolve, reject) => {
    child.stdout.once('data', resolve);
    child.once('error', reject);
    child.once('exit', code => reject(new Error(`Compiler exited before ready: ${code}`)));
  });
  child.kill('SIGTERM');
  assert.deepEqual(await exited, { code: 42, signal: null });
});
