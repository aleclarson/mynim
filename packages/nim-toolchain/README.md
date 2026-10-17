# nim-toolchain

Use a pinned native Nim compiler in an npm project. This package provides
Nim **2.2.12**, its standard library, Nimble, and nimsuggest, using the
[official Nim downloads](https://nim-lang.org/install.html).

This is an independent npm wrapper maintained with MyNim, not an official
Nim project package. The npm package version and Nim version are separate.

## Install and compile

Requires Node.js 22 or later and `tar` with support for the platform's archive
format (`.tar.xz` on Unix, `.zip` on Windows). Linux also needs `xz` when
required by its `tar`. macOS and Windows 10/11 include a suitable `tar`.

Native compilation also requires a C compiler and the platform SDK: Xcode
Command Line Tools on macOS, GCC or Clang on Linux, and MinGW or configured
Visual C++ Build Tools on Windows. This package does not install those tools
or run Nim's interactive `finish.exe` installer.

```sh
npm install --save-dev --save-exact nim-toolchain
npx nim --version
npx nimble --version
```

The first command that uses the toolchain downloads the pinned distribution
from `nim-lang/nightlies` on GitHub and verifies its SHA-256 checksum before
extraction. Subsequent commands use the cached distribution. No npm install
scripts are required; `npm install --ignore-scripts` works too.

Create `hello.nim`:

```nim
echo "Hello from Nim"
```

Compile and run it:

```sh
npx nim c -r hello.nim
```

The executable prints `Hello from Nim`. `npx nim` uses this package after it
has been installed; the unrelated npm package named `nim` is not required.
For a one-off command without installing a project dependency, use the
package's own name:

```sh
npx nim-toolchain --version
```

All compiler arguments pass through unchanged. npm scripts can invoke `nim`,
`nimble`, and `nimsuggest` directly.

## Platforms and cache

| OS | Architectures |
| --- | --- |
| macOS | arm64, x64 |
| Linux with glibc | arm64, x64 |
| Windows | x64 |

Other platforms, including musl/Alpine Linux and native Windows arm64, fail
with an unsupported-platform message. System Nim installations are left
unchanged. Nimble starts with this distribution first on `PATH`; its own
project dependency resolution still applies.

Downloads require network access on first use. Cache locations are:

- macOS: `~/Library/Caches/nim-toolchain`
- Linux: `$XDG_CACHE_HOME/nim-toolchain`, or `~/.cache/nim-toolchain`
- Windows: `%LOCALAPPDATA%\nim-toolchain\Cache`

Set `NIM_TOOLCHAIN_CACHE` to use a different cache directory, including a
directory restored by CI. **The cache path must not contain spaces or shell
metacharacters:** the bundled Nimble 0.24.1 does not quote the compiler path
when checking its version. If your home directory contains spaces, select a
writable cache path without them. Project paths and compiler arguments may
contain spaces.

Each distribution has its own directory identified by version, platform, and
checksum. Concurrent commands install into separate
temporary directories and share the completed result. Incomplete downloads
are discarded. A completed cache works without network access.

## Use from another CLI

```js
import { spawnSync } from 'node:child_process';
import { getToolchain, nimVersion } from 'nim-toolchain';

const toolchain = await getToolchain();
console.log(`Using Nim ${nimVersion}`);
const result = spawnSync(toolchain.nim, ['c', 'hello.nim'], {
  stdio: 'inherit',
  env: toolchain.env,
});
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
```

`getToolchain({ cacheDir })` can select an explicit cache directory. It returns
absolute paths for `nim`, `nimble`, and `nimsuggest`, the distribution directory,
its `binDirectory`, its version, and an environment with that `binDirectory`
prepended to `PATH`. It rejects on download, verification, extraction, cache-path,
or platform errors. Public declarations are in [index.d.ts](./index.d.ts).

## Develop and release

From this directory:

```sh
npm test
npm run test:smoke
npm pack --dry-run
```

Unit tests use local archives and HTTP fixtures. The smoke test downloads the
real pinned toolchain, installs a packed copy in a temporary npm project with
install scripts disabled, and compiles a Nim program through both Nim and
Nimble. It requires the native build prerequisites above.

To update Nim, choose a stable release linked from the official download page
and update `release.json` with its exact release tag, filenames, and SHA-256
digests. Verify every supported platform in CI and bump this npm package's
version before publishing from this directory with `npm publish --access public`.

The wrapper is MIT licensed. Downloaded distributions retain upstream files
and license notices; see Nim's `copying.txt` in the distribution.
