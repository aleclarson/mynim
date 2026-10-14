## pango.nim (pango_linux.go): the text engine of Linux. Fonts are found
## for what a font lacks, HarfBuzz shapes, and Pango breaks lines. Cairo
## rasterizes glyphs, with FreeType, in color for color fonts. They are
## the libraries GTK draws with, loaded with dlopen.

import std/[sha1, math, strutils, unicode, os, tables]

proc dlopen(path: cstring, mode: cint): pointer
  {.importc: "dlopen", dynlib: "libdl.so.2".}
proc dlsym(handle: pointer, name: cstring): pointer
  {.importc: "dlsym", dynlib: "libdl.so.2".}

const
  pangoScale = 1024
  pangoGlyphEmpty = 0x0FFFFFFF'u32
  pangoGlyphUnknown = 0x10000000'u32

  pangoWrapWord = 0
  pangoWrapWordChar = 2
  pangoStyleNormal = 0
  pangoStyleItalic = 2
  pangoDirLTR = 0
  pangoDirRTL = 1

  cairoFormatARGB32 = 0
  cairoAntialiasDefault = 0
  cairoAntialiasNone = 1
  cairoAntialiasGray = 2
  cairoAntialiasSubpixel = 3
  cairoHintStyleDefault = 0
  cairoHintStyleNone = 1
  cairoHintStyleSlight = 2
  cairoHintStyleMedium = 3
  cairoHintStyleFull = 4
  cairoHintMetricsOn = 2
  cairoStatusSuccess = 0
  fcResultMatch = 0
  fcSetApplication = 1

const
  rtldNowPl = 2
  rtldGlobalPl = 0x100

proc cs*(s: string): cstring = s.cstring

proc xmlEscape*(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"),
    ("\"", "&quot;"))

proc goStr0*(p: pointer): string =
  if p.isNil:
    return ""
  $cast[cstring](p)

# Pango and cairo structs, as their headers lay them out.
type
  gSList = object
    data: pointer
    next: ptr gSList
  pangoLayoutLine = object
    layout: pointer
    startIndex, length: int32
    runs: ptr gSList
    flags: uint32
  pangoGlyphItem = object
    item: ptr pangoItem
    glyphs: ptr pangoGlyphString
  pangoItem = object
    offset, length, numChars: int32
    pad: int32
    shapeEngine, langEngine: pointer
    font: pointer
    level: uint8
  pangoGlyphString = object
    numGlyphs: int32
    glyphs: ptr pangoGlyphInfo
    logClusters: ptr int32
  pangoGlyphInfo = object
    glyph: uint32
    width, xOffset, yOffset: int32
    attr: uint32
  cairoMatrix = object
    xx, yx, xy, yy, x0, y0: float64
  cairoGlyph = object
    index: uint64
    x, y: float64
  cairoTextExtents = object
    xBearing, yBearing, width, height, xAdvance, yAdvance: float64
  pangoRectangle = object
    x, y, width, height: int32
  fcFontSet = object
    nfont, sfont: int32
    fonts: ptr pointer

