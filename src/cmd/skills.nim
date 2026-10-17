## Install the maintenance guidance bundled with the CLI.

import std/os

const
  usageSkills = "Usage: nim-xplat install-skills [dir]\n" &
    "Install or refresh the bundled nim-xplat maintenance skill.\n"
  maintenanceSkill = staticRead(
    "templates/shared/.agents/skills/nim-xplat-maintenance/SKILL.md")
  agentMetadata = staticRead(
    "templates/shared/.agents/skills/nim-xplat-maintenance/agents/openai.yaml")

proc installBundledSkills*(dir: string) =
  let skillDir = dir / ".agents" / "skills" / "nim-xplat-maintenance"
  createDir(skillDir / "agents")
  writeFile(skillDir / "SKILL.md", maintenanceSkill)
  writeFile(skillDir / "agents" / "openai.yaml", agentMetadata)

proc runInstallSkills*(args: seq[string]): int =
  if args.len == 1 and args[0] in ["-h", "--help"]:
    stdout.write(usageSkills)
    return 0
  if args.len > 1:
    stderr.writeLine("nim-xplat install-skills: expected at most one project directory")
    stderr.write(usageSkills)
    return 2

  let dir = if args.len == 0: getCurrentDir() else: absolutePath(args[0])
  if not dirExists(dir):
    stderr.writeLine("nim-xplat install-skills: " & dir & " is not a directory")
    return 1
  try:
    installBundledSkills(dir)
    stdout.writeLine("Installed skills in " & (dir / ".agents" / "skills"))
    return 0
  except CatchableError as error:
    stderr.writeLine("nim-xplat install-skills: " & error.msg)
    return 1
