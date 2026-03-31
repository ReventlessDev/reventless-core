---
title: Testing Skills
sidebar_position: 5
---

# Testing Skills

## Verification Checklist

Before shipping a skill, verify:

1. **Frontmatter validity** — `name` and `description` are present and within limits
2. **Reference file existence** — every file mentioned in SKILL.md exists
3. **No tool-specific language** — no "Bash tool", "Read tool", "Agent tool" in skill body
4. **Activation test** — the skill triggers on relevant prompts
5. **Cross-assistant test** — verify the skill works in at least one non-Claude assistant

## Automated Checks

```bash
# Validate JSON config files
cat .claude-plugin/marketplace.json | python3 -m json.tool > /dev/null

# Check for Claude-specific tool names in skills
grep -rn "Bash tool\|Agent tool\|Read tool\|Write tool" .claude/skills/

# Verify all referenced files exist
for skill_dir in .claude/skills/*/; do
  grep "references/" "$skill_dir/SKILL.md" | grep -oE 'references/[a-z-]+\.md' | while read ref; do
    [ -f "$skill_dir$ref" ] || echo "MISSING: $skill_dir$ref"
  done
done
```

## Testing Activation

Start a new session (skills are discovered at session start), then test:

1. Ask a question that should trigger the skill
2. Verify the skill is loaded (check the system prompt for the skill description)
3. Verify reference files are accessible

## Cross-Assistant Testing

| Assistant | How to Test |
|-----------|-------------|
| **Cursor** | Open the project — `.claude/skills/` is cross-read automatically |
| **GitHub Copilot** | Open in VS Code with Copilot agent mode |
| **Codex CLI** | Copy skills to `.codex/skills/` or `.agents/skills/` |

## Using `/validate-skill`

If the `workshop` plugin is installed, use the AgentSkills spec validator:

```
/validate-skill .claude/skills/rescript
```
