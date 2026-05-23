---
title: AI-Assisted Development
sidebar_position: 1
---

# AI-Assisted Development

Reventless includes a set of **AI skills** that help you build event-sourced applications faster. Describe your domain, and an AI assistant generates complete, compilable Reventless code — plugins, aggregates, read models, DCB slices, extension points, tests, and configuration.

## What's Included

| Skill | Purpose |
|-------|---------|
| **reventless-app** | Generate complete applications from domain requirements |
| **event-sourcing-cqrs** | Learn ES/CQRS concepts in the context of Reventless |
| **event-modeling** | Translate Event Modeling diagrams into Reventless components |
| **rescript** | ReScript v12 patterns and pitfall avoidance |
| **reventless-testing** | Testing patterns (BehaviorTest DSL, E2E, mocks) |
| **reventless-aws** | AWS deployment patterns (DynamoDB, Lambda, Pulumi) |
| **reventless-context** | Pre-implementation discovery for existing codebases |

Plus 3 slash commands (`/reventless-new`, `/reventless-add`, `/reventless-validate`) and 2 review agents (`architecture-reviewer`, `code-reviewer`).

## Supported AI Assistants

The skills use the portable [SKILL.md open standard](https://agentskills.io/specification) and work across:

| Assistant | Support Level |
|-----------|--------------|
| **Claude Code** | Full (skills + MCP + agents + commands + hooks) |
| **Codex CLI** | Skills (auto-discovered from `.agents/skills/`) |
| **Cursor** | Skills (cross-reads `.claude/skills/`) |
| **GitHub Copilot** | Skills (cross-reads `.claude/skills/`) |
| **Gemini CLI** | Content portable via GEMINI.md (manual) |

## Installation

### Claude Code (recommended)

Skills are automatically available when working in a Reventless project — they live in `.claude/skills/` at the repo root and are picked up by Claude Code automatically.

For projects outside the reventless-core repo, copy or symlink the `.claude/` folder from reventless-core into your project root:

```bash
# Symlink (stays up-to-date when reventless-core is updated)
ln -s /path/to/reventless-core/.claude .claude

# Or copy (standalone snapshot)
cp -r /path/to/reventless-core/.claude .claude
```

### Other Assistants

Skills in `.claude/skills/` are cross-discovered by Cursor and GitHub Copilot automatically. For Codex CLI, symlink or copy to `.agents/skills/`.

## MCP Integration

Reventless includes a built-in MCP server that gives Claude Code native access to your application's commands and read models while it is running.

See [MCP Server](/framework/internals/mcp) for details on what the server exposes and how to configure it.
