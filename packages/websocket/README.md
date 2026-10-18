# @mygo-plugins/websocket

A browser-compatible `WebSocket` whose connections are opened by the Mynim
app. The app can add handshake headers and configure an optional app-managed
`Options.cookieJar`; the plugin does not use the webview's cookie store or
Content Security Policy.

Register the Nim plugin before running the app:

```nim
import mynim
import mynim/plugins/websocket

use(Plugin)
```

Then use the frontend package:

```ts
import { WebSocket } from "@mygo-plugins/websocket";

const ws = new WebSocket("wss://example.com/live", ["v1"], {
  headers: { authorization: `Bearer ${token}` },
});
ws.onopen = () => ws.send("hello");
ws.onmessage = (event) => console.log(event.data);
```

Messages preserve send order. Binary messages use `Blob` by default and can be
set to `ArrayBuffer`; page navigation closes its connections. The Nim plugin
defaults to a 64 MiB incoming-message limit and a five-second close handshake
timeout. For `wss:` connections it verifies the certificate chain and the URL
hostname before sending handshake headers. A custom Nim `tlsContext` must keep
peer certificate verification enabled.

A cookie jar returns `name=value` cookies for the handshake URL and receives
all response `Set-Cookie` fields, including fields from a rejected handshake.
Its URL uses `http:` for `ws:` and `https:` for `wss:`; the app owns cookie
matching, expiry, and storage.

Set `Options.transport` to own the opening handshake's network, proxy, and
TLS work. It receives a prepared HTTP(S) `GET` request and cancellation context, which
the handler must honor; it must not follow redirects. For a `101` response,
return the status and
headers, a `DuplexStream`, and any WebSocket bytes already read past the HTTP
headers in `readBuffer`. The transport overrides `Options.proxy` and
`Options.tlsContext`; cookie-jar callbacks still apply.

The native plugin uses `http_proxy`/`HTTP_PROXY` for `ws:` and
`https_proxy`/`HTTPS_PROXY` for `wss:`, subject to `no_proxy`/`NO_PROXY` and
the loopback bypass. Set `Options.proxy` to override the environment. HTTP
proxies support direct `ws:` forwarding and `wss:` CONNECT tunnels; SOCKS5
proxies support both schemes. An HTTPS proxy can carry `ws:`, but `wss:` over
an HTTPS proxy is not supported by Nim's current socket TLS wrapper.
