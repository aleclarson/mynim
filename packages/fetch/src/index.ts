/**
 * Fetch requests made by the Mynim app, outside the webview's CORS and header
 * restrictions. The Nim app must register `mynim/plugins/fetch` first.
 */
import { Channel, call, isCallError } from "mygo-runtime";

interface Part {
  status?: number;
  statusText?: string;
  url?: string;
  redirected?: boolean;
  headers?: [string, string][];
  /** Base64 encoded response bytes. */
  chunk?: string;
}

const NULL_BODY = new Set([101, 103, 204, 205, 304]);
const NORMALIZED = new Set(["DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT"]);

/** Makes an HTTP request through the app and returns a standard Response. */
export async function fetch(
  input: RequestInfo | URL,
  init: RequestInit = {},
): Promise<Response> {
  const request = typeof Request !== "undefined" && input instanceof Request
    ? input
    : null;
  const base = typeof location !== "undefined" ? location.href : undefined;
  const url = new URL(
    request ? request.url : input instanceof URL ? input.href : String(input),
    base,
  );
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return globalThis.fetch(input, init);
  }

  const signal = init.signal ?? request?.signal ?? null;
  signal?.throwIfAborted();
  let method = init.method ?? request?.method ?? "GET";
  if (NORMALIZED.has(method.toUpperCase())) method = method.toUpperCase();
  const headers = new Headers(init.headers ?? request?.headers);
  let body: Uint8Array | null = null;
  if (init.body != null) {
    const bodyResponse = new Response(init.body);
    const contentType = bodyResponse.headers.get("content-type");
    if (contentType && !headers.has("content-type")) {
      headers.set("content-type", contentType);
    }
    body = new Uint8Array(await bodyResponse.arrayBuffer());
  } else if (init.body === undefined && request?.body) {
    body = new Uint8Array(await request.arrayBuffer());
  }
  if (body && (method === "GET" || method === "HEAD")) {
    throw new TypeError(`fetch: a ${method} request cannot have a body`);
  }

  const parts = new Channel<Part>();
  const done = call<void>("plugin:fetch.Fetch", {
    url: url.href,
    method,
    headers: [...headers],
    body: body && toBase64(body),
    redirect: init.redirect ?? request?.redirect ?? "follow",
  }, parts);
  const failed = done.then(
    () => null,
    (error: unknown) => failure(error),
  );
  const iterator = parts[Symbol.asyncIterator]();
  let stream: ReadableStreamDefaultController<Uint8Array> | undefined;
  let rejectHead: ((reason: unknown) => void) | undefined;
  const onAbort = () => {
    parts.close();
    try {
      stream?.error(signal!.reason);
    } catch {}
    rejectHead?.(signal!.reason);
  };
  signal?.addEventListener("abort", onAbort, { once: true });
  const cleanup = () => signal?.removeEventListener("abort", onAbort);

  let head: Part;
  try {
    const first = await new Promise<IteratorResult<Part>>((resolve, reject) => {
      rejectHead = reject;
      iterator.next().then(resolve, reject);
    });
    rejectHead = undefined;
    if (first.done) throw (await failed) ?? new TypeError("fetch failed: no response");
    head = first.value;
  } catch (error) {
    cleanup();
    parts.close();
    throw error;
  }

  const status = head.status ?? 200;
  const nullBody = NULL_BODY.has(status) || method === "HEAD";
  const readable = nullBody
    ? null
    : new ReadableStream<Uint8Array>(
        {
          start(controller) {
            stream = controller;
          },
          async pull(controller) {
            const next = await iterator.next();
            if (signal?.aborted) return;
            if (!next.done) {
              if (next.value.chunk) controller.enqueue(fromBase64(next.value.chunk));
              return;
            }
            cleanup();
            const error = await failed;
            if (error) controller.error(error);
            else controller.close();
          },
          cancel() {
            cleanup();
            parts.close();
          },
        },
        { highWaterMark: 0 },
      );
  if (nullBody) {
    parts.close();
    cleanup();
  }

  const validStatus = status >= 200 && status <= 599;
  const response = new Response(readable, {
    status: validStatus ? status : 200,
    statusText: head.statusText ?? "",
    headers: head.headers ?? [],
  });
  const define = (name: string, value: unknown) =>
    Object.defineProperty(response, name, { value, enumerable: true });
  define("url", head.url ?? url.href);
  define("redirected", head.redirected ?? false);
  if (!validStatus) define("status", status);
  return response;
}

export default fetch;

function failure(error: unknown): Error {
  if (!isCallError(error)) {
    return error instanceof Error ? error : new TypeError(String(error));
  }
  if (error.message.includes("plugin is not used")) {
    return new Error(
      "@mygo-plugins/fetch: the app does not use the plugin; " +
        "call app.use(Plugin) before app.run",
    );
  }
  return new TypeError(`fetch failed: ${error.message}`, { cause: error });
}

function toBase64(bytes: Uint8Array): string {
  const native = (bytes as Uint8Array & { toBase64?: () => string }).toBase64;
  if (native) return native.call(bytes);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(
      null,
      bytes.subarray(i, i + 0x8000) as unknown as number[],
    );
  }
  return btoa(binary);
}

function fromBase64(value: string): Uint8Array {
  const native = (Uint8Array as typeof Uint8Array & {
    fromBase64?: (value: string) => Uint8Array;
  }).fromBase64;
  if (native) return native(value);
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
