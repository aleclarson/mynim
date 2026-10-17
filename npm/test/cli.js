import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { getToolchain } from 'nim-toolchain';

const root = fileURLToPath(new URL('../..', import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), 'nim-xplat-cli-tests-'));
try {
  const toolchain = await getToolchain();
  const tests = (await readdir(join(root, 'tests'))).filter(name => /^tcli_.*\.nim$/.test(name));
  tests.push('tlisteners.nim');
  for (const name of tests.sort()) {
    const result = spawnSync(toolchain.nim, [
      'c', '-r', '--hints:off', '--out:' + join(temporary, name.replace('.nim', '')),
      join(root, 'tests', name),
    ], { cwd: root, env: toolchain.env, encoding: 'utf8', timeout: 240_000 });
    if (result.error) throw result.error;
    assert.equal(result.status, 0, `${name}\n${result.stdout}\n${result.stderr}`);
    console.log(`PASS: ${name}`);
  }
} finally {
  await rm(temporary, { recursive: true, force: true });
}
