import { afterEach, expect, mock, test } from "bun:test";

type ChannelHandler = (value: any) => void;
class TestChannel {
  constructor(readonly onmessage: ChannelHandler) { channels.push(this); }
  closed = false;
  emit(value: unknown) { if (!this.closed) this.onmessage(value); }
  close() { this.closed = true; }
}

let calls: { name: string; params: unknown[] }[] = [];
let channels: TestChannel[] = [];
let rejects: unknown;
mock.module("mygo-runtime", () => ({
  Channel: TestChannel,
  call: (name: string, ...params: unknown[]) => {
    calls.push({ name, params });
    if (name === "plugin:websocket.Connect") {
      return rejects ? Promise.reject(rejects) : new Promise(() => {});
    }
    return Promise.resolve();
  },
  isCallError: (error: unknown) => error instanceof Error,
}));

const { WebSocket } = await import("../src/index.ts");

afterEach(() => {
  calls = [];
  channels = [];
  rejects = undefined;
});

test("normalizes the URL and sends protocols and handshake headers", () => {
  const socket = new WebSocket("https://example.com/live", ["v1"], {
    headers: { Authorization: "Bearer token" },
  });
  expect(socket.url).toBe("wss://example.com/live");
  expect(calls[0].name).toBe("plugin:websocket.Connect");
  expect(calls[0].params[0]).toEqual({
    id: expect.any(String),
    url: "wss://example.com/live",
    protocols: ["v1"],
    headers: [["authorization", "Bearer token"]],
  });
  channels[0].emit({ type: "open", protocol: "v1" });
  expect(socket.readyState).toBe(WebSocket.OPEN);
  expect(socket.protocol).toBe("v1");
});

test("sends text and binary messages in sequence and counts buffered bytes", async () => {
  const socket = new WebSocket("ws://example.com/live");
  channels[0].emit({ type: "open" });
  socket.send("hello");
  socket.send(new Uint8Array([0, 255]));
  expect(socket.bufferedAmount).toBe(7);
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(calls.filter((call) => call.name === "plugin:websocket.Send").map((call) => call.params))
    .toEqual([
      [expect.any(String), 1, { type: "text", text: "hello" }],
      [expect.any(String), 2, { type: "binary", data: btoa("\0ÿ") }],
    ]);
  expect(socket.bufferedAmount).toBe(0);
});

test("dispatches text, binary, and clean close events", () => {
  const socket = new WebSocket("ws://example.com/live");
  let received: unknown;
  let closed: CloseEvent | undefined;
  socket.addEventListener("message", (event) => { received = event.data; });
  socket.onclose = (event) => { closed = event; };
  channels[0].emit({ type: "open" });
  channels[0].emit({ type: "text", text: "hello" });
  expect(received).toBe("hello");
  socket.binaryType = "arraybuffer";
  channels[0].emit({ type: "binary", data: btoa("\0ÿ") });
  expect([...new Uint8Array(received as ArrayBuffer)]).toEqual([0, 255]);
  channels[0].emit({ type: "close", code: 1000, reason: "done", clean: true });
  expect(socket.readyState).toBe(WebSocket.CLOSED);
  expect(closed).toMatchObject({ code: 1000, reason: "done", wasClean: true });
});

test("validates protocols, URL schemes, and close arguments", () => {
  expect(() => new WebSocket("ftp://example.com")).toThrow(DOMException);
  expect(() => new WebSocket("ws://example.com/#fragment")).toThrow(DOMException);
  expect(() => new WebSocket("ws://example.com", ["v1", "v1"]))
    .toThrow("contain duplicates");
  const socket = new WebSocket("ws://example.com");
  expect(() => socket.close(1001)).toThrow(DOMException);
  expect(() => socket.close(3000, "a".repeat(124))).toThrow(DOMException);
});
