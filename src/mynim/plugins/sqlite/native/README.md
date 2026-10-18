# Bundled SQLite

`sqlite3.c` and `sqlite3.h` are the SQLite 3.53.4 amalgamation downloaded from
the official archive:

<https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip>

The archive's SHA3-256 digest is:

```
628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e
```

The C source is compiled into the application by `db.nim`. Its build defines
match MyGo's SQLite build: thread safety enabled, double-quoted string
compatibility disabled, foreign keys enabled by default, FTS5 and R*Tree
enabled, and loadable extensions, deprecated APIs, and shared cache omitted.

SQLite places the source and documentation in the public domain:
<https://www.sqlite.org/copyright.html>
