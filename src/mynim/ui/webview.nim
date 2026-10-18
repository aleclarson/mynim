## Native web views embedded in the GPU-rendered UI.

type NativeWebView* = surface.SurfaceWebView ## A web view made by Window.newWebView for native UI.

proc webView*(c: Context; view: NativeWebView): Element =
  ## Adds a native web view that fills its element's content box.
  result = c.newElement(false, identityKindWebView)
  let node = result.node
  if node != nil:
    node[].webView = view
    node[].selfAlign = Align.Stretch
    node[].focusable = true
    node[].accessRole = platform.roleGroup
    node[].accessRoleSet = true

proc webContentBox(node: ElementNode; box: Rect): Rect =
  let left = node.border[3] + node.pad[3]
  let top = node.border[0] + node.pad[0]
  let right = node.border[1] + node.pad[1]
  let bottom = node.border[2] + node.pad[2]
  Rect(x: box.x + left, y: box.y + top,
    w: max(box.w - left - right, 0'f32),
    h: max(box.h - top - bottom, 0'f32))

proc intersectRect(a, b: Rect): Rect =
  let left = max(a.x, b.x)
  let top = max(a.y, b.y)
  let right = min(a.x + a.w, b.x + b.w)
  let bottom = min(a.y + a.h, b.y + b.h)
  Rect(x: left, y: top, w: max(right - left, 0'f32),
    h: max(bottom - top, 0'f32))

proc snappedRect(rect, root: Rect; scale: float32): platform.RectF =
  let pixelScale = scale.float64
  let x0 = round((rect.x.float64 - root.x.float64) * pixelScale) /
    pixelScale
  let y0 = round((rect.y.float64 - root.y.float64) * pixelScale) /
    pixelScale
  let x1 = round((rect.x.float64 + rect.w.float64 - root.x.float64) *
    pixelScale) / pixelScale
  let y1 = round((rect.y.float64 + rect.h.float64 - root.y.float64) *
    pixelScale) / pixelScale
  platform.RectF(x: x0, y: y0, w: max(x1 - x0, 0),
    h: max(y1 - y0, 0))

proc intersectRect(a, b: platform.RectF): platform.RectF =
  let left = max(a.x, b.x)
  let top = max(a.y, b.y)
  let right = min(a.x + a.w, b.x + b.w)
  let bottom = min(a.y + a.h, b.y + b.h)
  platform.RectF(x: left, y: top, w: max(right - left, 0),
    h: max(bottom - top, 0))

proc addCover(covers: var seq[platform.RectF]; cover: platform.RectF) =
  if cover.w <= 0 or cover.h <= 0:
    return
  for existing in covers:
    if cover.x >= existing.x and cover.y >= existing.y and
        cover.x + cover.w <= existing.x + existing.w and
        cover.y + cover.h <= existing.y + existing.h:
      return
  covers.add(cover)

proc webViewPlacement(layout: LayoutResult; conn: surface.Conn;
    scale: float32; order, slot: int): Option[platform.WebViewPlacement] =
  let owner = layout.owner
  if conn == nil or owner == nil or layout.generation != owner.generation or
      layout.rects.len != owner.nodes.len or
      owner.visibleClipScratch.len != owner.nodes.len:
    return
  let node = owner.nodes[slot]
  if node.webView == nil or layout.backfaceBlocked[slot] or
      owner.effectivelyToolbarCollapsed(slot) or
      layout.insideCapturedEffect(slot, scale):
    return
  let native = node.webView.surfaceWebView(conn)
  if native == nil:
    return
  let content = node.webContentBox(layout.rects[slot])
  let frame = layout.worldTransforms[slot].transformedRect(content)
  let visible = intersectRect(frame, owner.visibleClipScratch[slot])
  if visible.w <= 0 or visible.h <= 0 or opacityOf(owner.nodes, slot) == 0:
    return
  let snappedFrame = snappedRect(frame, layout.root, scale)
  let snappedClip = intersectRect(snappedRect(visible, layout.root, scale),
    snappedFrame)
  var covers: seq[platform.RectF]
  let inert = owner.effectivelyInert(slot) or
    not owner.inActiveModalScope(slot) or node.passThrough
  if inert:
    covers.add(snappedClip)
  else:
    for aboveOrder in order + 1 ..< owner.paintSlots.len:
      let aboveSlot = owner.paintSlots[aboveOrder]
      if not layout.pointerTransparent(aboveSlot) and
          not owner.effectivelyInert(aboveSlot) and
          owner.inActiveModalScope(aboveSlot) and
          not owner.effectivelyToolbarCollapsed(aboveSlot):
        var hit = intersectRect(layout.visualRects[aboveSlot],
          owner.visibleClipScratch[aboveSlot])
        hit = intersectRect(hit, visible)
        covers.addCover(snappedRect(hit, layout.root, scale))

  some(platform.WebViewPlacement(webView: native,
    frame: snappedFrame, clip: snappedClip, covers: covers))

proc webViewPlacements(layout: LayoutResult; conn: surface.Conn;
                       scale: float32): seq[platform.WebViewPlacement] =
  let owner = layout.owner
  if owner == nil or owner.paintSlots.len == 0:
    return
  for order, slot in owner.paintSlots:
    let placement = layout.webViewPlacement(conn, scale, order, slot)
    if placement.isSome:
      let next = placement.get
      var existing = -1
      for i, current in result:
        if current.webView == next.webView:
          existing = i
          break
      if existing >= 0:
        result.delete(existing)
      result.add(next)

proc placeWebViews(layout: LayoutResult; conn: surface.Conn;
                   scale: float32) =
  if conn == nil:
    return
  let placements = layout.webViewPlacements(conn, scale)
  if conn.placeWebViews != nil:
    conn.placeWebViews(placements)
  elif conn.surface != nil:
    conn.surface.placeWebViews(placements)

proc nativeWebView(layout: LayoutResult; conn: surface.Conn;
                   slot: int): platform.WebView =
  if conn == nil or layout.owner == nil or slot <= 0 or
      slot >= layout.owner.nodes.len:
    return nil
  let view = layout.owner.nodes[slot].webView
  if view != nil:
    result = view.surfaceWebView(conn)
