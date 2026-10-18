import { afterEach, expect, mock, test } from "bun:test";

class TestChannel implements AsyncIterable<unknown> {
  constructor() { channels.push(this); }
  closed = false;
  #values: unknown[] = [];
  #waiters: ((value: IteratorResult<unknown>) => void)[] = [];
  #closeHandlers: (() => void)[] = [];

  emit(value: unknown): void {
    if (this.closed) return;
    const waiter = this.#waiters.shift();
    if (waiter) waiter({ done: false, value });
    else this.#values.push(value);
  }

  onClose(handler: () => void): void {
    if (this.closed) handler();
    else this.#closeHandlers.push(handler);
  }

  finish(): void {
    if (this.closed) return;
    this.closed = true;
    for (const waiter of this.#waiters.splice(0)) waiter({ done: true, value: undefined });
  }

  close(): void {
    if (this.closed) return;
    this.finish();
    for (const handler of this.#closeHandlers.splice(0)) handler();
  }

  [Symbol.asyncIterator](): AsyncIterator<unknown> {
    return {
      next: () => {
        const value = this.#values.shift();
        if (value !== undefined) return Promise.resolve({ done: false, value });
        if (this.closed) return Promise.resolve({ done: true, value: undefined });
        return new Promise((resolve) => this.#waiters.push(resolve));
      },
    };
  }
}

let channels: TestChannel[] = [];
let calls: { name: string; params: unknown[] }[] = [];
let serve: ((channel: TestChannel, args: unknown[]) => Promise<unknown>) | undefined;
mock.module("mygo-runtime", () => ({
  Channel: TestChannel,
  call: (name: string, ...params: unknown[]) => {
    calls.push({ name, params });
    const channel = params[params.length - 1] as TestChannel;
    if (!serve) throw new Error("missing fake watch service");
    return Promise.resolve().then(() => serve!(channel, params.slice(0, -1)))
      .then((outcome) => {
        channel.finish();
        return outcome;
      });
  },
}));

const { watch, WatchError } = await import("../src/index.ts");

afterEach(() => {
  channels = [];
  calls = [];
  serve = undefined;
});

test("streams event batches and close waits for the service", async () => {
  let stopped = false;
  serve = (channel, args) => {
    expect(args[0]).toEqual({ root: "project", path: ".", recursive: false, debounceMs: 0 });
    channel.emit({ type: "ready" });
    channel.emit({ type: "events", events: [{ op: "create", path: "a", isDir: false }] });
    channel.emit({ type: "events", events: [{ op: "remove", path: "a", isDir: false }] });
    return new Promise((resolve) => channel.onClose(() => {
      stopped = true;
      resolve(null);
    }));
  };
  const watcher = await watch("project");
  const iterator = watcher[Symbol.asyncIterator]();
  expect((await iterator.next()).value).toEqual([{ op: "create", path: "a", isDir: false }]);
  expect((await iterator.next()).value).toEqual([{ op: "remove", path: "a", isDir: false }]);
  await watcher.close();
  expect(stopped).toBe(true);
  expect(calls[0].name).toBe("plugin:watch.Watch");
});

test("reports service failures as WatchError and preserves final batches", async () => {
  serve = (channel, args) => {
    if ((args[0] as { root: string }).root === "missing") {
      channel.close();
      return Promise.resolve({ code: "not-found", message: "filesystem watch not found" });
    }
    channel.emit({ type: "ready" });
    channel.emit({ type: "events", events: [{ op: "remove", path: ".", isDir: false }] });
    return Promise.resolve({
      code: "limit",
      message: "filesystem watch limit",
    });
  };
  await expect(watch("missing")).rejects.toMatchObject({ code: "not-found" });
  const watcher = await watch("project", { path: "config.json", debounceMs: -1 });
  const batches: unknown[] = [];
  const iteration = (async () => {
    for await (const batch of watcher) batches.push(batch);
  })();
  await expect(iteration).rejects.toBeInstanceOf(WatchError);
  expect(batches).toEqual([[{ op: "remove", path: ".", isDir: false }]]);
  expect(calls[1].params[0]).toEqual({
    root: "project", path: "config.json", recursive: false, debounceMs: -1,
  });
});

test("validates debounce and handles abort before opening", async () => {
  serve = () => Promise.resolve(null);
  await expect(watch("project", { debounceMs: NaN })).rejects.toBeInstanceOf(TypeError);
  await expect(watch("project", { debounceMs: 60001 })).rejects.toBeInstanceOf(TypeError);
  await expect(watch("project", { signal: AbortSignal.abort("stop") })).rejects.toBe("stop");
  expect(calls).toHaveLength(0);
});
