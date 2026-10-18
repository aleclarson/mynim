# @mygo-plugins/websocket

A browser-compatible `WebSocket` whose connections are opened by the Mynim
app. The app can add handshake headers, and connections are not subject to the
webview's Content Security Policy or cookies.

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

The native plugin uses `http_proxy`/`HTTP_PROXY` for `ws:` and
`https_proxy`/`HTTPS_PROXY` for `wss:`, subject to `no_proxy`/`NO_PROXY` and
the loopback bypass. Set `Options.proxy` to override the environment. HTTP
proxies support direct `ws:` forwarding and `wss:` CONNECT tunnels; SOCKS5
proxies support both schemes. An HTTPS proxy can carry `ws:`, but `wss:` over
an HTTPS proxy is not supported by Nim's current socket TLS wrapper.
