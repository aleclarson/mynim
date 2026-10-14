## download.nim: the web context reports downloads, WebKit asks each
## where to save the file, and reports how it ended ("failed" comes
## before "finished").

var
  cbDownloadStarted*, cbDownloadDestination*, cbDownloadFinished*,
    cbDownloadFailed*: pointer

proc initDownloadCallbacks*() =
  cbDownloadStarted = cast[pointer](
    proc(ctx, d, data: pointer) {.cdecl.} =
      let w = theBackend.byWebView.getOrDefault(webkitDownloadGetWebView(d))
      if w.isNil:
        return
      downloads[d] = gtkDownload(w: w,
        url: goStr(webkitURIRequestGetURI(webkitDownloadGetRequest(d))))
      discard connect(d, "decide-destination", cbDownloadDestination, nil)
      discard connect(d, "finished", cbDownloadFinished, nil)
      discard connect(d, "failed", cbDownloadFailed, nil))
  cbDownloadDestination = cast[pointer](
    proc(d, suggested, data: pointer): bool {.cdecl.} =
      let dl = downloads.getOrDefault(d)
      if dl.isNil:
        return false
      dl.path = dl.w.h.downloadStarted(dl.url, goStr(suggested))
      if dl.path == "":
        downloads.del(d)
        webkitDownloadCancel(d)
        return true
      webkitDownloadSetAllowOverwrite(d, true)
      # file: URL of the path.
      var enc = "file://"
      for c in dl.path:
        if c in {'a'..'z','A'..'Z','0'..'9','-','.','_','~','/'}:
          enc.add c
        else:
          enc.add '%' & toHex(ord(c), 2)
      webkitDownloadSetDestination(d, cs(enc))
      true)
  cbDownloadFailed = cast[pointer](
    proc(d, gerr, data: pointer) {.cdecl.} =
      let dl = downloads.getOrDefault(d)
      if not dl.isNil:
        # GError: domain, code, then the message.
        dl.err = newException(CatchableError,
          "mynim: download failed: " & goStr(field[pointer](gerr, 8))))
  cbDownloadFinished = cast[pointer](
    proc(d, data: pointer) {.cdecl.} =
      let dl = downloads.getOrDefault(d)
      if not dl.isNil:
        downloads.del(d)
        dl.w.h.downloadFinished(dl.url, dl.path, dl.err))

## hookDownloads listens to the downloads of the web context once.
proc hookDownloads*() =
  if not downloadsHooked:
    downloadsHooked = true
    discard connect(webkitWebContextGetDefault(), "download-started",
      cbDownloadStarted, nil)
