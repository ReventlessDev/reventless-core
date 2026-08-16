---
title: What you provide, what you get
sidebar_label: What you provide, what you get
sidebar_position: 2
---

# What you provide, what you get

The contract is narrow on purpose: you describe the domain, the platform builds
the system around it.

```d2
direction: right

you: "What you write" {
  class: plugin-area

  specs: "Specs — commands, events, views" { class: spec }
  gwt: "Scenarios — Given / When / Then" { class: spec }
}

platform: "Reventless" {
  class: reventless-area

  derive: "Derives the system from the description" { class: adapter }
}

system: "What you get" {
  class: reventless-aws-area

  log: "Event log — the full history" { class: event-log }
  views: "Live views" { class: read model }
  api: "GraphQL and MCP APIs" { class: api }
  ui: "Generated user interface" { class: client }
  infra: "Cloud infrastructure" { class: aws-service }
}

you.specs -> platform.derive { class: command-flow }
you.gwt -> platform.derive { class: command-flow }
platform.derive -> system.log { class: event-flow }
platform.derive -> system.views { class: projection-flow }
platform.derive -> system.api { class: projection-flow }
platform.derive -> system.ui { class: projection-flow }
platform.derive -> system.infra { class: projection-flow }
```

## What you provide

| You write | What it says |
|---|---|
| **Commands** | What people (or other systems) can ask your application to do, and what information each request carries. |
| **Events** | The facts that result — what actually happened, in past tense, in your domain's own words. |
| **Decision rules** | For each command: given the history so far, is this allowed, and which events does it produce? |
| **Views** | What each screen or query needs, expressed as a projection over events. |
| **Scenarios** | Given/When/Then examples that pin the rules down — and run as the test suite. |
| **Boundaries** | Which parts of the application are grouped together, and where they connect to each other. |

That is the whole of it. There is no schema file to maintain alongside the
model, no API layer to write, no wiring between the pieces, and no infrastructure
definition to keep aligned with the code.

## What you get

| You get | What it means in practice |
|---|---|
| **A complete history** | Every state change stored as an immutable, ordered fact with its cause and actor. Nothing is overwritten, so nothing is lost. |
| **Live views** | Queryable state, maintained automatically as events arrive, and pushed to connected clients as it changes — no polling loop to write. |
| **A GraphQL API** | Every command and every view exposed as a typed endpoint, with authentication and per-command authorization applied. |
| **An MCP interface** | The same commands and views exposed to AI assistants, so an assistant can operate the running application through the same rules a person would. |
| **A working user interface** | Screens generated from the views and commands you defined — usable on day one, and replaceable with your own components where it matters. |
| **Deployed infrastructure** | The queues, tables, functions, permissions, and endpoints your application needs, provisioned in your own cloud account and kept in step with the model. |
| **A verified model** | Your scenarios run as automated tests, so a change that breaks a rule fails before it ships. |

## About the description itself

Specs are written in a small, declarative vocabulary — a list of commands, a list
of events with their fields, a decision per command, a projection per view. It
reads much like the domain notes you would write on a whiteboard, and the
compiler checks it: a view that reads a field no event produces, or a decision
that forgets a case, does not build.

That vocabulary is a detail of the platform, not a prerequisite for using it. In
practice most teams describe their domain in plain language and have an AI
assistant produce and maintain the specs, with the scenarios acting as the check
that the result is correct — see [How AI helps you build](./ai-assisted.md).

## Next

- [How AI helps you build](./ai-assisted.md)
- [Deployment: fast now, sovereign later](./deployment.md)
