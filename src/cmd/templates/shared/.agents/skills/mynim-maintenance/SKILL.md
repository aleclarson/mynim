---
name: mynim-maintenance
description: Maintain MyNim apps: native UI, lifetimes, state, tests, and platform behavior.
---

# MyNim app maintenance

Check the app's `mynim` dependency and nearby conventions before changing an
API. Read its package documentation and the comments beside the relevant API.
Confirm that an API exists in the version pinned by the app's Nimble package.

## Native UI lifetime and state

- A view's `ui.Context` is stable for its window. Elements created during a
  view build expire when that build returns. Keep application data and widget
  state, not `ui.Element` values, across builds.
- Use `ui.Handle` for persistent element identity, focus requests, and bounds.
  Give repeated stateful controls stable keys with `ctx.key(...)`.
- Views can rebuild more than once while handling an event. Keep rendering
  callbacks free of external side effects; use click, change, or submit
  callbacks for actions.
- Keep slow work off the UI thread. Publish background results with
  `Window.update` and ignore results that no longer match the current state.
- Prefer built-in controls and follow the active theme so keyboard, focus,
  disabled state, and accessibility continue to work.

## Verification

- Use `ui.newTester` for headless view tests. Check accessible text, clicks,
  keyboard input, focus, and text entry without depending on screenshots.
- Run the focused Nim test and `nimble test`; use `nim check` for the target
  operating systems when changing platform-specific APIs.
- Keep app state changes and UI tests deterministic. Do not rely on native
  window timing when the headless tester can exercise the behavior.