var pangoLib: tuple[
  gObjectRef: proc(obj: pointer): pointer {.cdecl.},
  gObjectUnref: proc(obj: pointer) {.cdecl.},
  gFree: proc(p: pointer) {.cdecl.},

  fontMapListFamilies: proc(fontMap: pointer, families: ptr pointer,
    n: ptr int32) {.cdecl.},
  fontFamilyGetName: proc(family: pointer): pointer {.cdecl.},
  fontFamilyIsMonospace: proc(family: pointer): bool {.cdecl.},

  fontMapNew: proc(): pointer {.cdecl.},
  fontMapCreateContext: proc(fontMap: pointer): pointer {.cdecl.},
  fontMapLoadFont: proc(fontMap, context, desc: pointer):
    pointer {.cdecl.},
  contextSetFontOptions: proc(context, options: pointer) {.cdecl.},
  contextSetBaseDir: proc(context: pointer, dir: int32) {.cdecl.},
  contextSetRoundPositions: proc(context: pointer,
    round: int32) {.cdecl.},
  fontGetScaledFont: proc(font: pointer): pointer {.cdecl.},
  fontGetMetrics: proc(font, language: pointer): pointer {.cdecl.},
  fontDescribeAbsolute: proc(font: pointer): pointer {.cdecl.},
  fontGetHBFont: proc(font: pointer): pointer {.cdecl.},
  hbNominalGlyph: proc(font: pointer, r: int32,
    glyph: ptr uint32): int32 {.cdecl.},
  hbGlyphHAdvance: proc(font: pointer, glyph: uint32): int32 {.cdecl.},
  metricsGetAscent: proc(metrics: pointer): int32 {.cdecl.},
  metricsGetUnderlinePos: proc(metrics: pointer): int32 {.cdecl.},
  metricsGetUnderlineThick: proc(metrics: pointer): int32 {.cdecl.},
  metricsGetStrikePos: proc(metrics: pointer): int32 {.cdecl.},
  metricsGetStrikeThick: proc(metrics: pointer): int32 {.cdecl.},
  fontGetGlyphExtents: proc(font: pointer, glyph: uint32,
    ink, logical: ptr pangoRectangle) {.cdecl.},
  metricsGetDescent: proc(metrics: pointer): int32 {.cdecl.},
  metricsGetHeight: proc(metrics: pointer): int32 {.cdecl.},
  metricsUnref: proc(metrics: pointer) {.cdecl.},
  descNew: proc(): pointer {.cdecl.},
  descFree: proc(desc: pointer) {.cdecl.},
  descSetFamily: proc(desc: pointer, family: cstring) {.cdecl.},
  descSetWeight: proc(desc: pointer, weight: int32) {.cdecl.},
  descSetStyle: proc(desc: pointer, style: int32) {.cdecl.},
  descSetAbsoluteSize: proc(desc: pointer, size: float64) {.cdecl.},
  descGetSize: proc(desc: pointer): int32 {.cdecl.},
  layoutNew: proc(context: pointer): pointer {.cdecl.},
  layoutSetText: proc(layout: pointer, text: pointer,
    length: int32) {.cdecl.},
  layoutSetFontDescription: proc(layout, desc: pointer) {.cdecl.},
  layoutSetWidth: proc(layout: pointer, width: int32) {.cdecl.},
  layoutSetWrap: proc(layout: pointer, wrap: int32) {.cdecl.},
  layoutSetAutoDir: proc(layout: pointer, auto0: int32) {.cdecl.},
  layoutGetLineCount: proc(layout: pointer): int32 {.cdecl.},
  layoutGetLineReadonly: proc(layout: pointer,
    line: int32): ptr pangoLayoutLine {.cdecl.},
  layoutSetAttributes: proc(layout, attrs: pointer) {.cdecl.},
  attrListNew: proc(): pointer {.cdecl.},
  attrListUnref: proc(list: pointer) {.cdecl.},
  attrListInsert: proc(list, attr: pointer) {.cdecl.},
  attrLetterSpacingNew: proc(spacing: int32): pointer {.cdecl.},
  attrFontFeaturesNew: proc(features: cstring): pointer {.cdecl.},
  attrFamilyNew: proc(family: cstring): pointer {.cdecl.},
  attrSizeAbsoluteNew: proc(size: int32): pointer {.cdecl.},
  attrWeightNew: proc(weight: int32): pointer {.cdecl.},
  attrStyleNew: proc(style: int32): pointer {.cdecl.},
  attrShapeNew: proc(ink, logical: ptr pangoRectangle):
    pointer {.cdecl.},
  attrLanguageNew: proc(language: pointer): pointer {.cdecl.},
  languageFromString: proc(tag: cstring): pointer {.cdecl.},
  languageGetDefault: proc(): pointer {.cdecl.},
  fontMapConfigChanged: proc(fontMap: pointer) {.cdecl.},
  cairoFontOptionsCreate: proc(): pointer {.cdecl.},
  cairoFontOptionsDestroy: proc(options: pointer) {.cdecl.},
  cairoFontOptionsAntialias: proc(options: pointer,
    antialias: int32) {.cdecl.},
  cairoFontOptionsHintMets: proc(options: pointer,
    hint: int32) {.cdecl.},
  cairoFontOptionsHintStyle: proc(options: pointer,
    style: int32) {.cdecl.},
  cairoFontOptionsSubpixel: proc(options: pointer,
    order: int32) {.cdecl.},
  cairoScaledFontFace: proc(font: pointer): pointer {.cdecl.},
  cairoScaledFontMatrix: proc(font: pointer,
    m: ptr cairoMatrix) {.cdecl.},
  cairoScaledFontOptions: proc(font, options: pointer) {.cdecl.},
  cairoScaledFontCreate: proc(face: pointer, fontMatrix,
    ctm: ptr cairoMatrix, options: pointer): pointer {.cdecl.},
  cairoScaledFontStatus: proc(font: pointer): int32 {.cdecl.},
  cairoScaledFontDestroy: proc(font: pointer) {.cdecl.},
  cairoScaledFontExtents: proc(font: pointer, glyphs: ptr cairoGlyph,
    n: int32, extents: ptr cairoTextExtents) {.cdecl.},
  cairoImageSurfaceCreate: proc(format, width, height: int32):
    pointer {.cdecl.},
  cairoImageSurfaceData: proc(surface: pointer):
    ptr UncheckedArray[byte] {.cdecl.},
  cairoImageSurfaceStride: proc(surface: pointer): int32 {.cdecl.},
  cairoSurfaceFlush: proc(surface: pointer) {.cdecl.},
  cairoSurfaceDestroy: proc(surface: pointer) {.cdecl.},
  cairoCreate: proc(surface: pointer): pointer {.cdecl.},
  cairoDestroy: proc(cr: pointer) {.cdecl.},
  cairoSetScaledFont: proc(cr, font: pointer) {.cdecl.},
  cairoSetSourceRGBA: proc(cr: pointer, r, g, b, a: float64) {.cdecl.},
  cairoShowGlyphs: proc(cr: pointer, glyphs: ptr cairoGlyph,
    n: int32) {.cdecl.},
  fcConfigGetCurrent: proc(): pointer {.cdecl.},
  fcConfigAppFontAddFile: proc(config: pointer, file: cstring):
    int32 {.cdecl.},
  fcConfigGetFonts: proc(config: pointer, set: int32):
    ptr fcFontSet {.cdecl.},
  fcConfigParseFromMemory: proc(config: pointer, xml: cstring,
    complain: int32): int32 {.cdecl.},
  fcPatternGetString: proc(pattern: pointer, `object`: cstring,
    n: int32, `out`: ptr pointer): int32 {.cdecl.}]

proc pangoOpen(names: varargs[string]):
    tuple[h: pointer, err: ref CatchableError] =
  var last: ref CatchableError
  for n in names:
    let h = dlopen(cs(n), rtldNowPl or rtldGlobalPl)
    if not h.isNil:
      return (h, nil)
    last = newException(CatchableError, "dlopen " & n & " failed")
  (nil, last)

proc plBind(lib: pointer, fn: ptr pointer, name: string,
    missing: var seq[string]) =
  let p = dlsym(lib, cs(name))
  if p.isNil:
    missing.add name
  else:
    fn[] = p

