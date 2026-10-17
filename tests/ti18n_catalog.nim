import std/[strutils, unittest]
import ../src/mynim/i18n as mygoI18n

proc appCatalog(): mygoI18n.Catalog =
  mygoI18n.newCatalog("en", [
    mygoI18n.catalogFile("en", """{
      "@@locale": "en",
      "hello": "Hello, {name}!",
      "@hello": {"description": "A greeting."},
      "color": "Color",
      "files": "{n, plural, one {# file} other {# files}}",
      "onlyEnglish": "Only in English",
      "broken": "Fine in English"
    }"""),
    mygoI18n.catalogFile("en-001", """{"color": "Colour"}"""),
    mygoI18n.catalogFile("de", """{
      "hello": "Hallo, {name}!",
      "files": "{n, plural, one {# Datei} other {# Dateien}}",
      "broken": "{kaputt"
    }"""),
    mygoI18n.catalogFile("zh-Hans", """{"hello": "你好，{name}！"}"""),
    mygoI18n.catalogFile("zh-Hant", """{"hello": "你好，{name}！", "color": "顏色"}"""),
    mygoI18n.catalogFile("pt", """{"color": "Cor"}"""),
    mygoI18n.catalogFile("pt-PT", """{"hello": "Olá, {name}!"}""")])

proc expectCatalogError(files: seq[mygoI18n.CatalogFile]; source, want: string) =
  var got = ""
  try:
    discard mygoI18n.newCatalog(source, files)
  except ValueError as error:
    got = error.msg
  check got.contains(want)

suite "i18n catalogs":
  test "validates source and locale file names":
    expectCatalogError(@[mygoI18n.catalogFile("en", "{}")], "", "not a language")
    expectCatalogError(@[mygoI18n.catalogFile("en", "{}")], "en-XA", "not a language")
    expectCatalogError(@[mygoI18n.catalogFile("de", "{}")], "en", "no en.json")
    expectCatalogError(@[mygoI18n.catalogFile("zh_CN", "{}"),
      mygoI18n.catalogFile("en", "{}")], "en", "canonical BCP 47")
    expectCatalogError(@[mygoI18n.catalogFile("en-XA", "{}"),
      mygoI18n.catalogFile("en", "{}")], "en", "pseudo locales")

  test "adds translations without replacing existing locales":
    let catalog = mygoI18n.newCatalog("en", [
      mygoI18n.catalogFile("en", """{"hello": "Hello"}""")])
    catalog.add([mygoI18n.catalogFile("fr", """{"hello": "Bonjour"}""")])
    check catalog.format("fr", "hello") == "Bonjour"
    check catalog.languages() == @["en", "fr"]
    var rejected = false
    try:
      catalog.add([mygoI18n.catalogFile("fr", "{}")])
    except ValueError:
      rejected = true
    check rejected

  test "lists catalogs and resolves CLDR parents, likely scripts, and source fallback":
    let catalog = appCatalog()
    check catalog.source() == "en"
    check catalog.namespace() == ""
    check catalog.languages() == @[
      "en", "de", "en-001", "pt", "pt-PT", "zh-Hans", "zh-Hant"]
    for (locale, key, want) in [
      ("en", "hello", "Hello, Ada!"),
      ("", "hello", "Hello, Ada!"),
      ("de", "hello", "Hallo, Ada!"),
      ("de-CH", "hello", "Hallo, Ada!"),
      ("de", "color", "Color"),
      ("de", "broken", "Fine in English"),
      ("en-AU", "color", "Colour"),
      ("en-GB", "hello", "Hello, Ada!"),
      ("en-US", "color", "Color"),
      ("zh-TW", "color", "顏色"),
      ("zh-Hant-HK", "color", "顏色"),
      ("zh-CN", "color", "Color"),
      ("zh", "hello", "你好，Ada！"),
      ("pt-AO", "hello", "Olá, Ada!"),
      ("pt-AO", "color", "Cor"),
      ("pt-BR", "hello", "Hello, Ada!"),
      ("fr", "hello", "Hello, Ada!"),
      ("C", "color", "Color"),
      ("de", "missing", "missing"),
      ("de", "files", "1 Datei"),
      ("fr", "files", "0 files")]:
      let got = catalog.format(locale, key,
        mygoI18n.formatArg("name", "Ada"), mygoI18n.formatArg("n", 1))
      if key == "files" and locale == "fr":
        check catalog.format(locale, key, mygoI18n.formatArg("n", 0)) == want
      else:
        check got == want

    let found = catalog.message("en-AU", "color")
    check found.found
    check found.language == "en-001"
    check found.message.source == "Colour"
    check not catalog.message("en", "absent").found

  test "formats source and app override messages for a library":
    let library = mygoI18n.newLibraryCatalog("en", "mygo", [
      mygoI18n.catalogFile("en", """{"cancel": "Cancel", "quitApp": "Quit {app}", "close": "Close"}"""),
      mygoI18n.catalogFile("zh-Hans", """{"cancel": "取消", "quitApp": "退出{app}"}"""),
      mygoI18n.catalogFile("zh-Hant", """{"cancel": "取消", "quitApp": "結束{app}"}""")])
    check library.format("zh-TW", "cancel") == "取消"
    check library.format("de", "cancel") == "Cancel"

    let app = mygoI18n.newCatalog("de", [
      mygoI18n.catalogFile("de", """{"title": "Titel", "mygo.cancel": "Abbrechen"}"""),
      mygoI18n.catalogFile("en", """{"title": "Title", "mygo.close": "Dismiss"}"""),
      mygoI18n.catalogFile("zh-Hans", """{"title": "标题", "mygo.quitApp": "退出 {app}"}"""),
      mygoI18n.catalogFile("zh-TW", """{"title": "標題"}""")])
    app.register()
    app.register()
    check mygoI18n.languages() == @["de", "en", "zh-Hans", "zh-TW"]
    check library.format("de", "cancel") == "Abbrechen"
    check library.format("de-AT", "cancel") == "Abbrechen"
    check library.format("en", "close") == "Dismiss"
    check library.format("en", "cancel") == "Cancel"
    check library.format("zh-Hans", "quitApp",
      mygoI18n.formatArg("app", "Notes")) == "退出 Notes"
    check library.format("zh-Hans", "cancel") == "取消"
    check library.format("zh-TW", "quitApp",
      mygoI18n.formatArg("app", "Notes")) == "結束Notes"
    check library.format("ja", "cancel") == "Abbrechen"
    check library.format("ja", "close") == "Dismiss"
    check library.format("ja", "quitApp",
      mygoI18n.formatArg("app", "Notes")) == "Quit Notes"
    check library.format("", "cancel") == "Abbrechen"
    check library.format("en-XA", "cancel") == "[Åƀƀŕéçĥéñ one]"
    check library.format("de", "missing") == "missing"

    var rejected = false
    try:
      library.register()
    except ValueError:
      rejected = true
    check rejected
