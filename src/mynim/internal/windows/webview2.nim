## webview2.nim (webview2.go): WebView2 environment creation — the
## official loader next to the executable first, else the client
## library of the runtime internal/webview2 found.


## Vtable indices of the WebView2 interfaces used here, from
## WebView2.h (SDK 1.0.4191.47). Each interface extends the previous
## version, so the indices stay valid for newer runtimes.
const
  # ICoreWebView2Environment
  envCreateController* = 3
  envCreateWebResourceResponse* = 4

  # ICoreWebView2Controller, ICoreWebView2Controller2
  ctlPutIsVisible* = 4
  ctlPutBounds* = 6
  ctlGetZoomFactor* = 7
  ctlPutZoomFactor* = 8
  ctlMoveFocus* = 12
  ctlAddAcceleratorKeyPressed* = 19
  ctlNotifyParentWindowPositionChanged* = 23
  ctlClose* = 24
  ctlGetCoreWebView2* = 25
  ctl2PutDefaultBackgroundColor* = 27

  # ICoreWebView2
  wvGetSettings* = 3
  wvGetSource* = 4
  wvNavigate* = 5
  wvNavigateToString* = 6
  wvAddNavigationStarting* = 7
  wvAddContentLoading* = 9
  wvAddPermissionRequested* = 23
  wvAddNavigationCompleted* = 15
  wvAddProcessFailed* = 25
  wvAddScriptToExecuteOnDocumentCreated* = 27
  wvRemoveScriptToExecuteOnDocumentCreated* = 28
  wvExecuteScript* = 29
  wvCapturePreview* = 30
  wvReload* = 31
  wvAddWebMessageReceived* = 34
  wvCallDevToolsProtocolMethod* = 36
  wvGetCanGoBack* = 38
  wvGetCanGoForward* = 39
  wvGoBack* = 40
  wvGoForward* = 41
  wvStop* = 43
  wvAddNewWindowRequested* = 44
  wvAddDocumentTitleChanged* = 46
  wvGetDocumentTitle* = 48
  wvOpenDevToolsWindow* = 51
  wvAddWebResourceRequested* = 55
  wvAddWebResourceRequestedFilter* = 57
  wvRemoveWebResourceRequestedFilter* = 58
  wvAddWindowCloseRequested* = 59

  # ICoreWebView2Settings, ICoreWebView2Settings2
  setPutIsScriptEnabled* = 4
  setPutIsWebMessageEnabled* = 6
  setPutAreDefaultScriptDialogsEnabled* = 8
  setPutIsStatusBarEnabled* = 10
  setPutAreDevToolsEnabled* = 12
  setPutAreDefaultContextMenusEnabled* = 14
  setPutIsZoomControlEnabled* = 18
  set2GetUserAgent* = 21
  set2PutUserAgent* = 22

  # Event arguments and helpers.
  navStartingGetURI* = 3
  navStartingGetIsUserInitiated* = 4
  navStartingPutCancel* = 8
  navStarting3GetNavigationKind* = 12
  navCompletedGetIsSuccess* = 3
  navCompletedGetWebErrorStatus* = 4
  msgTryGetWebMessageAsString* = 5
  msg2GetAdditionalObjects* = 6
  objectsGetCount* = 3
  objectsGetValueAtIndex* = 4
  fileGetPath* = 3
  newWinGetURI* = 3
  newWinPutHandled* = 6
  newWinGetWindowFeatures* = 10
  featGetHasPosition* = 3
  featGetHasSize* = 4
  featGetLeft* = 5
  featGetTop* = 6
  featGetHeight* = 7
  featGetWidth* = 8
  resReqGetRequest* = 3
  resReqPutResponse* = 5
  resReqGetDeferral* = 6
  resReqGetResourceContext* = 7
  reqGetURI* = 3
  reqGetMethod* = 5
  reqGetContent* = 7
  reqGetHeaders* = 9
  headersGetIterator* = 8
  iterGetCurrentHeader* = 3
  iterGetHasCurrentHeader* = 4
  iterMoveNext* = 5
  deferralComplete* = 3
  procFailedGetKind* = 3
  wv4AddDownloadStarting* = 75 # ICoreWebView2_4
  wv13GetProfile* = 105 # ICoreWebView2_13
  profile2ClearBrowsingDataAll* = 12 # ICoreWebView2Profile2
  dlStartGetOperation* = 3
  dlStartPutCancel* = 5
  dlStartGetResultFilePath* = 6
  dlStartPutResultFilePath* = 7
  dlStartPutHandled* = 9
  dlOpAddStateChanged* = 7
  dlOpGetURI* = 9
  dlOpGetState* = 16
  dlOpGetInterruptReason* = 17
  permGetURI* = 3
  permGetKind* = 4
  permPutState* = 7
  accelGetKeyEventKind* = 3
  accelGetVirtualKey* = 4
  accelPutHandled* = 8
  comp2GetAutomationProvider* = 11 # ICoreWebView2CompositionController2
  env4GetAutomationProviderForWindow* = 11 # ICoreWebView2Environment4

