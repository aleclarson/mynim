import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const packageDir = fileURLToPath(new URL('..', import.meta.url));
const npm = process.env.npm_execpath;
assert.ok(npm, 'Run this test with npm run test:smoke.');
const temporary = await mkdtemp(join(tmpdir(), 'nim-npm-smoke-'));
const env = {
  ...process.env,
  NIM_TOOLCHAIN_CACHE: join(temporary, 'toolchain-cache'),
  NIMBLE_DIR: join(temporary, 'nimble'),
};
const consumer = join(temporary, 'consumer with spaces');

function run(command, args, cwd = consumer) {
  const result = spawnSync(command, args, { cwd, env, encoding: 'utf8', timeout: 240_000 });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${command} ${args.join(' ')}\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

function runNpm(args, cwd) {
  return run(process.execPath, [npm, ...args], cwd);
}

try {
  await mkdir(consumer);
  const [packed] = JSON.parse(runNpm(['pack', '--json', '--pack-destination', temporary], packageDir));
  await writeFile(join(consumer, 'package.json'), JSON.stringify({
    name: 'nim-toolchain-smoke',
    private: true,
    type: 'module',
    scripts: {
      build: 'nim c --hints:off --out:hello hello.nim',
      'build:nimble': 'nimble c --hints:off --out:hello-nimble hello.nim',
    },
  }));
  runNpm(['install', '--offline', '--ignore-scripts', '--no-audit', '--no-fund', join(temporary, packed.filename)]);
  assert.equal(existsSync(env.NIM_TOOLCHAIN_CACHE), false, 'npm install must not fetch a compiler');

  const { getToolchain, nimVersion } = await import(pathToFileURL(join(consumer, 'node_modules', 'nim-toolchain', 'index.js')));
  const { version } = JSON.parse(await readFile(join(packageDir, 'release.json')));
  assert.equal(nimVersion, version);
  console.log(`Downloading and verifying Nim ${version} for ${process.platform}-${process.arch}...`);
  const toolchain = await getToolchain({ cacheDir: env.NIM_TOOLCHAIN_CACHE });
  assert.ok(toolchain.nim.startsWith(env.NIM_TOOLCHAIN_CACHE));
  assert.equal(toolchain.version, version);
  env.NIM_TOOLCHAIN_EXPECTED_LIB = join(toolchain.directory, 'lib');
  assert.match(runNpm(['exec', '--offline', '--', 'nim-toolchain', '--version']), new RegExp(`Nim Compiler Version ${version.replaceAll('.', '\\.')}`));
  assert.match(runNpm(['exec', '--offline', '--', 'nimble', '--version']), /nimble/i);
  assert.match(runNpm(['exec', '--offline', '--', 'nimsuggest', '--version']), /Nim|nimsuggest/i);

  await writeFile(join(consumer, 'hello.nim'), `import std/[compilesettings, os, strutils]\nconst library = querySetting(SingleValueSetting.libPath)\ndoAssert sameFile(library / "system.nim", getEnv("NIM_TOOLCHAIN_EXPECTED_LIB") / "system.nim")\necho "toolchain smoke".toUpperAscii()\ndoAssert getCurrentDir().len > 0\n`);
  await writeFile(join(consumer, 'smoke.nimble'), `version = "0.1.0"\nauthor = "smoke"\ndescription = "Toolchain smoke test"\nlicense = "MIT"\nsrcDir = "."\nrequires "nim >= 2.2.0"\n`);
  const extension = process.platform === 'win32' ? '.exe' : '';
  runNpm(['run', 'build']);
  assert.equal(run(join(consumer, 'hello' + extension), []).trim(), 'TOOLCHAIN SMOKE');
  runNpm(['run', 'build:nimble']);
  assert.equal(run(join(consumer, 'hello-nimble' + extension), []).trim(), 'TOOLCHAIN SMOKE');
  console.log('PASS: packed npm install, local commands, standard library, native compilation, and Nimble compilation.');
} finally {
  await rm(temporary, { recursive: true, force: true });
}
