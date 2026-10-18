# @mygo-plugins/watch

Page code can watch files that the app explicitly grants under a name. Add the
plugin to the app and configure its roots:

```nim
import mynim/plugins/watch
import mynim as core
import std/tables

core.use(newWatchPlugin(Options(roots: {
  "project": Root(path: projectDir, recursive: true),
}.toTable)))
```

Then iterate batches in the page:

```ts
import { watch } from "@mygo-plugins/watch";

const watcher = await watch("project", { recursive: true });
for await (const events of watcher) {
  for (const event of events) console.log(event.op, event.path);
}
```

Events report `create`, `write`, `remove`, and `rename` changes after the
debounce interval. Paths are relative to the watched directory or file, with
`oldPath` on rename events. Close the watcher, break from its loop, abort its
signal, or navigate away to stop it.
