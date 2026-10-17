import std/[assertions, os, tempfiles]
import ../src/cmd/i18n_check

proc writeProject(dir: string; source, translation: string) =
  createDir(dir / "locales")
  writeFile(dir / "mygo.json",
    "{\"i18n\": {\"dir\": \"locales\", \"source\": \"en\"}}\n")
  writeFile(dir / "locales" / "en.json", source)
  if translation.len > 0:
    writeFile(dir / "locales" / "de.json", translation)

proc testCatalogCheck() =
  let temporary = createTempDir("mynim-i18n-", "")
  defer: removeDir(temporary)
  let project = temporary / "project with spaces"
  let source = """{
  "@@locale": "en",
  "hello": "Hello, {name}!",
  "textChoice": "{thing}",
  "files": "{count, plural, one {# file} other {# files}}",
  "@files": {"description": "A file count.", "placeholders": {"count": {"type": "int"}}},
  "who": "{gender, select, female {She} other {They}} replied.",
  "offset": "{count, plural, offset:1 =0 {Nobody} =1 {{host} and one other} other {{host} and # others}}",
  "rank": "{n, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}",
  "quoted": "'{escaped}' and {name}",
  "price": "{amount, number, ::currency/EUR} on {day, date, short} at {day, time, short}"
}"""
  let translation = """{
  "@@locale": "de",
  "hello": "Hallo, {name}!",
  "textChoice": "{thing, select, other {Text}}",
  "files": "{count, plural, one {# Datei} other {# Dateien}}",
  "who": "{gender, select, female {Sie} other {Sie}} antwortete.",
  "offset": "{count, plural, offset:1 =0 {Niemand} =1 {{host} und eine weitere Person} other {{host} und # weitere}}",
  "rank": "{n, selectordinal, one {#.} two {#.} few {#.} other {#.}}",
  "quoted": "'{escaped}' und {name}",
  "price": "{amount, number, ::currency/EUR} am {day, date, short} um {day, time, short}"
}"""
  writeProject(project, source, translation)
  doAssert runI18n(@["check", project]) == 0

  writeFile(project / "locales" / "de.json", """{
  "hello": "Hallo, {person}!",
  "files": "{count, plural, one {# Datei} other {# Dateien}}",
  "who": "{gender, select, female {Sie} other {Sie}}"
}""")
  doAssert runI18n(@["check", project]) == 1

proc testCatalogErrorsAndWarnings() =
  let temporary = createTempDir("mynim-i18n-errors-", "")
  defer: removeDir(temporary)
  let project = temporary / "project"
  let source = """{
  "hello": "Hello, {name}!",
  "files": "{count, plural, one {# file} other {# files}}"
}"""
  writeProject(project, source, """{"hello": "Hallo, {name}!"}""")
  doAssert runI18n(@["check", project]) == 0 # Missing messages warn.

  writeFile(project / "locales" / "de.json", """{
  "hello": "Hallo, {name}!",
  "extra": "Extra"
}""")
  doAssert runI18n(@["check", project]) == 1

  writeFile(project / "locales" / "en.json", """{
  "files": "{count, plural, one {# file} other {# files}}",
  "@files": {"placeholders": {"count": {"type": "String"}}}
}""")
  writeFile(project / "locales" / "de.json", """{
  "files": "{count, plural, one {# Datei} other {# Dateien}}"
}""")
  doAssert runI18n(@["check", project]) == 1

  writeFile(project / "locales" / "en.json", """{
  "dup_name": "One",
  "dupName": "Two",
  "In": "Reserved"
}""")
  writeFile(project / "locales" / "de.json", "{}")
  doAssert runI18n(@["check", project]) == 1

  writeFile(project / "locales" / "en.json", """{
  "files": "{count, plural, one {# file}}"
}""")
  doAssert runI18n(@["check", project]) == 1

  writeFile(project / "locales" / "en.json", """{
  "same": "One",
  "same": "Two"
}""")
  doAssert runI18n(@["check", project]) == 1

  writeFile(project / "locales" / "en.json", """{"hello": "Hi {count}"}""")
  writeFile(project / "locales" / "de.json", """{
  "hello": "{count, plural, one {eins}}"
}""")
  doAssert runI18n(@["check", project]) == 1

proc testPluralCategoriesAndFrameworkOverrides() =
  let temporary = createTempDir("mynim-i18n-framework-", "")
  defer: removeDir(temporary)
  let project = temporary / "project"
  let source = """{
  "files": "{n, plural, other {# files}}",
  "rank": "{n, selectordinal, other {#th}}",
  "mygo.clipboardRead": "Clipboard access",
  "mygo.removeToken": "Remove {token}",
  "mygo.appName": "App name",
  "mygo.appDescription": "App description"
}"""
  let translation = """{
  "files": "{n, plural, few {# files} other {# files}}",
  "rank": "{n, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}",
  "mygo.clipboardRead": "Zwischenablage",
  "mygo.removeToken": "Entferne {token}",
  "mygo.appName": "Anwendungsname",
  "mygo.appDescription": "Anwendungsbeschreibung"
}"""
  writeProject(project, source, translation)
  doAssert runI18n(@["check", project]) == 0

  writeFile(project / "locales" / "en.json", """{
  "mygo.notInTheFramework": "Unknown message",
  "hello": "Hello"
}""")
  writeFile(project / "locales" / "de.json", """{
  "mygo.notInTheFramework": "Unknown message",
  "hello": "Hallo"
}""")
  doAssert runI18n(@["check", project]) == 1

  writeFile(project / "locales" / "en.json", source)
  writeFile(project / "locales" / "de.json", """{
  "mygo.notInTheFramework": "Unknown message"
}""")
  doAssert runI18n(@["check", project]) == 1

  writeFile(project / "locales" / "de.json", """{
  "mygo.removeToken": "Entferne {token, number}"
}""")
  doAssert runI18n(@["check", project]) == 1

  writeFile(project / "locales" / "de.json", """{
  "mygo.removeToken": "Entferne {person}"
}""")
  doAssert runI18n(@["check", project]) == 1

proc testLocaleRules() =
  let temporary = createTempDir("mynim-i18n-locales-", "")
  defer: removeDir(temporary)
  let project = temporary / "project"
  writeProject(project, "{}", "")
  writeFile(project / "locales" / "ar-XB.json", "{}")
  doAssert runI18n(@["check", project]) == 1

  writeFile(project / "mygo.json",
    "{\"i18n\": {\"dir\": \"../locales\"}}\n")
  doAssert runI18n(@["check", project]) == 1

proc testCliErrors() =
  let temporary = createTempDir("mynim-i18n-cli-", "")
  defer: removeDir(temporary)
  doAssert runI18n(@["--help"]) == 0
  doAssert runI18n(@[]) == 1
  doAssert runI18n(@["unknown"]) == 2
  doAssert runI18n(@["check", "-unknown"]) == 2
  doAssert runI18n(@["check", temporary, temporary]) == 2
  doAssert runI18n(@["check", temporary]) == 1

testCatalogCheck()
testCatalogErrorsAndWarnings()
testPluralCategoriesAndFrameworkOverrides()
testLocaleRules()
testCliErrors()
