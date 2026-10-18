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
