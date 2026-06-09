---
title: Framework Internals
draft: false
---

# Framework Internals

How the Reventless framework is structured and operates internally. Read the pages below in
order — each builds on the previous — then move on to
[Extending the framework](./extending-the-framework.md).

## Architectural patterns

Reventless leans on a few patterns throughout, for consistency, type safety, and provider
independence:

- **Component structure pattern** — every component is two required files
  (`Component.res` for types, `Component_Builder.res` for the construction functor) plus up to
  three optional ones (`_Adapter`, `_Operations`, `_Callback`). See
  [Component structure pattern](./component-structure-pattern.md).
- **First-class modules and functors** — components are parameterized over their specs and
  adapters, so the same builder works for any provider.
- **Adapter pattern** — infrastructure is injected through adapter interfaces; the core
  depends on no provider.
- **Deploy-time vs runtime separation** — `Pulumi.Output.t`-wrapped values keep deploy-time
  (infrastructure) and runtime (Lambda) concerns distinct.

## The ordered tour

1. [Messages](./messages.md) — how commands and events are shaped, correlated, and routed.
2. [Serialization](./serialization.md) — encoding/decoding with sury and the `@schema` PPX.
3. [Resources](./resources.md) — how infrastructure resources are modeled.
4. [Runtime & deployment](./runtime.md) — runtime environments and the Single/PerAggregate/Micro
   deployment strategies.
5. [Pulumi integration](./pulumi.md) — deploy-time vs runtime separation in depth.
6. [Component structure pattern](./component-structure-pattern.md) — the file pattern used by
   every component, walked through with EventLog.
7. [MCP](./mcp.md) — AI-native access via tools and resources.

Then: [**Extending the framework →**](./extending-the-framework.md) — add a new component or a
new provider adapter.

## Where the implementations live

- Framework core: `reventless/reventless-core/src/components/` (and `src/admin/` for the
  built-in Platform Admin components).
- Provider adapters: `reventless/reventless-aws/src/adapter/` and
  `reventless/reventless-local/src/adapter/`. See the
  [AWS adapter reference](/infrastructure/aws) for the concrete AWS mappings.

## Related

- [Component Overview](/app/component-overview) — high-level component architecture
- [ReScript Syntax](/app/rescript-syntax) — language features used throughout the framework
