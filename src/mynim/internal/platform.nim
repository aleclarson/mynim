## Port of mygo's internal/platform: the contract between the public mynim
## API and the native backends (WKWebView on macOS, WebKitGTK on Linux,
## WebView2 on Windows).
##
## Threading rules: unless a method says otherwise it must be called on the
## main (UI) thread, and every handler callback is invoked on the main
## thread. The public package is responsible for hopping onto the main
## thread.
##
## Go interfaces map to `ref object of RootObj` + methods; the optional
## interfaces the Go code reaches through type assertions (DamageSurface,
## OccludableSurface, WideGamutSurface, MaterialSurface, IdleSurface,
## SchemeBodyWriter) are folded into their bases as `supportsX` predicates
## plus methods with defaults.

include platform/types
include platform/flyout
include platform/access
include platform/surface
include platform/watch
include platform/ifaces
include platform/text_input
include platform/texts
