import { afterEach, expect, mock, test } from "bun:test";

let calls: { name: string; params: unknown[] }[] = [];
let closeResolve: (() => void) | undefined;
let closePromise: Promise<void> | undefined;
let closeFailure: Error | undefined;

mock.module("mygo-runtime", () => ({
  call: (name: string, ...params: unknown[]) => {
    calls.push({ name, params });
    switch (name) {
      case "plugin:sqlite.Open": return Promise.resolve("db-1");
      case "plugin:sqlite.Execute":
        return Promise.resolve({ changes: 1, lastInsertId: "9007199254740993" });
      case "plugin:sqlite.Query":
        return Promise.resolve({
          columns: ["value", "value", "value", "value", "value", "value"],
          rows: [[
            { type: "null" },
            { type: "integer", integer: "12" },
            { type: "integer", integer: "9007199254740993" },
            { type: "real", special: "NaN" },
            { type: "text", text: "hello" },
            { type: "blob", blob: btoa("bytes") },
          ]],
        });
      case "plugin:sqlite.Transaction":
        return Promise.resolve([
          { changes: 1, lastInsertId: "4" },
          { changes: 0, lastInsertId: "4" },
        ]);
      case "plugin:sqlite.Close":
        if (closeFailure) return Promise.reject(closeFailure);
        if (!closePromise) {
          closePromise = new Promise<void>((resolve) => { closeResolve = resolve; });
        }
        return closePromise;
      default: return Promise.reject(new Error(`unexpected call ${name}`));
    }
  },
}));

const { open } = await import("../src/index.ts");

afterEach(() => {
  calls = [];
  closeResolve = undefined;
  closePromise = undefined;
  closeFailure = undefined;
});

test("opens with read-only options and preserves SQLite result types", async () => {
  const db = await open("app.db", { readOnly: true });
  const insert = await db.execute("INSERT INTO t(value) VALUES (?)", [true]);
  expect(insert).toEqual({ changes: 1, lastInsertId: 9007199254740993n });
  expect(calls[0]).toEqual({
    name: "plugin:sqlite.Open",
    params: ["app.db", { readOnly: true }],
  });
  expect(calls[1].params[2]).toEqual([
    { type: "integer", integer: "1" },
  ]);

  const rows = await db.query("SELECT value FROM t");
  expect(rows.columns).toEqual(["value", "value", "value", "value", "value", "value"]);
  expect(rows.rows[0].slice(0, 5)).toEqual([
    null, 12, 9007199254740993n, NaN, "hello",
  ]);
  expect(rows.rows[0][5]).toEqual(new TextEncoder().encode("bytes"));
});

test("encodes parameters and maps transaction results", async () => {
  const db = await open(":memory:");
  const blob = new Uint8Array([0, 127, 255]);
  const results = await db.transaction([
    { sql: "INSERT INTO t VALUES (?, ?, ?, ?, ?, ?)", params: [null, false, -5n, 1.25, "x", blob] },
    { sql: "DELETE FROM t" },
  ]);

  expect(calls[0].params).toEqual([":memory:", { readOnly: false }]);
  expect(calls[1]).toEqual({
    name: "plugin:sqlite.Transaction",
    params: ["db-1", [
      {
        sql: "INSERT INTO t VALUES (?, ?, ?, ?, ?, ?)",
        args: [
          { type: "null" },
          { type: "integer", integer: "0" },
          { type: "integer", integer: "-5" },
          { type: "real", real: 1.25 },
          { type: "text", text: "x" },
          { type: "blob", blob: btoa("\u0000\u007fÿ") },
        ],
      },
      { sql: "DELETE FROM t", args: [] },
    ]],
  });
  expect(results).toEqual([
    { changes: 1, lastInsertId: 4n },
    { changes: 0, lastInsertId: 4n },
  ]);
});

test("rejects values that cannot cross the SQLite wire format", async () => {
  const db = await open(":memory:");
  await expect(db.execute("SELECT ?", [Number.NaN])).rejects.toThrow("must be finite");
  await expect(db.execute("SELECT ?", [Number.MAX_SAFE_INTEGER + 1])).rejects.toThrow("use bigint");
  await expect(db.execute("SELECT ?", [1n << 63n])).rejects.toThrow("signed 64-bit");
  expect(calls.filter((call) => call.name === "plugin:sqlite.Execute")).toHaveLength(0);
});

test("concurrent closes share a call and block operations until closed", async () => {
  const db = await open(":memory:");
  const first = db.close();
  const second = db.close();
  expect(first).toBe(second);
  expect(calls.filter((call) => call.name === "plugin:sqlite.Close")).toHaveLength(1);
  await expect(db.query("SELECT 1")).rejects.toThrow("database is closed");
  closeResolve!();
  await first;
  await db.close();
  expect(calls.filter((call) => call.name === "plugin:sqlite.Close")).toHaveLength(1);
});

test("retries close after a failed native close", async () => {
  const db = await open(":memory:");
  closeFailure = new Error("busy");
  await expect(db.close()).rejects.toThrow("busy");
  closeFailure = undefined;
  closePromise = undefined;
  const retry = db.close();
  expect(calls.filter((call) => call.name === "plugin:sqlite.Close")).toHaveLength(2);
  closeResolve!();
  await retry;
});
