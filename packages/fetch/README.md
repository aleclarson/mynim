# @mygo-plugins/fetch

The Fetch bridge for Mynim apps. It sends `http:` and `https:` requests through
the app, outside webview CORS and header restrictions, and returns a standard
`Response` whose body streams through channel IPC.

Register the Nim plugin before running the app:

```nim
import mynim
import mynim/plugins/fetch

use(Plugin)
```

To route requests through an HTTP proxy, pass one to the default plugin client:

```nim
import std/httpclient
import mynim/plugins/fetch/service

let plugin = newFetchPlugin(Options(proxy: newProxy("http://127.0.0.1:8080")))
```

When `clientFactory` is set, configure the proxy on the client it returns.
Otherwise, a nil `Options.proxy` uses the `http_proxy`/`HTTP_PROXY`,
`https_proxy`/`HTTPS_PROXY`, and `no_proxy`/`NO_PROXY` environment variables;
localhost and loopback targets bypass those proxies.
An app can also provide `Options.cookieJar` callbacks: `cookies(url)` returns
`name=value` request cookies, and `store(url, setCookieHeaders)` receives each
raw `Set-Cookie` response field. The app owns matching, expiry, and persistence.

Then use the frontend package:

```ts
import { fetch } from "@mygo-plugins/fetch";

const response = await fetch("https://api.example.com/items", {
  headers: { authorization: `Bearer ${token}` },
});
const items = await response.json();
```

Other URL schemes use the webview's native `fetch`. Aborting the request,
canceling its response body, navigating away, or closing the window cancels the
app-side request.
