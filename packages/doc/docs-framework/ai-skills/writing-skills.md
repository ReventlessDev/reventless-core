---
title: Writing Skills
sidebar_position: 2
---

# Writing Portable Skills

## SKILL.md Format

Each skill lives in its own directory with a `SKILL.md` file and optional `references/` subdirectory:

```
skills/my-skill/
├── SKILL.md
└── references/
    ├── topic-a.md
    └── topic-b.md
```

### Frontmatter (Required)

```yaml
---
name: my-skill-name
description: >-
  One to three sentences describing what the skill does and when to use it.
  This text is shown in the skills list and determines when the skill activates.
---
```

- **name:** lowercase, hyphens, max 64 characters
- **description:** max 1024 characters; used as the activation trigger

### Body Structure

```markdown
## Purpose
What this skill enables and who it's for.

## When to Use
Decision matrix: when this skill activates vs alternatives.

## Reference Files
Table of references/ files with purpose descriptions.

## Key Rules
Numbered rules the AI must follow when this skill is active.

## Related Skills
Cross-references to complementary skills.
```

## Writing for Portability

Skills should work across AI assistants. Follow these rules:

1. **No tool-specific names** — write "run this command" not "use the Bash tool"
2. **No tool-specific features** — keep agents, hooks, and commands in the plugin layer
3. **Generic file operations** — write "read this file" not "use the Read tool"
4. **Path references** — use relative paths from the project root

## Reference Files

Reference files contain the detailed knowledge loaded when the skill activates:

- **Code templates** — complete, compilable examples from the codebase
- **Pattern catalogs** — lookup tables mapping concepts to components
- **Decision guides** — flowcharts and criteria for architecture choices
- **Pitfall lists** — known issues with workarounds

Keep reference files focused — one topic per file. The AI loads them into context, so smaller files mean more relevant context.

## Activation Triggers

The `description` field determines when the skill activates. Be specific:

```yaml
# Good — specific triggers
description: >-
  ReScript v12 language patterns. Use when writing .res/.resi files,
  debugging compiler warnings, or working with sury-ppx serialization.

# Bad — too vague
description: >-
  Helps with coding.
```
