---
title: Plugin configuration
sidebar_label: Plugin configuration
---

# Plugin configuration (`plugin.json`)

A plugin needs almost no configuration: the generator derives what it can from
the package and from what it finds in `src/`. What is left goes in an optional
`src/plugin.json`, read before every build.

The shipped example is one line:

```json
{"name": "Catalog"}
```

## Fields

| Field | Default | What it does |
|---|---|---|
| `name` | derived from the package name (`@scope/my-catalog` → `MyCatalog`) | The plugin's registered name. It appears in every GraphQL field prefix (`Catalog_AddProduct`), so changing it is a public API change. |
| `heartbeatInterval` | framework default | How often the plugin reports itself to the platform, in minutes. |
| `exclude` | none | Paths under `src/` the generator should skip when discovering components. |
| `runtime` | none | Per-component resource hints — see below. |

## Per-component runtime hints

Components share a handler per kind, and the shared handler is sized for the
most demanding component in it. When one component needs more memory or time
than its neighbours, say so here rather than raising the whole platform:

```json
{
  "name": "Catalog",
  "runtime": {
    "ImportProducts": {"memorySize": 1024, "timeout": 300}
  }
}
```

Keys are component names as they appear in `src/` (`ImportProducts`,
`PlaceOrder`, `Customers`). Both fields are optional; an omitted one falls
through to the per-kind default, and the higher of the hint and the default
wins. On the local platform these are accepted and ignored — there is no process
boundary to size.

For the deployment-wide knobs (the four command-handler flavours, reserved
concurrency, ephemeral storage, log retention) see the
[Lambda deployment guide](/infrastructure/lambda-deployment).

## Where the rest of the configuration lives

Configuration that is not the plugin's own belongs elsewhere on purpose:

- **Which platform you run on** is a functor argument at the composition root —
  see [Run and deploy](../local-development.md).
- **Deployment settings** (region, Cognito pool, custom domain, stack
  references) live in the Pulumi stack config of the `-aws` package, not in the
  plugin — see the [deployment guide](/infrastructure/deployment-guide).
- **Who counts as an operator** is `REVENTLESS_ELEVATED_GROUPS`, deliberately an
  environment setting rather than anything a plugin declares — see
  [Authorization](../authorization.md).