proc loadPango*(): ref CatchableError =
  var err: ref CatchableError
  var gobject, pango, glib, pangocairo, cairo: pointer
  (gobject, err) = pangoOpen("libgobject-2.0.so.0")
  if not err.isNil: return err
  (pango, err) = pangoOpen("libpango-1.0.so.0")
  if not err.isNil: return err
  (glib, err) = pangoOpen("libglib-2.0.so.0")
  if not err.isNil: return err
  (pangocairo, err) = pangoOpen("libpangocairo-1.0.so.0")
  if not err.isNil: return err
  (cairo, err) = pangoOpen("libcairo.so.2")
  if not err.isNil: return err
  var missing: seq[string]
  let l = addr pangoLib
  plBind(gobject, cast[ptr pointer](addr l.gObjectRef), "g_object_ref",
    missing)
  plBind(gobject, cast[ptr pointer](addr l.gObjectUnref),
    "g_object_unref", missing)
  plBind(glib, cast[ptr pointer](addr l.gFree), "g_free", missing)
  plBind(pango, cast[ptr pointer](addr l.fontMapListFamilies),
    "pango_font_map_list_families", missing)
  plBind(pango, cast[ptr pointer](addr l.fontFamilyGetName),
    "pango_font_family_get_name", missing)
  plBind(pango, cast[ptr pointer](addr l.fontFamilyIsMonospace),
    "pango_font_family_is_monospace", missing)
  plBind(pangocairo, cast[ptr pointer](addr l.fontMapNew),
    "pango_cairo_font_map_new", missing)
  plBind(pangocairo, cast[ptr pointer](addr l.contextSetFontOptions),
    "pango_cairo_context_set_font_options", missing)
  plBind(pangocairo, cast[ptr pointer](addr l.fontGetScaledFont),
    "pango_cairo_font_get_scaled_font", missing)
  plBind(pango, cast[ptr pointer](addr l.fontMapCreateContext),
    "pango_font_map_create_context", missing)
  plBind(pango, cast[ptr pointer](addr l.fontMapLoadFont),
    "pango_font_map_load_font", missing)
  plBind(pango, cast[ptr pointer](addr l.contextSetBaseDir),
    "pango_context_set_base_dir", missing)
  plBind(pango, cast[ptr pointer](addr l.fontGetMetrics),
    "pango_font_get_metrics", missing)
  plBind(pango, cast[ptr pointer](addr l.fontDescribeAbsolute),
    "pango_font_describe_with_absolute_size", missing)
  plBind(pango, cast[ptr pointer](addr l.metricsGetAscent),
    "pango_font_metrics_get_ascent", missing)
  plBind(pango, cast[ptr pointer](addr l.metricsGetUnderlinePos),
    "pango_font_metrics_get_underline_position", missing)
  plBind(pango, cast[ptr pointer](addr l.metricsGetUnderlineThick),
    "pango_font_metrics_get_underline_thickness", missing)
  plBind(pango, cast[ptr pointer](addr l.metricsGetStrikePos),
    "pango_font_metrics_get_strikethrough_position", missing)
  plBind(pango, cast[ptr pointer](addr l.metricsGetStrikeThick),
    "pango_font_metrics_get_strikethrough_thickness", missing)
  plBind(pango, cast[ptr pointer](addr l.fontGetGlyphExtents),
    "pango_font_get_glyph_extents", missing)
  plBind(pango, cast[ptr pointer](addr l.metricsGetDescent),
    "pango_font_metrics_get_descent", missing)
  plBind(pango, cast[ptr pointer](addr l.metricsUnref),
    "pango_font_metrics_unref", missing)
  plBind(pango, cast[ptr pointer](addr l.descNew),
    "pango_font_description_new", missing)
  plBind(pango, cast[ptr pointer](addr l.descFree),
    "pango_font_description_free", missing)
  plBind(pango, cast[ptr pointer](addr l.descSetFamily),
    "pango_font_description_set_family", missing)
  plBind(pango, cast[ptr pointer](addr l.descSetWeight),
    "pango_font_description_set_weight", missing)
  plBind(pango, cast[ptr pointer](addr l.descSetStyle),
    "pango_font_description_set_style", missing)
  plBind(pango, cast[ptr pointer](addr l.descSetAbsoluteSize),
    "pango_font_description_set_absolute_size", missing)
  plBind(pango, cast[ptr pointer](addr l.descGetSize),
    "pango_font_description_get_size", missing)
  plBind(pango, cast[ptr pointer](addr l.layoutNew),
    "pango_layout_new", missing)
  plBind(pango, cast[ptr pointer](addr l.layoutSetText),
    "pango_layout_set_text", missing)
  plBind(pango, cast[ptr pointer](addr l.layoutSetFontDescription),
    "pango_layout_set_font_description", missing)
  plBind(pango, cast[ptr pointer](addr l.layoutSetWidth),
    "pango_layout_set_width", missing)
  plBind(pango, cast[ptr pointer](addr l.layoutSetWrap),
    "pango_layout_set_wrap", missing)
  plBind(pango, cast[ptr pointer](addr l.layoutSetAutoDir),
    "pango_layout_set_auto_dir", missing)
  plBind(pango, cast[ptr pointer](addr l.layoutGetLineCount),
    "pango_layout_get_line_count", missing)
  plBind(pango, cast[ptr pointer](addr l.layoutGetLineReadonly),
    "pango_layout_get_line_readonly", missing)
  plBind(pango, cast[ptr pointer](addr l.layoutSetAttributes),
    "pango_layout_set_attributes", missing)
  plBind(pango, cast[ptr pointer](addr l.attrListNew),
    "pango_attr_list_new", missing)
  plBind(pango, cast[ptr pointer](addr l.attrListUnref),
    "pango_attr_list_unref", missing)
  plBind(pango, cast[ptr pointer](addr l.attrListInsert),
    "pango_attr_list_insert", missing)
  plBind(pango, cast[ptr pointer](addr l.attrLetterSpacingNew),
    "pango_attr_letter_spacing_new", missing)
  plBind(pango, cast[ptr pointer](addr l.attrFamilyNew),
    "pango_attr_family_new", missing)
  plBind(pango, cast[ptr pointer](addr l.attrSizeAbsoluteNew),
    "pango_attr_size_new_absolute", missing)
  plBind(pango, cast[ptr pointer](addr l.attrWeightNew),
    "pango_attr_weight_new", missing)
  plBind(pango, cast[ptr pointer](addr l.attrStyleNew),
    "pango_attr_style_new", missing)
  plBind(pango, cast[ptr pointer](addr l.attrShapeNew),
    "pango_attr_shape_new", missing)
  plBind(pango, cast[ptr pointer](addr l.attrLanguageNew),
    "pango_attr_language_new", missing)
  plBind(pango, cast[ptr pointer](addr l.languageFromString),
    "pango_language_from_string", missing)
  plBind(pango, cast[ptr pointer](addr l.languageGetDefault),
    "pango_language_get_default", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoFontOptionsCreate),
    "cairo_font_options_create", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoFontOptionsDestroy),
    "cairo_font_options_destroy", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoFontOptionsAntialias),
    "cairo_font_options_set_antialias", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoFontOptionsHintMets),
    "cairo_font_options_set_hint_metrics", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoFontOptionsHintStyle),
    "cairo_font_options_set_hint_style", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoFontOptionsSubpixel),
    "cairo_font_options_set_subpixel_order", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoScaledFontFace),
    "cairo_scaled_font_get_font_face", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoScaledFontMatrix),
    "cairo_scaled_font_get_font_matrix", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoScaledFontOptions),
    "cairo_scaled_font_get_font_options", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoScaledFontCreate),
    "cairo_scaled_font_create", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoScaledFontStatus),
    "cairo_scaled_font_status", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoScaledFontDestroy),
    "cairo_scaled_font_destroy", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoScaledFontExtents),
    "cairo_scaled_font_glyph_extents", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoImageSurfaceCreate),
    "cairo_image_surface_create", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoImageSurfaceData),
    "cairo_image_surface_get_data", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoImageSurfaceStride),
    "cairo_image_surface_get_stride", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoSurfaceFlush),
    "cairo_surface_flush", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoSurfaceDestroy),
    "cairo_surface_destroy", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoCreate), "cairo_create",
    missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoDestroy),
    "cairo_destroy", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoSetScaledFont),
    "cairo_set_scaled_font", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoSetSourceRGBA),
    "cairo_set_source_rgba", missing)
  plBind(cairo, cast[ptr pointer](addr l.cairoShowGlyphs),
    "cairo_show_glyphs", missing)
  if missing.len > 0:
    return newException(CatchableError,
      "Pango or cairo lacks " & missing.join(", "))
  # Optional: Pango 1.44 and later, and what adding fonts needs.
  missing = @[]
  plBind(pango, cast[ptr pointer](addr l.contextSetRoundPositions),
    "pango_context_set_round_glyph_positions", missing)
  plBind(pango, cast[ptr pointer](addr l.attrFontFeaturesNew),
    "pango_attr_font_features_new", missing)
  plBind(pango, cast[ptr pointer](addr l.metricsGetHeight),
    "pango_font_metrics_get_height", missing)
  plBind(pango, cast[ptr pointer](addr l.fontGetHBFont),
    "pango_font_get_hb_font", missing)
  let (hb, _) = pangoOpen("libharfbuzz.so.0")
  if not hb.isNil:
    plBind(hb, cast[ptr pointer](addr l.hbNominalGlyph),
      "hb_font_get_nominal_glyph", missing)
    plBind(hb, cast[ptr pointer](addr l.hbGlyphHAdvance),
      "hb_font_get_glyph_h_advance", missing)
  let (ft, _) = pangoOpen("libpangoft2-1.0.so.0")
  if not ft.isNil:
    plBind(ft, cast[ptr pointer](addr l.fontMapConfigChanged),
      "pango_fc_font_map_config_changed", missing)
  let (fc, _) = pangoOpen("libfontconfig.so.1")
  if not fc.isNil:
    plBind(fc, cast[ptr pointer](addr l.fcConfigGetCurrent),
      "FcConfigGetCurrent", missing)
    plBind(fc, cast[ptr pointer](addr l.fcConfigAppFontAddFile),
      "FcConfigAppFontAddFile", missing)
    plBind(fc, cast[ptr pointer](addr l.fcConfigGetFonts),
      "FcConfigGetFonts", missing)
    plBind(fc, cast[ptr pointer](addr l.fcConfigParseFromMemory),
      "FcConfigParseAndLoadFromMemory", missing)
    plBind(fc, cast[ptr pointer](addr l.fcPatternGetString),
      "FcPatternGetString", missing)
  nil

