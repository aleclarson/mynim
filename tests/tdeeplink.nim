import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "deeplink test"))
app.initialized = true

when packageIdentifier == "com.example.mynim":
  doAssert app.name() == "Configured"
  doAssert app.version() == "1.2.3"
  doAssert app.isPackaged()
else:
  doAssert not packageInfo().ok

doAssert app.registerURLScheme("mynim-test").isNil
doAssert app.isURLSchemeRegistered("MYNIM-TEST")
doAssert not app.isURLSchemeRegistered("bad scheme")
doAssert not app.registerURLScheme("2invalid").isNil

var opened = ""
discard app.onOpenURL(proc(url: string) = opened = url)
deliverArgs(["mynim-test://open?id=1", "other://ignored"], startDir)
doAssert opened == "mynim-test://open?id=1"

doAssert app.unregisterURLScheme("mynim-test").isNil
doAssert not app.isURLSchemeRegistered("mynim-test")
loop.shutdown()
