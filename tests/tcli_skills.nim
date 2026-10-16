import std/[assertions, os, strutils, tempfiles]
import ../src/cmd/skills

proc testInstallSkills() =
  let temporary = createTempDir("mynim-skills-", "")
  defer: removeDir(temporary)

  let project = temporary / "project"
  let skillDir = project / ".agents" / "skills" / "mynim-maintenance"
  createDir(skillDir / "agents")
  writeFile(skillDir / "SKILL.md", "old bundled skill")
  writeFile(skillDir / "custom.md", "keep this file")
  createDir(project / ".agents" / "skills" / "my-custom-skill")
  writeFile(project / ".agents" / "skills" / "my-custom-skill" / "SKILL.md",
    "keep this skill")

  doAssert runInstallSkills(@[project]) == 0
  let installed = readFile(skillDir / "SKILL.md")
  doAssert installed.contains("name: mynim-maintenance")
  doAssert installed.contains("ui.newTester")
  doAssert readFile(skillDir / "custom.md") == "keep this file"
  doAssert readFile(project / ".agents" / "skills" / "my-custom-skill" /
    "SKILL.md") == "keep this skill"
  doAssert fileExists(skillDir / "agents" / "openai.yaml")

  doAssert runInstallSkills(@[temporary / "missing"]) == 1
  doAssert runInstallSkills(@[project, project]) == 2
  doAssert runInstallSkills(@["--help"]) == 0

testInstallSkills()
