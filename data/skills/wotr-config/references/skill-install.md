# Skill Installation (wotr-config only)

After generating the `.wotr/config` file, offer to install the wotr-config skill into the project so Claude Code can help update the config in future conversations (e.g., "add a redis resource", "update the switch hook").

## Instructions

1. Check if `.claude/skills/wotr-config/SKILL.md` already exists in the project. If it does, skip this step entirely — the skill is already installed.

2. Ask the user:
   > "Would you like me to install the wotr-config skill into this project? This lets you ask Claude Code to update your `.wotr/config` anytime — for example, 'add a redis resource' or 'update the switch hook'."

3. If the user agrees, copy the skill files from the gem data directory. The source files are the same ones loaded into this system prompt — the SKILL.md and all reference files. Write them to `.claude/skills/wotr-config/` in the project:
   - `.claude/skills/wotr-config/SKILL.md`
   - `.claude/skills/wotr-config/references/config-reference.md`
   - `.claude/skills/wotr-config/references/icon-guide.md`
   - `.claude/skills/wotr-config/references/resource-patterns.md`

   The content of each file is already available in this system prompt (they were appended as reference materials). Write them as-is.

4. Do NOT install this file (`skill-install.md`) — it is only relevant during `wotr init` and not needed for ongoing skill usage.