var
  iidICoreWebView2Controller2* = guid(
    "c979903e-d4ca-4228-92eb-47ee3fa96eab")
  iidICoreWebView2Settings2* = guid(
    "ee9a0f68-f46c-4e32-ac23-ef8cac224d2a")
  iidICoreWebView2WebMessageReceivedEventArgs2* = guid(
    "06fc7ab7-c90c-4297-9389-33ca01cf6d5e")
  iidICoreWebView2NavigationStartingEventArgs3* = guid(
    "ddffe494-4942-4bd2-ab73-35b8ff40e19f")
  iidICoreWebView2File* = guid(
    "f2c19559-6bc1-4583-a757-90021be9afec")
  iidICoreWebView2_4* = guid(
    "20d02d59-6df2-42dc-bd06-f98a694b1302")
  iidICoreWebView2_13* = guid(
    "f75f09a8-667e-4983-88d6-c8773f315e84")
  iidICoreWebView2Profile2* = guid(
    "fa740d4b-5eae-4344-a8ad-74be31925397")
  iidICoreWebView2Environment3* = guid(
    "80a22ae3-be7c-4ce2-afe1-5a50056cdeeb")
  iidICoreWebView2Controller* = guid(
    "4d00c0d1-9434-4eb6-8078-8697a560334f")
  iidICoreWebView2CompositionController2* = guid(
    "0b6a3d24-49cb-4806-ba20-b5e0734a7b26")
  iidICoreWebView2CompositionController3* = guid(
    "9570570e-4d76-4361-9ee1-f04d0dbdfb1e")
  iidICoreWebView2Environment4* = guid(
    "20944379-6dcf-41d6-a0a0-abc0fc50de0d")
  iidICoreWebView2EnvironmentOptions* = guid(
    "2fde08a8-1e9a-4766-8c05-95a9ceb9d1c5")

## newEnvOptions makes the environment options object carrying the
## app's language (webview2_options.go). Options COM objects: a fixed
## vtable of three handlers.
type
  envOptionsCom = object
    vtbl: ptr array[6, uint]
    refs: int32
  envOptionsEntry = ref object
    com: ptr envOptionsCom
    language: WideCString

var
  envOptionsVtbl: array[6, uint]
  envOptionsObjs: Table[uint, envOptionsEntry]

proc envOptsQueryInterface(this, riid, out0: uint): uint {.stdcall.} =
  let iid = cast[ptr GUID](cast[pointer](riid))
  if iid[] != iidIUnknown and iid[] != iidICoreWebView2EnvironmentOptions:
    cast[ptr uint](cast[pointer](out0))[] = 0
    return eNoInterface
  cast[ptr uint](cast[pointer](out0))[] = this
  addRef(this)
  sOK

proc envOptsAddRef(this: uint): uint32 {.stdcall.} =
  inc cast[ptr envOptionsCom](cast[pointer](this)).refs
  uint32(cast[ptr envOptionsCom](cast[pointer](this)).refs)

proc envOptsRelease(this: uint): uint32 {.stdcall.} =
  let c = cast[ptr envOptionsCom](cast[pointer](this))
  dec c.refs
  if c.refs == 0:
    envOptionsObjs.del(this)
    dealloc(c)
    return 0
  uint32(c.refs)

proc envOptsGetLanguage(this, value: uint): uint {.stdcall.} =
  let e = envOptionsObjs.getOrDefault(this)
  if e.isNil:
    return eFail
  cast[ptr pointer](cast[pointer](value))[] =
    cast[pointer](unsafeAddr e.language[0])
  sOK

proc envOptsStub(this: uint): uint {.stdcall.} = eNotImpl

proc newEnvOptions(language: string): uint =
  if envOptionsVtbl[0] == 0:
    envOptionsVtbl = [
      cast[uint](envOptsQueryInterface),
      cast[uint](envOptsAddRef),
      cast[uint](envOptsRelease),
      cast[uint](envOptsGetLanguage),
      cast[uint](envOptsStub), # put_Language: none after creation
      cast[uint](envOptsStub), # get_AdditionalBrowserArguments
    ]
  let com = cast[ptr envOptionsCom](alloc0(sizeof(envOptionsCom)))
  com.vtbl = addr envOptionsVtbl
  com.refs = 1
  let p = cast[uint](com)
  envOptionsObjs[p] = envOptionsEntry(com: com,
    language: newWideCString(language))
  p

## loaderProc returns the official WebView2 loader next to the
## executable and its CreateCoreWebView2EnvironmentWithOptions, or
## nil when there is no loader to use. createEnvironment calls what
## it returns, and webViewSupported asks for it, so the two cannot
## disagree: a DLL of that name with no such export is no loader, and
## a runtime is looked for instead.
proc loaderProc*(): pointer =
  let exe = getAppFilename()
  if exe == "":
    return nil
  let path = parentDir(exe) / "WebView2Loader.dll"
  if not fileExists(path):
    return nil
  let lib = loadLib(path)
  if lib.isNil:
    return nil
  symAddr(lib, "CreateCoreWebView2EnvironmentWithOptions")

type envLoaderFn = proc(hwnd, userData, options,
  handler: uint): uint {.stdcall.}
