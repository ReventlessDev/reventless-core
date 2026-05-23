---
title: Writing Slash Commands
sidebar_position: 3
---

# Writing Slash Commands

Commands are Claude Code-specific slash commands invoked with `/command-name`. They live in `.claude/commands/`.

## Format

```markdown
---
description: What this command does (shown in command list)
argument-hint: parameter-type (helps users understand expected args)
allowed-tools: Bash, Write, Read, Edit, Glob, Grep, AskUserQuestion
---

# Command Title

Instructions for the AI when this command is invoked.
```

### Frontmatter Fields

| Field | Required | Purpose |
|-------|----------|---------|
| `description` | Yes | Shown in command list, used for discovery |
| `argument-hint` | No | Hint for what argument to pass (e.g., `component-type`) |
| `allowed-tools` | No | Restrict which tools the command can use |

## Naming Convention

File name becomes the command name:

```
reventless-new.md → /reventless-new
reventless-add.md → /reventless-add
```

## Best Practices

1. **Structured workflow** — break the command into numbered steps
2. **Reference skills** — commands can invoke skills for detailed knowledge
3. **Build verification** — always end with a build/test step
4. **User confirmation** — ask before generating large amounts of code
