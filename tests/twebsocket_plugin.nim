import mynim as core
import mynim/plugins/websocket/service as websocket

core.use(websocket.newWebSocketPlugin())
core.bindTypeScript("plugin:websocket", "Connect", [
  core.TypeScriptParam(name: "options", tsType: "unknown"),
  core.TypeScriptParam(name: "events", tsType: "unknown", channel: true),
])
