---
title: AI Skills Development
sidebar_position: 1
---

# AI Skills Development

The Reventless plugin (`reventless-skills`) packages AI skills, commands, agents, and rules as a Claude Code plugin. The skills themselves use the portable [SKILL.md open standard](https://agentskills.io/specification), making them usable across multiple AI assistants.

## Plugin Architecture

```
.claude/
├── skills/              # Portable SKILL.md files (work with any assistant)
│   ├── rescript/
│   ├── event-sourcing-cqrs/
│   ├── reventless-app/
│   ├── event-modeling/
│   ├── reventless-testing/
│   ├── reventless-aws/
│   └── reventless-context/
├── commands/            # Claude Code slash commands
│   ├── reventless-new.md
│   ├── reventless-add.md
│   └── reventless-validate.md
├── agents/              # Claude Code subagents
│   ├── architecture-reviewer.md
│   └── code-reviewer.md
├── rules/               # Behavioral guidelines
│   ├── conventions.md
│   ├── component-guidelines.md
│   └── app-developer.md
├── hooks/               # Lifecycle hooks
│   ├── hooks.json
│   └── SessionStart
├── .mcp.json            # MCP server connections
└── settings.json        # Plugin permissions
```

## Skill Dependency Graph

```
event-sourcing-cqrs ─────────────────┐
                                      │
event-modeling ──┐                    │
                 ├──→ reventless-app ─┤──→ rescript
                 │         │          │
                 │         ▼          │
                 │  reventless-testing│
                 │                    │
                 └──→ reventless-aws  │
                                      │
reventless-context ───────────────────┘
```

## Portability

| Asset | Portable? |
|-------|-----------|
| SKILL.md + references/ | Yes — works with Claude Code, Codex, Cursor, Copilot |
| Commands | Claude Code only |
| Agents | Claude Code only |
| Rules | Claude Code only (other tools have equivalents) |
| Hooks | Claude Code only |
| MCP config | Partial (MCP is open protocol, config format varies) |

## Distribution

The plugin is distributed via the GitHub marketplace pattern. The source lives in `.claude/` at the reventless-core repo root. The marketplace manifest is in `.claude-plugin/marketplace.json`.
