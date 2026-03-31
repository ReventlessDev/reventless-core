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

Skills are automatically available when working in a Reventless project — they live in `.claude/skills/` at the repo root.

For projects outside the reventless-core repo:

```
/plugin marketplace add ReventlessDev/reventless-core
/plugin install reventless-skills
```

### Other Assistants

Skills in `.claude/skills/` are cross-discovered by Cursor and GitHub Copilot automatically. For Codex CLI, symlink or copy to `.agents/skills/`.

## MCP Integration

When a Reventless application is running (via `node src/Main.res.mjs`), the built-in MCP server exposes:

- **Tools** — one per command (auto-generated from sury schemas)
- **Resources** — one per read model / view slice (single-item + list)
- **Event History** — paginated event replay per entity

Claude Code connects automatically via the plugin's MCP configuration (ports 3001/3002).
