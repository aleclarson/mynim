# @mygo-plugins/sqlite

The SQLite frontend for Mynim apps. It exposes parameterized `execute`,
`query`, and atomic `transaction` calls through the app's internal IPC service,
preserving 64-bit integers as JavaScript `bigint` and BLOBs as `Uint8Array`.

Register the Nim plugin before running the app:

```nim
import mynim
import mynim/plugins/sqlite

use(Plugin)
```

Then open a database from the page:

```ts
import { open } from "@mygo-plugins/sqlite";

const db = await open("app.db");
await db.execute("CREATE TABLE IF NOT EXISTS notes (title TEXT)");
await db.execute("INSERT INTO notes(title) VALUES (?)", ["Hello SQLite"]);
const { columns, rows } = await db.query("SELECT title FROM notes");
await db.close();
```

Files live in the app's user-data directory. Page connections close when the
page navigates away or the app quits. The Nim plugin can set a database
directory and lock timeout with `newSqlitePlugin(Options(...))`.

Mynim currently loads the operating system's SQLite shared library at runtime.
The upstream plugin ships prebuilt SQLite libraries, so bundling and packaging
those libraries remains a parity gap, especially on Windows and Linux systems
without SQLite installed.