type
  scaledKey* = object
    font: Font
    scale: float32
    subpixel: bool

  PangoEngine* = ref object of Engine
    fontMap: pointer
    context: pointer
    descs: Table[Style, pointer] ## font descriptions, by style
    fonts: Table[uint, Font] ## by PangoFont
    scaled: Table[scaledKey, pointer]
    registered: Table[string, bool] ## files of registered fonts
    ## names are the names the app registered fonts under, as it gave
    ## them, and their own; appFamily the family of each, by lowercased
    ## name.
    names: seq[string]
    appFamily: Table[string, string]
    ## uiFamily is the desktop's interface font, which system-ui stands
    ## for before fontconfig's default.
    uiFamily: string
    ## The cairo antialiasing, hint style and subpixel order of the
    ## desktop's settings (setFontRendering), as GTK has its labels
    ## draw.
    antialias, hintStyle, subpixels: int32
    ## languages are the PangoLanguages of tags.
    languages: Table[string, pointer]

proc applyOptions*(e: PangoEngine) ## below
proc fontOf*(e: PangoEngine, font: pointer): Font ## below
proc space*(e: PangoEngine, font: pointer, r: Rune):
  tuple[glyph: uint32, advance: int32] ## below
proc scaledFont*(e: PangoEngine, f: Font, scale: float32,
  subpixel: bool): pointer ## below
proc ink*(e: PangoEngine, f: Font, id: uint32):
  tuple[a, b: float32, ok: bool] ## below
proc draw*(e: PangoEngine, f: Font, id: uint32, scale, dx: float32,
  subpixel: bool): bitmap ## below
proc fontFamilies*(config: pointer, path: string): seq[string] ## below

