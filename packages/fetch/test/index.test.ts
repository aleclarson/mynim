import { afterEach, expect, mock, test } from "bun:test";

interface Part {
  status?: number;
  statusText?: string;
  url?: string;
  redirected?: boolean;
  headers?: [string, string][];
  chunk?: string;
}

class FakeChannel<T> implements AsyncIterable<T> {
  private values: T[] = [];
  private waiters: ((value: IteratorResult<T>) => void)[] = [];
  private ended = false;

  push(value: T): void {
    const waiter = this.waiters.shift();
    if (waiter) waiter({ done: false, value });
    else this.values.push(value);
  }

  end(): void {
    this.ended = true;
    while (this.waiters.length > 0) {
      this.waiters.shift()!({ done: true, value: undefined });
    }
  }

  close(): void {
    this.end();
  }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    return this;
  }

  next(): Promise<IteratorResult<T>> {
    if (this.values.length > 0) {
      return Promise.resolve({ done: false, value: this.values.shift()! });
    }
    if (this.ended) return Promise.resolve({ done: true, value: undefined });
    return new Promise((resolve) => this.waiters.push(resolve));
  }
}

let requestArgs: unknown[] = [];
let nativeFetch = globalThis.fetch;

mock.module("mygo-runtime", () => ({
  Channel: FakeChannel,
  call: (_method: string, ...args: unknown[]) => {
    requestArgs = args;
    const channel = args.at(-1) as FakeChannel<Part>;
    channel.push({
      status: 201,
      statusText: "Created",
      url: "https://api.example.test/items",
      redirected: true,
      headers: [["x-fetch", "ok"]],
    });
    channel.push({ chunk: btoa("streamed ") });
    channel.push({ chunk: btoa("response") });
    channel.end();
    return Promise.resolve();
  },
  isCallError: () => false,
}));

const { fetch } = await import("../src/index.ts");

afterEach(() => {
  globalThis.fetch = nativeFetch;
  requestArgs = [];
});

test("turns the streamed IPC response into a standard Response", async () => {
  const response = await fetch("https://api.example.test/items", {
    method: "POST",
    headers: { authorization: "Bearer token" },
    body: "payload",
  });

  expect(response.status).toBe(201);
  expect(response.statusText).toBe("Created");
  expect(response.url).toBe("https://api.example.test/items");
  expect(response.redirected).toBe(true);
  expect(response.headers.get("x-fetch")).toBe("ok");
  expect(await response.text()).toBe("streamed response");
  expect(requestArgs[0]).toMatchObject({
    method: "POST",
    body: btoa("payload"),
    headers: [["authorization", "Bearer token"]],
  });
});

test("uses the webview fetch for non-HTTP schemes", async () => {
  globalThis.fetch = mock(() => Promise.resolve(new Response("native"))) as
    typeof globalThis.fetch;
  const response = await fetch("mygo://localhost/icon.svg");
  expect(await response.text()).toBe("native");
});
