---
title: Extending the framework
sidebar_position: 9
---

# Extending the framework

This is the capstone of the framework-internals track. By now you've followed the
ordered path — [messages](./messages), [serialization](./serialization),
[resources](./resources), [runtime](./runtime), [pulumi](./pulumi), and the
[component-structure pattern](./component-structure-pattern). This page maps the
three most common kinds of extension onto that knowledge.

Reventless is built so that the **provider-agnostic core** (`reventless-spec`,
`reventless-core`) is separate from **provider implementations** (`reventless-aws`,
`reventless-local`). Almost every extension is "add another implementation of
an existing interface" rather than "change the core".

## 1. A new component type

A component (Aggregate, ReadModel, Task, …) follows the
[component-structure pattern](./component-structure-pattern):

- `Component.res` — type definitions and `outputs` (see
  [why output types live in reventless-spec](./resources.md#why-output-types-live-in-reventless-spec)).
- `Component_Builder.res` — the `Make` functor that wires it.
- `Component_Adapter.res` (optional) — the provider-agnostic interface for any
  infrastructure it needs.
- `Component_Operations.res` / `Component_Callback.res` (optional) — runtime
  logic and handlers.

Then implement the adapter once per provider (under `reventless-aws/src/adapter/`
and `reventless-local/src/adapter/`), and surface the component on the
`Platform.T` module type so plugins can call `Platform.<Component>.Make(...)`. The
plugin generator picks it up from a folder convention — see the
[component reference](/app/component-overview) for the existing set.

## 2. A new adapter or cloud provider

The core never imports a cloud SDK; it depends on adapter **interfaces**. To add a
provider you implement those interfaces for the new backend:

- EventLog / DcbEventLog storage
- CommandTopic / EventTopic channels
- QueryDb (read store) and its query/resolver surface
- Task buckets, Scheduler, Heartbeat, and the API (GraphQL) integration

The AWS adapter (`reventless-aws`) and the in-memory adapter
(`reventless-local`) are the two reference implementations to copy from.
Deploy-time concerns live in `src/adapter/` (Pulumi resources); runtime concerns
live in `src/adapter/Runtime/`. See [resources](./resources) and [pulumi](./pulumi)
for how deploy-time and runtime are kept separate.

Design explorations for other providers (what each interface maps to, and where
the gaps are) live in the repo's analysis notes:

- [GCP cloud provider analysis](https://github.com/ReventlessDev/reventless-core/blob/main/docs/analysis/gcp-cloud-provider-analysis.md)
- [Azure cloud provider analysis](https://github.com/ReventlessDev/reventless-core/blob/main/docs/analysis/azure-cloud-provider-analysis.md)
- [Supabase local platform](https://github.com/ReventlessDev/reventless-core/blob/main/docs/analysis/supabase-local-platform.md)

## 3. A new API protocol or transport

The command/query surface is itself an adapter. To expose plugins over a protocol
other than the built-in GraphQL/AppSync path, or to add a new transport for
commands and events, follow:

- [API protocol integration](../api-protocol-integration) — adding a new API
  protocol on top of the command/query model.
- [Transport adapter guide](../transport-adapter-guide) — adding a new transport
  for moving messages between components.

## Principles to keep

- **Don't fork the core.** If you find yourself editing `reventless-core` to add a
  provider, the seam is probably an adapter interface that should be widened
  instead.
- **Keep deploy-time and runtime separate.** Pulumi resource creation and Lambda
  runtime code never mix — see [pulumi](./pulumi) and [runtime](./runtime).
- **Wrap infrastructure values in `Pulumi.Output.t`.** Never `option<Pulumi.Output.t<'a>>`,
  never `...->ignore` on outputs.
- **Serialize through the schema layer.** New message types use `@schema`; see
  [serialization](./serialization).