method setFontRendering*(e: PangoEngine, antialias, hinting,
    subpixels: string) =
  ## takes the desktop's settings (platform.FontRendering) for the fonts
  ## made from now on.
  e.antialias = {"none": cairoAntialiasNone.int32,
    "gray": cairoAntialiasGray.int32,
    "subpixel": cairoAntialiasSubpixel.int32}.toTable.getOrDefault(
      antialias)
  e.hintStyle = {"none": cairoHintStyleNone.int32,
    "slight": cairoHintStyleSlight.int32,
    "medium": cairoHintStyleMedium.int32,
    "full": cairoHintStyleFull.int32}.toTable.getOrDefault(hinting)
  e.subpixels = {"rgb": 1'i32, "bgr": 2'i32, "vrgb": 3'i32,
    "vbgr": 4'i32}.toTable.getOrDefault(subpixels)
  e.applyOptions()
  for sf in e.scaled.values:
    pangoLib.cairoScaledFontDestroy(sf)
  e.scaled.clear()

## applyOptions gives the context GTK's font options for labels: the
## desktop's antialiasing, hint style and subpixel order, metrics hinted
## to whole pixels, and glyphs on whole pixels.
proc applyOptions*(e: PangoEngine) =
  let l = addr pangoLib
  let opts = l.cairoFontOptionsCreate()
  l.cairoFontOptionsAntialias(opts, e.antialias)
  l.cairoFontOptionsHintStyle(opts, e.hintStyle)
  l.cairoFontOptionsSubpixel(opts, e.subpixels)
  l.cairoFontOptionsHintMets(opts, cairoHintMetricsOn)
  l.contextSetFontOptions(e.context, opts)
  l.cairoFontOptionsDestroy(opts)
  if not l.contextSetRoundPositions.isNil:
    l.contextSetRoundPositions(e.context, 1)

method setUIFamily*(e: PangoEngine, family: string) =
  if family == e.uiFamily:
    return
  e.uiFamily = family
  for d in e.descs.values:
    pangoLib.descFree(d)
  e.descs.clear()

proc newPango*(): PangoEngine =
  let err = loadPango()
  if not err.isNil:
    raise err
  let l = addr pangoLib
  let e = PangoEngine(
    descs: initTable[Style, pointer](),
    fonts: initTable[uint, Font](),
    scaled: initTable[scaledKey, pointer](),
    registered: initTable[string, bool](),
    appFamily: initTable[string, string](),
    languages: initTable[string, pointer]())
  # A font map of our own: the default one belongs to the thread that
  # asks for it, and threads move between tasks.
  e.fontMap = l.fontMapNew()
  if e.fontMap.isNil:
    raise newException(CatchableError,
      "pango_cairo_font_map_new failed")
  e.context = l.fontMapCreateContext(e.fontMap)
  # Until the app has the desktop's settings, GDK's defaults on X11
  # without a settings daemon: grayscale antialiasing, medium hinting.
  e.antialias = cairoAntialiasGray
  e.hintStyle = cairoHintStyleMedium
  e.applyOptions()
  e

## pangoFamily returns the family list of a style for Pango, where
## fontconfig knows the generic families, and system-ui is the desktop's
## interface font, ui, when the app knows it.
proc pangoFamily*(list, ui: string): string =
  var out0: seq[string]
  var systemUI = @["system-ui", "sans-serif"]
  if ui != "":
    systemUI = @[ui, "system-ui", "sans-serif"]
  for f in familyList(list):
    case generic(f)
    of "system-ui":
      out0.add systemUI
    of "":
      out0.add f
    else:
      out0.add generic(f)
  if out0.len == 0:
    out0 = systemUI
  out0.join(",")

proc desc*(e: PangoEngine, style: Style): pointer =
  let key = Style(family: style.family, size: style.fontSize(),
    weight: style.weight(), italic: style.italic)
  if e.descs.hasKey(key):
    return e.descs[key]
  let l = addr pangoLib
  if e.descs.len >= 256:
    for d in e.descs.values:
      l.descFree(d)
    e.descs.clear()
  let d = l.descNew()
  l.descSetFamily(d, cs(pangoFamily(key.family, e.uiFamily)))
  l.descSetWeight(d, int32(key.weight()))
  if key.italic:
    l.descSetStyle(d, pangoStyleItalic)
  else:
    l.descSetStyle(d, pangoStyleNormal)
  l.descSetAbsoluteSize(d, float64(key.fontSize()) * pangoScale)
  e.descs[key] = d
  d

method font*(e: PangoEngine, style: Style): Font =
  let font = pangoLib.fontMapLoadFont(e.fontMap, e.context,
    e.desc(style))
  if font.isNil:
    return nil
  let f = e.fontOf(font)
  pangoLib.gObjectUnref(font)
  f

## fontOf returns the Font of a PangoFont.
proc fontOf*(e: PangoEngine, font: pointer): Font =
  let key = cast[uint](font)
  if e.fonts.hasKey(key):
    return e.fonts[key]
  let l = addr pangoLib
  discard l.gObjectRef(font)
  let f = Font(native: key)
  let d = l.fontDescribeAbsolute(font)
  if not d.isNil:
    f.size = float32(l.descGetSize(d)) / pangoScale
    l.descFree(d)
  let m = l.fontGetMetrics(font, nil)
  if not m.isNil:
    f.ascent = float32(l.metricsGetAscent(m)) / pangoScale
    f.descent = float32(l.metricsGetDescent(m)) / pangoScale
    # Hinted metrics are whole pixels (DIPs), rounded up.
    f.underlineTop = float32(l.metricsGetUnderlinePos(m)) / pangoScale
    f.underlineThick =
      float32(l.metricsGetUnderlineThick(m)) / pangoScale
    f.strikeTop = float32(l.metricsGetStrikePos(m)) / pangoScale
    f.strikeThick = float32(l.metricsGetStrikeThick(m)) / pangoScale
    if not l.metricsGetHeight.isNil:
      f.lineGap = max(float32(l.metricsGetHeight(m)) / pangoScale -
        f.ascent - f.descent, 0)
    l.metricsUnref(m)
  e.fonts[key] = f
  f

## language returns the PangoLanguage of a tag, Pango's default one, of
## the user's locale, for "". Pango keeps them for good.
proc language*(e: PangoEngine, tag: string): pointer =
  if tag == "":
    return pangoLib.languageGetDefault()
  if e.languages.hasKey(tag):
    return e.languages[tag]
  let p = pangoLib.languageFromString(cs(tag))
  e.languages[tag] = p
  p

## attributes returns Pango's attributes of a style's letter spacing,
## OpenType features and language, over the whole text, and of its
## spans' styles, over their runes; nil without any.
proc attributes*(e: PangoEngine, style: Style,
    spans: seq[Span], text: seq[Rune]): pointer

method shape*(e: PangoEngine, text: openArray[Rune], style: Style,
    spans: openArray[Span], width: float32, rtl,
    wholeWords: bool): seq[shapedLine] =
  if text.len == 0:
    return @[]
  let l = addr pangoLib
  let (utf8, index) = utf8Text(text)
  var dir = int32(pangoDirLTR)
  if rtl:
    dir = pangoDirRTL
  l.contextSetBaseDir(e.context, dir)
  let layout = l.layoutNew(e.context)
  if layout.isNil:
    return @[]
  defer: l.gObjectUnref(layout)
  l.layoutSetAutoDir(layout, 0)
  l.layoutSetFontDescription(layout, e.desc(style))
  l.layoutSetText(layout, addr utf8[0], int32(utf8.len))
  let attrs = e.attributes(style, @spans, @text)
  if not attrs.isNil:
    l.layoutSetAttributes(layout, attrs)
    l.attrListUnref(attrs)
  if width > 0:
    # Round up to whole Pango units: truncating can make the box a
    # thousandth of a dip narrower than the text measured within it.
    # Pango also applies the letter spacing after the text's last glyph
    # when wrapping but trims it from the measured line, so the box
    # needs the spacing back to hold that line; the other engines keep
    # the trailing spacing in their measurements.
    var w = math.ceil(float64(width) * pangoScale)
    if style.letterSpacing > 0:
      w += math.round(float64(style.letterSpacing) * pangoScale)
    l.layoutSetWidth(layout, int32(min(w, float64(int32.high))))
    if wholeWords:
      l.layoutSetWrap(layout, pangoWrapWord)
    else:
      l.layoutSetWrap(layout, pangoWrapWordChar)
  proc at(b: int32): int =
    index[max(0, min(int(b), utf8.len))]
  let n = l.layoutGetLineCount(layout)
  var lines = newSeqOfCap[shapedLine](n)
  for i in 0 ..< n:
    let line = l.layoutGetLineReadonly(layout, i)
    if line.isNil:
      continue
    var sl = shapedLine(start: at(line.startIndex),
      `end`: at(line.startIndex + line.length))
    var x = int32(0)
    # The runs are in visual order, each with its glyphs.
    var r = line.runs
    while not r.isNil:
      let run = cast[ptr pangoGlyphItem](r.data)
      let item = run.item
      let gs = run.glyphs
      let f = e.fontOf(item.font)
      var sr = shapedRun(font: f, start: at(item.offset),
        `end`: at(item.offset + item.length))
      if gs.numGlyphs > 0:
        let infos = cast[ptr UncheckedArray[pangoGlyphInfo]](gs.glyphs)
        let clusters = cast[ptr UncheckedArray[int32]](gs.logClusters)
        sr.glyphs = newSeq[Glyph](gs.numGlyphs)
        for j in 0 ..< gs.numGlyphs:
          var g = infos[j]
          let cluster = at(item.offset + clusters[j])
          # Pango empties the space ending a wrapped line; the other
          # engines keep it, as editors need.
          if g.glyph == pangoGlyphEmpty and cluster < text.len and
              isWhiteSpace(text[cluster]):
            let (glyph, width) = e.space(item.font, text[cluster])
            g.glyph = glyph
            g.width = width
          sr.glyphs[j] = Glyph(
            font: f, id: g.glyph,
            x: float32(x + g.xOffset) / pangoScale,
            y: float32(g.yOffset) / pangoScale,
            advance: float32(g.width) / pangoScale,
            cluster: cluster, rtl: (item.level and 1) != 0)
          x += g.width
      sl.runs.add sr
      r = r.next
    lines.add sl
  lines

proc attributes*(e: PangoEngine, style: Style, spans: seq[Span],
    text: seq[Rune]): pointer =
  let l = addr pangoLib
  var list: pointer
  # add inserts an attribute over bytes from to to, or the whole text
  # when to is 0.
  proc add(attr: pointer, `from`, to: int) =
    if attr.isNil:
      return
    if list.isNil:
      list = l.attrListNew()
    if to > 0:
      # PangoAttribute: start_index 8, end_index 12.
      cast[ptr uint32](cast[uint](attr) + 8)[] = uint32(`from`)
      cast[ptr uint32](cast[uint](attr) + 12)[] = uint32(to)
    l.attrListInsert(list, attr)
  proc featureAttr(list0: string): pointer =
    let fs = features(list0)
    if fs.len == 0 or l.attrFontFeaturesNew.isNil:
      return nil
    # HarfBuzz's syntax, which Pango hands over.
    var b: string
    for i, f in fs:
      if i > 0:
        b.add ','
      for c in f.tag: b.add char(c)
      b.add '='
      b.add $f.value
    l.attrFontFeaturesNew(b.cstring)
  proc spacing(v: float32): pointer =
    if v == 0:
      return nil
    l.attrLetterSpacingNew(
      int32(math.round(float64(v) * pangoScale)))
  add(spacing(style.letterSpacing), 0, 0)
  add(featureAttr(style.features), 0, 0)
  if style.lang != "":
    add(l.attrLanguageNew(e.language(style.lang)), 0, 0)
  let runs = langRuns(text, style.lang, spans)
  if spans.len == 0 and runs.len == 0:
    return list
  # The byte each rune starts at.
  var at = newSeq[int](text.len + 1)
  for i, r in text:
    at[i + 1] = at[i] + toUTF8(r).len
  var `from` = 0
  for sp in spans:
    let to = max(`from`, min(sp.`end`, text.len))
    let (b0, b1) = (at[`from`], at[to])
    let start = `from`
    `from` = to
    if b1 == b0:
      continue
    if sp.family != "":
      add(l.attrFamilyNew(cs(pangoFamily(sp.family, e.uiFamily))),
        b0, b1)
    if sp.size > 0:
      add(l.attrSizeAbsoluteNew(
        int32(math.round(float64(sp.size) * pangoScale))), b0, b1)
    if sp.weight > 0:
      add(l.attrWeightNew(int32(min(sp.weight, 999))), b0, b1)
    if sp.italic:
      add(l.attrStyleNew(pangoStyleItalic), b0, b1)
    add(spacing(sp.letterSpacing), b0, b1)
    add(featureAttr(sp.features), b0, b1)
    if sp.objectWidth > 0:
      # Each rune an inline object: a shape of its size standing on
      # the baseline, in its own attribute.
      var box = pangoRectangle(
        y: -int32(math.round(float64(sp.objectHeight) * pangoScale)),
        width: int32(math.round(float64(sp.objectWidth) * pangoScale)),
        height: int32(math.round(float64(sp.objectHeight) *
          pangoScale)))
      for k in start ..< to:
        add(l.attrShapeNew(addr box, addr box), at[k], at[k + 1])
  # The runs in other languages, over the whole text's: an attribute
  # added later over a range wins.
  for r in runs:
    add(l.attrLanguageNew(e.language(r.lang)), at[r.start], at[r.`end`])
  list

## space returns the glyph and advance, in Pango units, of a whitespace
## rune in a font, from HarfBuzz as Pango shapes it.
proc space*(e: PangoEngine, font: pointer, r: Rune):
    tuple[glyph: uint32, advance: int32] =
  let l = addr pangoLib
  if l.fontGetHBFont.isNil or l.hbNominalGlyph.isNil or
      l.hbGlyphHAdvance.isNil:
    return (pangoGlyphEmpty, 0)
  let hb = l.fontGetHBFont(font)
  var glyph: uint32
  if hb.isNil or l.hbNominalGlyph(hb, int32(r), addr glyph) == 0:
    return (pangoGlyphEmpty, 0)
  (glyph, l.hbGlyphHAdvance(hb, glyph))

## scaledFont returns the cairo font of f at scale pixels per DIP, with
## the context's options, but grayscale antialiasing instead of subpixel
## unless subpixel.
proc scaledFont*(e: PangoEngine, f: Font, scale: float32,
    subpixel: bool): pointer =
  let key = scaledKey(font: f, scale: scale, subpixel: subpixel)
  if e.scaled.hasKey(key):
    return e.scaled[key]
  let l = addr pangoLib
  if e.scaled.len >= 256:
    for sf in e.scaled.values:
      l.cairoScaledFontDestroy(sf)
    e.scaled.clear()
  let src = l.fontGetScaledFont(cast[pointer](f.native))
  if src.isNil:
    return nil
  var m: cairoMatrix
  l.cairoScaledFontMatrix(src, addr m)
  let s = float64(scale)
  m.xx *= s; m.yx *= s; m.xy *= s; m.yy *= s
  var identity = cairoMatrix(xx: 1, yy: 1)
  let opts = l.cairoFontOptionsCreate()
  l.cairoScaledFontOptions(src, opts)
  if not subpixel and e.antialias == cairoAntialiasSubpixel:
    l.cairoFontOptionsAntialias(opts, cairoAntialiasGray)
  let sf = l.cairoScaledFontCreate(l.cairoScaledFontFace(src), addr m,
    addr identity, opts)
  l.cairoFontOptionsDestroy(opts)
  if sf.isNil or l.cairoScaledFontStatus(sf) != cairoStatusSuccess:
    return nil
  e.scaled[key] = sf
  sf

## textParams leaves coverage as it is: cairo blends glyphs in sRGB
## space, as renderers do, with subpixel antialiasing where the
## desktop's settings ask for it.
method textParams*(e: PangoEngine): tuple[p: scene.TextParams, subpixel: bool] =
  (scene.TextParams(), e.antialias == cairoAntialiasSubpixel)

## positions puts glyphs on whole pixels, as GTK does: Pango rounds
## their positions, and labels sit on whole pixels.
method positions*(e: PangoEngine, f: Font, scale: float32,
    subpixel: bool): tuple[n: int, round: bool] = (1, false)

## decorate places underlines and strikethroughs as GTK draws a label's
## (PangoRenderer): at the positions and thicknesses of the run's font,
## whole pixels, from the label's baseline, an underline along the ink
## and advances of the run, a strikethrough along its ink.
method decorate*(e: PangoEngine, r: decoRange): seq[Stroke] =
  let s = r.scale
  let base = e.baseline((r.y + r.line.baseline) * s)
  let gs = r.line.glyphs
  var i = r.i
  while i < r.j:
    var j = i + 1
    while j < r.j and gs[j].font == gs[i].font:
      inc j
    let f = gs[i].font
    if not f.isNil:
      var ink0 = float32.high
      var ink1 = -float32.high
      for g in gs[i ..< j]:
        let (a, b, ok) = e.ink(f, g.id)
        if ok:
          ink0 = min(ink0, g.x + a)
          ink1 = max(ink1, g.x + b)
      # The left and right of the advances of glyphs [i, j).
      var x0 = float32.high
      var x1 = float32.low
      for k in i ..< j:
        x0 = min(x0, gs[k].x)
        x1 = max(x1, gs[k].x + gs[k].advance)
      var top = f.strikeTop
      var thick = f.strikeThick
      if r.d == Underline:
        top = f.underlineTop
        thick = f.underlineThick
        x0 = min(x0, ink0)
        x1 = max(x1, ink1)
      else:
        if ink0 <= ink1:
          x0 = ink0
          x1 = ink1
        else:
          i = j
          continue
      let st = Stroke(x0: (r.x + x0) * s, x1: (r.x + x1) * s,
        top: base - top * s, bottom: base - top * s + thick * s)
      # Runs whose lines meet make one, as PangoRenderer draws them.
      if result.len > 0 and result[^1].top == st.top and
          result[^1].bottom == st.bottom:
        result[^1].x1 = max(result[^1].x1, st.x1)
      else:
        result.add st
    i = j

## join: cairo adds the coverage of a run's glyphs before compositing
## it.
method join*(e: PangoEngine): bool = true

## ink returns how far left and right of its origin a glyph's ink
## reaches, in DIPs.
proc ink*(e: PangoEngine, f: Font, id: uint32):
    tuple[a, b: float32, ok: bool] =
  if id == pangoGlyphEmpty or (id and pangoGlyphUnknown) != 0:
    return (0, 0, false)
  var inkR, logical: pangoRectangle
  pangoLib.fontGetGlyphExtents(cast[pointer](f.native), id,
    addr inkR, addr logical)
  if inkR.width <= 0:
    return (0, 0, false)
  (float32(inkR.x) / pangoScale,
    float32(inkR.x + inkR.width) / pangoScale, true)

## baseline is the whole pixel at or above y, as a GTK label's.
method baseline*(e: PangoEngine, y: float32): float32 =
  float32(math.floor(float64(y) + 1e-3))

method glyph*(e: PangoEngine, f: Font, id: uint32, scale, dx: float32,
    shade: Shade, subpixel: bool): bitmap =
  # Pango's empty glyphs, and the boxes it draws for missing ones, are
  # not the font's.
  if id == pangoGlyphEmpty or (id and pangoGlyphUnknown) != 0:
    return bitmap()
  let b = e.draw(f, id, scale, dx, false)
  if b.color or b.pix.len == 0 or not subpixel or
      e.antialias != cairoAntialiasSubpixel:
    return b
  e.draw(f, id, scale, dx, true)

## draw rasterizes a glyph with cairo: with subpixel antialiasing if
## subpixel, else in grayscale, or in color for color fonts.
proc draw*(e: PangoEngine, f: Font, id: uint32, scale, dx: float32,
    subpixel: bool): bitmap =
  let sf = e.scaledFont(f, scale, subpixel)
  if sf.isNil:
    return bitmap()
  let l = addr pangoLib
  var g = cairoGlyph(index: uint64(id))
  var ext: cairoTextExtents
  l.cairoScaledFontExtents(sf, addr g, 1, addr ext)
  if ext.width <= 0 or ext.height <= 0:
    return bitmap()
  # The LCD filter spreads subpixel glyphs a pixel further.
  var pad = 1
  if subpixel:
    pad = 2
  let left = int(math.floor(ext.xBearing + float64(dx))) - pad
  let top = int(math.floor(ext.yBearing)) - pad
  let right = int(math.ceil(ext.xBearing + ext.width +
    float64(dx))) + pad
  let bottom = int(math.ceil(ext.yBearing + ext.height)) + pad
  let (w, h) = (right - left, bottom - top)
  if w > 2048 or h > 2048:
    return bitmap()
  let surface = l.cairoImageSurfaceCreate(cairoFormatARGB32,
    int32(w), int32(h))
  defer: l.cairoSurfaceDestroy(surface)
  let cr = l.cairoCreate(surface)
  l.cairoSetScaledFont(cr, sf)
  l.cairoSetSourceRGBA(cr, 1, 1, 1, 1)
  g.x = float64(dx) - float64(left)
  g.y = -float64(top)
  l.cairoShowGlyphs(cr, addr g, 1)
  l.cairoDestroy(cr)
  l.cairoSurfaceFlush(surface)
  let data = l.cairoImageSurfaceData(surface)
  let stride = int(l.cairoImageSurfaceStride(surface))
  if data.isNil:
    return bitmap()
  if subpixel:
    # White glyphs with subpixel antialiasing: the coverage of each
    # subpixel in R, G and B (B, G, R in memory).
    var b = bitmap(left: left, top: top, w: w, h: h,
      pix: newSeq[byte](4 * w * h), subpixel: true)
    for y in 0 ..< h:
      for x in 0 ..< w:
        let q = y * stride + 4 * x
        let p = 4 * (y * w + x)
        b.pix[p] = data[q + 2]
        b.pix[p + 1] = data[q + 1]
        b.pix[p + 2] = data[q]
        b.pix[p + 3] = uint8(
          (uint16(data[q]) + uint16(data[q + 1]) +
            uint16(data[q + 2]) + 1) div 3)
    return b
  # White glyphs of a plain font come out gray: B, G, R and A (in
  # memory order) are the same, and the alpha is the coverage. Others
  # are colored.
  var color = false
  block scan:
    for y in 0 ..< h:
      let row = y * stride
      for x in countup(0, 4 * w - 4, 4):
        let a = data[row + x + 3]
        if data[row + x] != a or data[row + x + 1] != a or
            data[row + x + 2] != a:
          color = true
          break scan
  var b = bitmap(left: left, top: top, w: w, h: h, color: color)
  if color:
    b.pix = newSeq[byte](4 * w * h)
    for y in 0 ..< h:
      for x in 0 ..< w:
        let q = y * stride + 4 * x
        let p = 4 * (y * w + x)
        b.pix[p] = data[q + 2]
        b.pix[p + 1] = data[q + 1]
        b.pix[p + 2] = data[q]
        b.pix[p + 3] = data[q + 3]
    return b
  b.pix = newSeq[byte](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      b.pix[y * w + x] = data[y * stride + 4 * x + 3]
  b

## families lists the app's families and the font map's, the monospaced
## ones when mono, as fontconfig knows them, without the generic
## families Pango adds (Sans, Serif, Monospace, System-ui), which are
## aliases rather than fonts. The font map's hold the app's under their
## own names.
method families*(e: PangoEngine, mono: bool):
    tuple[app, system: seq[string]] =
  var app, system: seq[string]
  let l = addr pangoLib
  var arr: pointer
  var n: int32
  l.fontMapListFamilies(e.fontMap, addr arr, addr n)
  if not arr.isNil:
    defer: l.gFree(arr)
    var fixed = initTable[string, bool]()
      # whether each family is monospaced, by lowercased name
    let fams = cast[ptr UncheckedArray[pointer]](arr)
    for i in 0 ..< n:
      let name = goStr0(l.fontFamilyGetName(fams[i]))
      case name.toLower()
      of "", "sans", "serif", "monospace", "system-ui":
        continue
      else: discard
      let isMono = l.fontFamilyIsMonospace(fams[i])
      fixed[name.toLower()] = isMono
      if not mono or isMono:
        system.add name
    for name in e.names:
      if not mono or
          fixed.getOrDefault(e.appFamily.getOrDefault(
            name.toLower()).toLower()):
        app.add name
  (app, system)

## register adds a font file to fontconfig's fonts for the app, from
## the user's cache directory, and an alias for family.
method register*(e: PangoEngine, data: openArray[byte],
    family: string) =
  let l = addr pangoLib
  if l.fcConfigAppFontAddFile.isNil or l.fontMapConfigChanged.isNil:
    raise newException(ValueError,
      "mynim: adding fonts needs fontconfig and PangoFT2")
  let sum = $secureHash(cast[string](data))
  var dir = getCacheDir()
  if dir == "":
    dir = getTempDir()
  dir = dir / "mynim" / "fonts"
  try:
    createDir(dir)
  except CatchableError as ex:
    raise newException(ValueError, "mynim: cannot add font: " &
      ex.msg)
  let path = dir / sum[0 ..< 32] & ".font"
  if not fileExists(path):
    let tmp = path & ".tmp"
    try:
      writeFile(tmp, cast[string](@data))
      moveFile(tmp, path)
    except CatchableError as ex:
      raise newException(ValueError, "mynim: cannot add font: " &
        ex.msg)
  let config = l.fcConfigGetCurrent()
  if not e.registered.getOrDefault(path):
    if l.fcConfigAppFontAddFile(config, cs(path)) == 0:
      raise newException(ValueError,
        "mynim: cannot add font: not a font fontconfig reads")
    e.registered[path] = true
  let names = fontFamilies(config, path)
  if family != "":
    if names.len == 0:
      raise newException(ValueError,
        "mynim: cannot add font: no family name")
    if names[0].toLower() != family.toLower():
      let xml = "<?xml version=\"1.0\"?>" &
        "<!DOCTYPE fontconfig SYSTEM \"fonts.dtd\"><fontconfig>" &
        "<alias binding=\"same\"><family>" & xmlEscape(family) &
        "</family><prefer><family>" & xmlEscape(names[0]) &
        "</family></prefer></alias></fontconfig>"
      if l.fcConfigParseFromMemory.isNil or
          l.fcConfigParseFromMemory(config, cs(xml), 1) == 0:
        raise newException(ValueError,
          "mynim: cannot add font under another family name")
    e.appFamily[family.toLower()] = names[0]
    e.names.add family
  for name in names:
    e.appFamily[name.toLower()] = name
    e.names.add name
  l.fontMapConfigChanged(e.fontMap)
  # Fonts and descriptions found before may resolve differently now.
  for d in e.descs.values:
    l.descFree(d)
  e.descs.clear()

## fontFamilies returns the families of the app's fonts from a file.
proc fontFamilies*(config: pointer, path: string): seq[string] =
  let l = addr pangoLib
  if l.fcConfigGetFonts.isNil or l.fcPatternGetString.isNil:
    return @[]
  let set = l.fcConfigGetFonts(config, fcSetApplication)
  if set.isNil or set.nfont <= 0:
    return @[]
  let pats = cast[ptr UncheckedArray[pointer]](set.fonts)
  for i in 0 ..< set.nfont:
    var file, family: pointer
    if l.fcPatternGetString(pats[i], "file", 0, addr file) !=
        fcResultMatch or goStr0(file) != path:
      continue
    if l.fcPatternGetString(pats[i], "family", 0, addr family) ==
        fcResultMatch:
      result.add goStr0(family)

method fontCount*(e: PangoEngine): int = e.fonts.len

## forgetFonts lets go of the Pango and cairo fonts of the Fonts made
## so far.
method forgetFonts*(e: PangoEngine) =
  let l = addr pangoLib
  for sf in e.scaled.values:
    l.cairoScaledFontDestroy(sf)
  e.scaled.clear()
  for f in e.fonts.values:
    l.gObjectUnref(cast[pointer](f.native))
  e.fonts.clear()