type envInternalFn = proc(ver, runtimeType, userData, options,
  handler: uint): uint {.stdcall.}

## createEnvironmentWith creates the environment as
## createEnvironment does, with the options of language, or none for
## "".
proc createEnvironmentWith(userData, language: string,
    done: proc(env: uint, err: ref CatchableError) {.closure.}):
    ref CatchableError =
  proc completed(hr, env: uint) =
    if failed(hr) or env == 0:
      done(0, hresultError("creating the WebView2 environment", hr))
      return
    addRef(env)
    done(env, nil)
  if language != "":
    let options = newEnvOptions(language)
    defer: release(options)
    let proc0 = loaderProc()
    if not proc0.isNil:
      let f = cast[envLoaderFn](proc0)
      let hr = withHandler(completed, proc(h: uint): uint =
        f(0, cast[uint](u16(userData)), options, h))
      if failed(hr):
        return hresultError(
          "CreateCoreWebView2EnvironmentWithOptions", hr)
      return nil
    ## Otherwise the runtime's client library, as the loader does: a
    ## fixed version runtime named by
    ## WEBVIEW2_BROWSER_EXECUTABLE_FOLDER, else the Evergreen
    ## runtime.
    let (dir, fixed, err) = webview2.find()
    if not err.isNil:
      return err
    let client = webview2.clientDLL(dir)
    var runtimeType = 0'u
    if fixed:
      runtimeType = 1
    let lib = loadLib(client)
    if lib.isNil:
      return newException(CatchableError,
        "mynim: cannot load the WebView2 Runtime at " & client)
    let proc1 = symAddr(lib,
      "CreateWebViewEnvironmentWithOptionsInternal")
    if proc1.isNil:
      return newException(CatchableError,
        "mynim: unsupported WebView2 Runtime at " & client)
    let f = cast[envInternalFn](proc1)
    let hr = withHandler(completed, proc(h: uint): uint =
      f(1, runtimeType, cast[uint](u16(userData)), options, h))
    if failed(hr):
      return hresultError("creating the WebView2 environment", hr)
    return nil
  ## No language: the system's.
  let proc0 = loaderProc()
  if not proc0.isNil:
    let f = cast[envLoaderFn](proc0)
    let hr = withHandler(completed, proc(h: uint): uint =
      f(0, cast[uint](u16(userData)), 0, h))
    if failed(hr):
      return hresultError(
        "CreateCoreWebView2EnvironmentWithOptions", hr)
    return nil
  let (dir, fixed, err) = webview2.find()
  if not err.isNil:
    return err
  let client = webview2.clientDLL(dir)
  var runtimeType = 0'u
  if fixed:
    runtimeType = 1
  let lib = loadLib(client)
  if lib.isNil:
    return newException(CatchableError,
      "mynim: cannot load the WebView2 Runtime at " & client)
  let proc1 = symAddr(lib,
    "CreateWebViewEnvironmentWithOptionsInternal")
  if proc1.isNil:
    return newException(CatchableError,
      "mynim: unsupported WebView2 Runtime at " & client)
  let f = cast[envInternalFn](proc1)
  let hr = withHandler(completed, proc(h: uint): uint =
    f(1, runtimeType, cast[uint](u16(userData)), 0, h))
  if failed(hr):
    return hresultError("creating the WebView2 environment", hr)
  nil

## createEnvironment starts creating the WebView2 environment, in
## language, the app's (envOptions), or the system's for ""; done
## runs on the main thread with it, or with an error. A runtime that
## fails to create one with the options is asked for one without
## them.
proc createEnvironment*(userData, language: string,
    done: proc(env: uint, err: ref CatchableError) {.closure.}):
    ref CatchableError =
  var err = createEnvironmentWith(userData, language,
    proc(env: uint, err: ref CatchableError) {.closure.} =
      if not err.isNil and language != "":
        ## A runtime that takes no options of ours: one without
        ## them, in the language of the system.
        stderr.writeLine $err.msg &
          "; creating it again without its language"
        let e = createEnvironmentWith(userData, "", done)
        if not e.isNil:
          done(0, e)
        return
      done(env, err))
  if not err.isNil and language != "":
    return createEnvironmentWith(userData, "", done)
  err

## webViewSupported reports whether a window showing a web page can
## have one: the WebView2 Runtime is installed, or a loader next to
## the executable loads a fixed version runtime or the installed one
## itself. It starts nothing; once a window showing a page created
## the environment, it says whether that worked.
method webViewSupported*(b: WinBackend): bool =
  if b.env != 0 or not b.envErr.isNil:
    return b.envErr.isNil
  if not loaderProc().isNil:
    return true
  let (_, _, err) = webview2.find()
  err.isNil

## automationProvider returns WebView2's UI Automation provider of
## the page, which the window keeps a reference to, or 0.
proc automationProvider*(w: w32Window): uint =
  if w.uia == 0 and w.comp != 0:
    let comp2 = queryInterface(w.comp,
      addr iidICoreWebView2CompositionController2)
    if comp2 != 0:
      discard comCall(comp2, comp2GetAutomationProvider,
        cast[uint](addr w.uia))
      release(comp2)
  w.uia
