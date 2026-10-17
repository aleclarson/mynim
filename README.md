# MyNim

Build desktop applications in Nim with a native UI or a web frontend. The
`mynim` command creates projects, runs development builds with live reload,
generates typed TypeScript clients, and packages apps for the current machine.

MyNim is a Nim port of [MyGo](https://github.com/egoist/mygo). This is an early
release; building for another operating system and code signing are not yet
supported by the CLI.

## Create an application

The npm package is `@aleclarson/mynim`; its command is `mynim`.

The npm release targets macOS and Linux on arm64 and x64. It requires Node.js
22 or later and a native C compiler with the platform SDK:

- macOS: Xcode Command Line Tools.
- Linux: GCC or Clang. Desktop apps also need GTK 3, WebKitGTK 4.1, Pango,
  FreeType, and Fontconfig runtime libraries.

The Windows desktop backend is not enabled in the public library yet, so
Windows is excluded from this npm release.

The [nim-toolchain](./packages/nim-toolchain/README.md) npm dependency supplies
Nim 2.2.12, its standard library, and Nimble. Its first use downloads and
verifies the official distribution. The C compiler and SDK are installed
separately. Both caches live under the toolchain's user cache directory; the
bundled Nimble requires a cache path without spaces or shell metacharacters.
Set `NIM_TOOLCHAIN_CACHE` if your default cache path contains them.

```sh
npx @aleclarson/mynim init counter
cd counter
npm install
npm test
npm run dev
```

The native starter is a counter with a name field. `npm test` runs its test
without opening a desktop window. `npm run dev` starts the app and rebuilds
it when source files or resources change.

For a web frontend:

```sh
npx @aleclarson/mynim init --template web web-app
cd web-app
npm install
npm test
npm run dev
```

The web starter uses Vite and TypeScript. Its typed client is generated from
the Nim service before development and production builds.

The CLI compiles itself on first use and caches the executable by source
content, platform, and Nim version. npm install scripts are not required:
`npm install --ignore-scripts` is supported. Generated projects pin their
`mynim` dependency and compile against its bundled framework sources, so a
separate Nimble registration or global Nim installation is unnecessary.

## Build and check

Inside either starter:

```sh
npm run vet
npm run build
```

Build output goes to `build/<os>-<arch>/`, including an `.app` bundle on macOS.
The existing `mygo.json` project configuration and `mygo-runtime` web package
are supported. The CLI command is `mynim`.

Other commands include `mynim generate`, `mynim i18n check`,
`mynim install-skills`, and `mynim doctor`. Run `mynim help` or a command's
`--help` for arguments. Under npm, use `npx mynim` to invoke the local command.

## Develop this repository

```sh
npm ci --ignore-scripts
node npm/bin/mynim.js --version
npm test
npm pack --dry-run
```

`npm test` uses the published `nim-toolchain` package. It runs the CLI tests,
then installs a packed candidate into a temporary npm project and checks
native and web starter flows without a global Nim installation. Starter
projects are relocated before checking them to verify that source paths stay
portable. The smoke test also checks that a failing app test returns a failed
npm command.

To use a local checkout as a standalone Nim dependency:

```sh
nimble compilecli
./cmd/mynim init --mynim . example
```

The starter's `config.nims` then points to this checkout. npm-created projects
instead find the SDK in `node_modules/@aleclarson/mynim`.

## License

[MIT](./LICENSE). Vendored audio licenses are in
`src/mynim/audio/mp3/LICENSE` and `src/mynim/audio/vorbis/LICENSE`; Unicode data
notices are in `licenses/Unicode-3.0.txt`.
