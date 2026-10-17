import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { delimiter, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../..', import.meta.url));
const npm = process.env.npm_execpath;
assert.ok(npm, 'Run this test with npm run test:smoke.');
const metadata = JSON.parse(await readFile(join(root, 'package.json')));
assert.deepEqual(metadata.bin, { 'nim-xplat': 'npm/bin/nim-xplat.js' });
const temporary = await mkdtemp(join(tmpdir(), 'nim-xplat-npm-smoke-'));
const env = {
  ...process.env,
  NIM_TOOLCHAIN_CACHE: join(temporary, 'toolchains'),
  NIMBLE_DIR: join(temporary, 'nimble'),
};

function run(args, cwd, expected = 0) {
  const result = spawnSync(process.execPath, [npm, ...args], { cwd, env, encoding: 'utf8', timeout: 300_000 });
  if (result.error) throw result.error;
  assert.equal(result.status, expected, `${args.join(' ')}\n${result.stdout}\n${result.stderr}`);
  return result;
}

try {
  const consumer = join(temporary, 'consumer with spaces');
  await mkdir(consumer);
  await writeFile(join(consumer, 'package.json'), JSON.stringify({ name: 'consumer', private: true }));
  const [packed] = JSON.parse(run(['pack', '--json', '--pack-destination', temporary], root).stdout);
  assert.ok(packed.files.some(file => file.path === 'src/mynim.nim'));
  assert.ok(packed.files.some(file => file.path === 'src/cmd/nim_xplat.nim'));
  assert.ok(!packed.files.some(file => file.path.startsWith('packages/') || file.path.startsWith('.agents/')));
  const archive = join(temporary, packed.filename);
  run(['install', '--ignore-scripts', '--no-audit', '--no-fund', archive], consumer);

  // Restrict Unix PATH to Node and the system build tools: no Homebrew Nim.
  if (process.platform !== 'win32') {
    env.PATH = [dirname(process.execPath), '/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(delimiter);
  }
  console.log('Building the CLI from a packed install with the published toolchain...');
  const version = run(['exec', '--offline', '--', 'nim-xplat', '--version'], consumer);
  assert.equal(version.stdout.trim(), `nim-xplat ${metadata.version}`);
  const cached = run(['exec', '--offline', '--', 'nim-xplat', '--version'], consumer);
  assert.ok(!cached.stderr.includes('Preparing the nim-xplat CLI'));

  for (const template of ['native', 'web']) {
    const project = join(consumer, `${template} app`);
    run(['exec', '--offline', '--', 'nim-xplat', 'init', '--template', template, project], consumer);
    const manifest = JSON.parse(await readFile(join(project, 'package.json')));
    assert.equal(manifest.devDependencies[metadata.name], metadata.version);
    assert.equal(manifest.scripts.build, 'nim-xplat build');
    assert.equal(manifest.scripts.test, 'nim-xplat test');
    const nimbleName = (await readdir(project)).find(name => name.endsWith('.nimble'));
    assert.ok(!(await readFile(join(project, nimbleName), 'utf8')).includes('requires "nim-xplat'));
    // Install the candidate tarball until its version is available on npm.
    manifest.devDependencies[metadata.name] = 'file:' + archive;
    await writeFile(join(project, 'package.json'), JSON.stringify(manifest));
    run(['install', '--ignore-scripts', '--no-audit', '--no-fund'], project);

    const moved = join(temporary, `${template} relocated`);
    await rename(project, moved);
    run(['test'], moved);
    run(['run', 'vet'], moved);
    run(['run', 'generate'], moved);
    if (template === 'web') run(['run', 'typecheck'], moved);
    run(['run', 'build'], moved);
    const output = join(moved, 'build');
    assert.ok((await readdir(output)).some(name => !name.startsWith('.')));
    // Exercise the dev launcher without opening a desktop window.
    const configPath = join(moved, 'mygo.json');
    const config = JSON.parse(await readFile(configPath));
    config.devUrl = '';
    config.devCommand = '';
    config.frontendDist = '';
    await writeFile(configPath, JSON.stringify(config));
    await writeFile(join(moved, 'src', 'main.nim'), `import std/os\nimport mynim\nif getEnv("NIM_XPLAT_GENERATE").len == 0:\n  echo "managed dev toolchain"\n`);
    const dev = run(['exec', '--offline', '--', 'nim-xplat', 'dev', '-skip-dev-command', moved], moved);
    assert.ok(dev.stdout.includes('managed dev toolchain'));
    await writeFile(join(moved, 'tests', 'test_app.nim'), 'quit(7)\n');
    const failed = spawnSync(process.execPath, [npm, 'test'], { cwd: moved, env, encoding: 'utf8', timeout: 120_000 });
    assert.ok(failed.status !== null && failed.status !== 0, 'npm test must propagate a failing test');
    console.log(`PASS: ${template} init, relocated project, test, vet, generate, build, dev, and failing-test status`);
  }
} finally {
  await rm(temporary, { recursive: true, force: true });
}
