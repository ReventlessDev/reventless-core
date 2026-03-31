---
title: Writing Agents
sidebar_position: 4
---

# Writing Agents

Agents are Claude Code subagents — specialized reviewers or workers that compose multiple skills. They live in `.claude/agents/`.

## Format

```yaml
---
name: agent-name
description: >-
  What this agent does and when to use it.
tools: Read, Grep, Glob
skills:
  - skill-a
  - skill-b
  - skill-c
---
```

### Frontmatter Fields

| Field | Required | Purpose |
|-------|----------|---------|
| `name` | Yes | Agent identifier |
| `description` | Yes | When to use this agent |
| `tools` | No | Which tools the agent can use |
| `skills` | No | Skills loaded into the agent's context |

## Body Content

The body contains the agent's instructions:

1. **Role** — what the agent is expert in
2. **Review checklist** — specific items to check
3. **Output format** — how to report findings

## Skill Composition

Agents compose multiple skills. Skills listed in `skills:` are loaded into the agent's context, giving it access to all reference files:

```yaml
skills:
  - event-sourcing-cqrs   # ES/CQRS concepts
  - event-modeling         # EM methodology
  - reventless-app         # Component patterns
```

Skills from other installed plugins also work — they're resolved globally by name.

## Reventless Agents

| Agent | Purpose | Skills |
|-------|---------|--------|
| `architecture-reviewer` | Reviews aggregate/DCB choices, plugin boundaries, EP design | event-sourcing-cqrs, event-modeling, reventless-app |
| `code-reviewer` | Reviews ReScript code, annotations, naming, pitfalls | rescript, reventless-testing, reventless-context |
