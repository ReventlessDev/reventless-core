# `Platform_Plugins` admin connection returns null — internal RM rows violate the non-null schema

**Status:** Implemented 2026-07-08 (fix (A) — read-side filter; write-side (B) was already in place)
**Area:** admin API / plugin-lifecycle read model / QueryDb resolver generation

## Resolution (2026-07-08)

Investigation showed the write-side separation of option **(B)** already exists: a
dedicated `PluginSchemaPersistence` DynamoDB table is provisioned and exported
(`pluginSchemaPersistenceTableName`), and `preResolversSchemaHook` prefers it over
the Plugin RM table for all `deploy-schema:*` / `deploy-schema-hash:*` writes
(`reventless/reventless-aws/src/Platform.res:796`, `:1710`). So *fresh* deploys no
longer co-host internal rows in the Plugin RM table. The live 2026-07-08 leak came
from **legacy** rows (incl. the historical `plugin-info:*` prefix, which no longer
appears anywhere in source) left in platforms deployed before that table existed —
and, more fundamentally, from the **read side having no defense at all**.

Applied option **(A)** as the durable read-side guard so the connection is correct
regardless of what the physical table contains (legacy rows, future internal
prefixes, or a fallback write):

- `AppSync_Resolver_Functions.listAllItemsConnection` gained an optional
  `~requireAttribute` param. When set, the generated Scan emits an always-on
  `attribute_exists(#<attr>)` FilterExpression clause (ANDed with any client
  filters). (`rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res`)
- `QueryDbResolvers_AppSync` passes `~requireAttribute="name"` **only** for the
  Plugins admin RM, via the testable helper `internalRowRequiredAttr` — real plugin
  rows always carry `name`; internal bookkeeping rows never do. The predicate is
  prefix-agnostic, so a new internal prefix can't regress the connection.
  (`reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res`)
- Regression test:
  `reventless/reventless-aws/tests/QueryDbResolvers_AppSyncTest.res` asserts the
  Plugins path emits `attribute_exists(#name)` and that ordinary read models are
  unchanged (no filter).

Only the Connection Scan is filtered — the single-`Platform_Plugin(id)` GetItem and
`Platform_PluginsByIds` BatchGetItem take client-supplied real ids and are not leak
vectors (a client never asks for an internal id). Deploy verification pends the next
CI push (code-complete, all local builds warning-free, tests green).

## Symptom

The host-shell **Plugins** admin page renders "No data" even when plugins are
deployed, connected, and their UI (nav pages via `Platform_ComponentDefinitions`
/ `Platform_UIFragments`) renders fine. Auth is not the cause: all three fields
carry the same `@aws_auth(cognito_groups: ["Admin"])` and the signed-in user is
in `Admin`; the two component/fragment fields populate, only `Platform_Plugins`
comes back empty.

## Root cause (confirmed by live inspection)

The generated `Platform_Plugins` resolver does an **unfiltered DynamoDB `Scan`**
of the plugin read-model table and maps every returned item to a
`Platform_PluginEdge`. But that physical table holds two kinds of rows:

1. **Real plugin-registry entries** from `PluginsProjection`
   (`src/plugin/lifecycle/PluginsProjection.res`) — keyed by plugin name, with
   `name` / `version` / `status` / `extensions` / `extensionPoints` populated.
2. **Internal bookkeeping records** written into the *same* table by the schema
   stitch — ids prefixed `deploy-schema:<name>` (see
   `reventless/reventless-aws/src/Platform.res:603`, and the comment at
   `Platform.res:745` "writes its fragment to the Plugin RM table (keyed
   `deploy-schema:<name>`)") and `plugin-info:<name>`. These rows have
   `name` / `version` / `status` = **null**.

The admin schema is non-null all the way down:

```
type Platform_Plugin implements Node { name: String!  status: Platform_PluginStatus!  version: String! ... }
type Platform_PluginConnection { edges: [Platform_PluginEdge!]! ... }
Platform_Plugins(...): Platform_PluginConnection!
```

So when the scan returns an internal row, `name: String!` resolves to null →
non-null violation → the error propagates up through `Platform_PluginEdge!` →
`[Platform_PluginEdge!]!` → `Platform_PluginConnection!` and **nulls the entire
connection**. Result: even valid plugins never reach the client, and the page
shows "No data".

### Live evidence (hybrid example platform API)

An unfiltered scan of the Plugins RM table returned 8 rows — 3 valid
(`Platform`, `Ordering`, `Catalog`) and 5 internal (`plugin-info:*`,
`deploy-schema:*`) with null `name`/`version`/`status`. The `Platform_Plugins`
resolver's request handler is a plain `{ operation: 'Scan', limit, nextToken }`
with no `filter` unless `search`/`ids` args are supplied — so the internal rows
are always included.

## Reproduce

1. Deploy the hybrid example platform + a couple of plugins.
2. Sign in to the host shell as an `Admin` user; open the Plugins page.
3. Observe "No data" despite deployed plugins. Confirm by scanning the Plugins
   RM DynamoDB table: real entries coexist with `plugin-info:` / `deploy-schema:`
   rows whose `name` is absent.

## Fix — two directions (pick one; (B) is the cleaner long-term)

**(A) Filter the read at the resolver.** Add a filter to the `Platform_Plugins`
(and `Platform_PluginsByIds` / `Platform_Plugin`) scan/get so internal rows are
excluded — e.g. `attribute_exists(#name)` or
`NOT begins_with(#id, :pluginInfoPrefix) AND NOT begins_with(#id, :deploySchemaPrefix)`.
Generated in the QueryDb backend (`reventless/reventless-aws/src/adapter/QueryDb/QueryDbBackend.res`)
/ `Platform.res` resolver wiring. Cheapest change; leaves the mixed-table design
in place. Risk: any future internal prefix must be added to the filter or the
bug regresses.

**(B) Separate the physical stores.** Stop writing `deploy-schema:` /
`plugin-info:` records into the table that backs the `Platform_Plugins`
connection. Give the schema-stitch/persistence fragments their own table (a
dedicated `PluginSchemaPersistence`-style store already exists — route these
rows there instead of the Plugins RM), so the connection scan only ever sees
plugin-registry entries. Removes the class of bug rather than one instance;
larger change (write paths + any readers of those co-located rows).

## Open questions

- Are the `deploy-schema:` / `plugin-info:` rows in the Plugins RM table
  intentional (shared physical table, prefix-partitioned) or an accidental leak
  from the schema stitch? Answering this decides (A) vs (B).
- Do any consumers rely on reading those internal rows *through* the Plugins RM
  table (vs. their dedicated persistence table)? If not, (B) is unambiguously
  correct.

## Also seen (separate follow-ups, not this bug)

- A deployed plugin can show `status: Disconnected` in the same read model — a
  reconcile/lifecycle question independent of the null-row serialization bug.

## Acceptance

- Plugins admin page lists all deployed plugins for an `Admin` user with no
  internal rows leaking into the connection.
- A read-model containing `deploy-schema:` / `plugin-info:` records returns a
  clean `Platform_PluginConnection` (no non-null violation).
- Regression test: projection/read fixture that includes an internal row asserts
  `Platform_Plugins` still returns only the real entries.
