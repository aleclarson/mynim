import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { installRelease } from '../lib/install.js';

async function fixture(t, { incomplete = false, status = 200 } = {}) {
  const temporary = await mkdtemp(join(tmpdir(), 'nim toolchain test '));
  t.after(() => rm(temporary, { recursive: true, force: true }));
  const root = join(temporary, 'nim-fixture');
  for (const dir of ['bin', 'lib', 'config']) await mkdir(join(root, dir), { recursive: true });
  for (const name of ['nim', 'nimble', 'nimsuggest']) {
    await writeFile(join(root, 'bin', name), 'fixture tool', { mode: 0o755 });
  }
  if (!incomplete) await writeFile(join(root, 'lib', 'system.nim'), '# standard library');
  await writeFile(join(root, 'config', 'nim.cfg'), '# compiler configuration');
  const archive = join(temporary, 'fixture.tar.gz');
  const packed = spawnSync('tar', ['-czf', archive, '-C', temporary, 'nim-fixture'], { encoding: 'utf8' });
  assert.equal(packed.status, 0, packed.stderr);
  const bytes = await readFile(archive);
  let requests = 0;
  const server = createServer((request, response) => {
    requests++;
    response.writeHead(status, { 'content-length': bytes.length });
    response.end(bytes);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => {
    server.close(resolve);
    server.closeAllConnections();
  }));
  const options = {
    cacheDir: join(temporary, 'cache with spaces'),
    version: '2.2.12',
    platform: 'darwin-arm64',
    url: `http://127.0.0.1:${server.address().port}/fixture.tar.gz`,
    sha256: createHash('sha256').update(bytes).digest('hex'),
  };
  return { options, requests: () => requests };
}

test('a complete distribution is cached and reused without a second request', async t => {
  const { options, requests } = await fixture(t);
  const directory = await installRelease(options);
  assert.equal(await readFile(join(directory, 'lib', 'system.nim'), 'utf8'), '# standard library');
  assert.equal(await installRelease(options), directory);
  assert.equal(requests(), 1);
  assert.deepEqual(await readdir(options.cacheDir), [directory.split(/[\\/]/).at(-1)]);
});

test('a checksum mismatch leaves no installed files or temporary download', async t => {
  const { options } = await fixture(t);
  await assert.rejects(installRelease({ ...options, sha256: '0'.repeat(64) }), /checksum mismatch/);
  assert.deepEqual(await readdir(options.cacheDir), []);
});

test('a failed download leaves the cache available for a later retry', async t => {
  const { options } = await fixture(t, { status: 503 });
  await assert.rejects(installRelease(options), /HTTP 503/);
  assert.deepEqual(await readdir(options.cacheDir), []);
});

test('an archive without a standard library is rejected', async t => {
  const { options } = await fixture(t, { incomplete: true });
  await assert.rejects(installRelease(options), /missing compiler, tools, standard library, or configuration/);
  assert.deepEqual(await readdir(options.cacheDir), []);
});

test('concurrent installations publish one complete distribution', async t => {
  const { options } = await fixture(t);
  const directories = await Promise.all(Array.from({ length: 4 }, () => installRelease(options)));
  assert.ok(directories.every(directory => directory === directories[0]));
  assert.equal((await readdir(options.cacheDir)).length, 1);
  assert.equal(await readFile(join(directories[0], 'config', 'nim.cfg'), 'utf8'), '# compiler configuration');
});
