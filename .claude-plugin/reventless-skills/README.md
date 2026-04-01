# Reventless Skills

AI skills for building event-sourced applications with the [Reventless](https://reventless.dev) framework.

## Quick Start

Skills are automatically available when working in a Reventless project. For external projects:

```
/plugin marketplace add ReventlessDev/reventless-core
/plugin install reventless-skills
```

## What's Included

### 7 Skills

| Skill | Purpose |
|-------|---------|
| `reventless-app` | Generate complete apps from domain requirements |
| `rescript` | ReScript v12 patterns, sury-ppx, pitfalls |
| `event-sourcing-cqrs` | ES/CQRS concepts for Reventless developers |
| `event-modeling` | Event Modeling methodology → Reventless components |
| `reventless-testing` | BehaviorTest DSL, E2E patterns, Jest ESM gotchas |
| `reventless-aws` | AWS deployment (DynamoDB, Lambda, Pulumi) |
| `reventless-context` | Pre-implementation discovery for codebases |

### 3 Commands

| Command | Purpose |
|---------|---------|
| `/reventless-new` | Scaffold a new platform from domain requirements |
| `/reventless-add` | Add a component to an existing plugin |
| `/reventless-validate` | Validate project structure and conventions |

### 2 Agents

| Agent | Purpose |
|-------|---------|
| `architecture-reviewer` | Review aggregate/DCB choices, plugin boundaries |
| `code-reviewer` | Review ReScript conventions, annotations, pitfalls |

### MCP Integration

Connects to the running Reventless MCP server (ports 3001/3002) for live access to commands, queries, and event history.

## Works With

| Assistant | Support |
|-----------|---------|
| Claude Code | Full (skills + MCP + agents + commands + hooks) |
| Codex CLI | Skills |
| Cursor | Skills (cross-reads `.claude/skills/`) |
| GitHub Copilot | Skills (cross-reads `.claude/skills/`) |

## Documentation

- [AI-Assisted Development Guide](https://reventless.dev/app/ai-assisted)
- [AI Skills Development Guide](https://reventless.dev/framework/ai-skills)
