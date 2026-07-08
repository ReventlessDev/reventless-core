# Harden runtime AppSync schema update against transient clobber

Scope: prevent the runtime `mkUpdateApiSchema` path from overwriting the live
AppSync DomainApi schema with an incomplete SDL during plugin lifecycle churn,
which orphans every field-attached resolver and surfaces as
`NotFoundException: Type not found` on `pulumi refresh`.

Status: implemented (A + D + **deploy-time repair**, see below) on `alpha`. Local
build clean; reventless-core (396) and reventless-aws (104) test suites green.
**Alpha deploy verification still pending** — keep this plan here until the
multi-stack redeploy check below passes, then move to `docs/plans/done/`.

## Problem

`mkUpdateApiSchema` (in
`reventless/reventless-aws/src/adapter/Runtime/AdminEventCollectorEntryPoint.mjs:365-384`)
re-stitches the live AppSync schema on every plugin lifecycle event by scanning
the Plugin RM for rows whose `status` contains "Connected" and concatenating
their `apiSchemaFragment` values. Any moment when the scan returns zero (or
fewer) Connected rows produces an SDL missing those plugins' fragments — and
`startSchemaCreation` overwrites the live schema with that incomplete SDL,
orphaning every field-attached resolver.

Observed in alpha (2026-05-20): the DomainApi (`wbbmwqjunzdohdbtuxa6aadvua`)
`Mutation`/`Query` types contained only the admin-base `Platform_*` fields —
zero `Catalog_*`/`Ordering_*` — while both the deploy-schema entries
(`PluginSchemaPersistence:deploy-schema:Catalog|Ordering`) and the Plugin RM
Connected rows (`Catalog@1.0.0-alpha.50`, `Ordering@1.0.0-alpha.50`) still held
the full 98-field fragments. The data sources were intact; only the live schema
was clobbered.

The clobber surfaces as `NotFoundException: Type not found` on `pulumi refresh`.
Commit `5961503a1` softened this by adding `"Type not found"` to
`AppSync_Resolver_Retrying.isAlreadyDeletedError` — but that is only a healing
path (refresh reports drift, next `up` recreates resolvers). It does not stop
the clobber from recurring.

## Failure modes (concrete)

1. **Redeploy transition window** — a new plugin version starts before the old
   one finishes Disconnect; or a `DoDisconnectPlugin` event fires while no
   replacement Connected row exists yet.
2. **All-plugins-Disconnected window** — during multi-stack redeploys, a brief
   moment when every plugin row is Disconnected → scan returns 0 fragments →
   schema collapses to admin-base only (the state observed in alpha).
3. **DynamoDB scan eventual consistency** — `queryEngine.scan` does not set
   `ConsistentRead`, so a freshly-projected Connected row may not be visible to
   the next scan within the same poll cycle.
4. **Source-of-truth divergence** — deploy-time
   (`PluginSchemaPersistence:deploy-schema:*`) and runtime (Plugin RM Connected
   rows) are different sources; the runtime path can produce a strictly weaker
   schema than what was just deployed.

## Hardening options

| # | Tactic | Impact | Risk |
|---|---|---|---|
| A | Read fragments from `PluginSchemaPersistence` instead of Plugin RM | Eliminates transition-window clobber | Loses ability to track Connect/Disconnect for schema visibility |
| B | Make `mkUpdateApiSchema` strictly additive (merge with current live SDL, never drop types) | Prevents shrinkage; downgrades become explicit | Stale fields persist when a plugin is intentionally removed |
| C | Latest-version-per-plugin selection (regardless of status), Connected preferred | Survives transitions; minor staleness during uninstall | Requires version-aware row filtering |
| D | Circuit breaker: abort `updateAppSyncSchema` if new SDL drops > N% of currently-live root-type fields | Catches catastrophic clobbers at the doorstep | Adds a GetSchema call per update; threshold tuning |
| E | Skip runtime schema push entirely; rely on deploy-time only | Simplest; removes a whole failure class | Loses dynamic plugin install/uninstall (if that is a real feature) |
| F | Use `ConsistentRead` on the Plugin RM scan | Closes the eventual-consistency window | Doubles RCU cost; does not help with transition windows |

## Recommended approach (combined): A + D

- **A (primary):** switch the runtime source to `PluginSchemaPersistence`.
  Plugin fragments are stored there at deploy time, not at lifecycle time, which
  aligns the runtime stitch with the deploy-time stitch. Lifecycle events still
  trigger the re-stitch (so deploy-schema additions / removals propagate), but
  the stitch reads the durable source rather than the lifecycle-volatile Plugin
  RM.
- **D (defense-in-depth):** before calling `startSchemaCreation`, fetch the
  current schema and compare root-type field counts; if the new SDL has < 50% of
  the currently-live `Mutation`/`Query` fields, skip the push and log loudly.
  Catches anything A misses.

Skip B and C — they create stale-fragment lifecycle problems. Skip E unless we
confirm dynamic install/uninstall is not supported. F is too narrow on its own.

## Implementation steps (as built)

Deviations from the original sketch are called out inline. Net change touched 4
source files + 1 test; `PluginExtensionPoint_Plugin.res` needed **no** change
(the lifecycle handlers already call `Spec.updateApiSchema(queryEngine)`; only
the function injected as `updateApiSchema` in the `.mjs` entry point changed).

1. **A (source switch)** — `mkUpdateApiSchema`
   (`AdminEventCollectorEntryPoint.mjs`) now reads plugin fragments from the
   dedicated `PluginSchemaPersistence` table via
   `collectDeploySchemaFragments(tableName)` — a `begins_with(id,
   "deploy-schema:")` scan that wraps each row's `fragment` attribute as
   `{encoded, protocol:"graphql"}`, mirroring the deploy-time hook. The
   `begins_with("deploy-schema:")` prefix excludes the platform
   (`deploy-schema-platform:`) and hash (`deploy-schema-hash:`) rows (hyphen at
   that position).
   - *Deviation from A.1/A.3:* no env-var feature flag and no
     `mkUpdateApiSchemaFromPluginRm` rename. Instead the old Plugin RM
     Connected-row scan is kept inline as a **self-healing fallback**, taken
     only when `pluginSchemaPersistenceTableName === "NOT_AVAILABLE"` (older
     platform stack). Zero-config, can't drift out of sync, and the table is
     always present on stacks built by current `Platform.res`.
2. **Config threading + IAM** — added
   `pluginSchemaPersistenceTableName: option<Pulumi.Output.t<string>>` to
   `PluginRuntime_Builder.adminConfig` + `registerConfig`, serialized into
   `HANDLER_CONFIG`; `Platform.res` passes `pluginSchemaPersistenceTable.name`
   at the `registerConfig` call site. Two IAM grants added to the admin
   EventCollector role (both load-bearing — without them the new path degrades
   silently): `appsync:GetIntrospectionSchema` (alongside the existing
   StartSchemaCreation/GetSchemaCreationStatus) for the circuit breaker, and a
   `dynamodb:Scan` RolePolicy on the PluginSchemaPersistence table (the existing
   Scan grant only covered the Plugin RM table).
3. **A.2 pagination** — the runtime `scanByTableName`
   (`HandlerFactoryHelpers.mjs`) **already** loops on `LastEvaluatedKey`, so no
   runtime fix was needed. Back-ported the paginated loop
   (`scanAllDeploySchemaItems`) to the deploy-time hook
   (`Platform.res`, formerly `:709`), which previously did a single
   `ScanCommand.send`.
4. **D.1 circuit breaker** — pure helpers `countRootTypeFields(~sdl, ~typeName)`
   and `isCatastrophicSchemaShrink(~currentSdl, ~newSdl, ~threshold)` added to
   `GraphQL_Stitcher.res` (consumed by the entry point). Before
   `updateAppSyncSchema`, the entry point introspects the live schema
   (`GetIntrospectionSchemaCommand`, format `SDL`) and aborts the push when the
   new SDL drops below `threshold` × the live Mutation+Query field count.
   Threshold via `RUNTIME_SCHEMA_SHRINK_THRESHOLD` (default 0.5). An empty/
   unintrospectable current schema → no baseline → push proceeds (first deploy).
   - *Update (2026-07-08, `54f58a10f`):* `isCatastrophicSchemaShrink` and
     `countRootTypeFields` were made **identity-based** by the sibling plan
     [`appsync-split-admin-schema-clobber.md`](appsync-split-admin-schema-clobber.md):
     the guard now diffs field-name SETS across `Mutation + Query + Subscription`
     (was a Mutation+Query cardinality ratio), never rejects a purely additive
     push, and still falls back to the threshold on genuine drops. The runtime
     entry point imports the shared compiled function, so this strengthens the
     Fix D guard here with no `.mjs` change.
5. **D.2 metric** — `emitShrinkRejectionMetric` writes a CloudWatch EMF log line
   (`Reventless/Runtime` namespace, `SchemaShrinkRejected` count, `ApiId`
   dimension). No PutMetricData call, SDK dep, or extra IAM needed — Lambda logs
   shaped as EMF are auto-extracted into metrics.
6. **Test** — `tests/api/GraphQL_StitcherTest.res` (10 cases) covers the
   all-disconnected collapse (8 → 3 fields rejected), an intentional small
   removal (8 → 7 allowed), first-push (empty current allowed), unchanged
   re-push, `@aws_auth` directive-line handling, and counting edge cases.
7. **Cleanup** — none deferred. The RM fallback is permanent defensive code, not
   a flag to remove.

## Follow-up: deploy-time repair of an already-clobbered schema (2026-05-20)

A + D stop *future* runtime clobbers but do **not repair** a schema that is
already clobbered — and the alpha DomainApi was already in that state. The
`pulumi up` after the layer bump still failed: every `Subscription.onOrdering_*`
resolver errored `NotFoundException: Type not found` on `pulumi refresh`
(`ResourceProviderService.read`), and `up` could not recover.

Two layered reasons it could not self-heal:

1. **Stale dynamic-provider serialization.** Pulumi's dynamic `read`
   deserializes the provider from `props["__provider"]` in stack state
   (`@pulumi/pulumi/cmd/dynamic-provider/index.js` `getProvider`/`read`), so
   resolvers created before `5961503a1` run their *pre-fix* `read`/`delete` that
   re-throw on "Type not found". This is tolerated — CI guards `pulumi refresh`
   with `|| echo "::warning::…"` — but it means refresh alone never heals.
2. **THE BLOCKER — deploy-time hash short-circuit never re-pushed.**
   `preResolversSchemaHook` (`Platform.res`) skipped the schema push when
   `storedHash == currentHash`. The stored `deploy-schema-hash:<apiId>` row
   records what the *deploy* last pushed; the *runtime* clobber overwrote the
   live schema without touching that row (the runtime path only reads
   `deploy-schema:` rows). So the next deploy saw a matching hash and skipped the
   repair, leaving the clobbered schema in place — and with the live schema still
   missing the plugin types, even a fresh `CreateResolver` fails "Type not found".

**Fix (drift-aware hash short-circuit).** When the stored hash matches, the hook
now introspects the live schema (`AppSync_Adapter.getIntrospectionSdl`, a new
`GetIntrospectionSchemaCommand` wrapper) and compares root-type
(Mutation+Query+Subscription) field counts via
`GraphQL_Stitcher.countRootTypeFields`. It skips only when the live schema is
confirmed intact (`live >= expected`); if the live schema has shrunk — or cannot
be introspected *despite* a stored hash (a real failure, not a first deploy) — it
forces the push. Because plugin resolvers are registered *inside*
`schemaPushed.apply(...)` (`Plugin_Builder.res:452`), the repair completes during
program evaluation before any resolver CRUD runs, so delete-before-replace and
create both hit the healed schema in the same `up`.

Files: `AppSync_Adapter.res` (+`getIntrospectionSdl`), `Platform.res`
(drift-aware skip). No layer rebuild needed — `preResolversSchemaHook` runs in
the deploy-time Pulumi program, so the next CI deploy picks it up from source.

*Operational note:* this self-heals on the next `pulumi up`. To unblock a stuck
stack *before* merging, deleting the `deploy-schema-hash:<apiId>` DynamoDB row in
the PluginSchemaPersistence table forces the existing code to re-push once.

## Out of scope

- Restructuring the Phase 4 `dcbEventLog` schema. Already shipping; data-layer
  back-compat was rejected in favor of wipe-on-alpha.
- Per-plugin AppSync APIs (split-API mode already supported, not the focus).
- Dynamic plugin install/uninstall semantics — flag for separate discussion if
  option E is reconsidered.

## Verification

- Deploy alpha with both fixes.
- Force a multi-stack concurrent redeploy (Catalog + Ordering simultaneously).
- Confirm the DomainApi schema retains both plugins' fields throughout.
- Confirm the circuit breaker logs but does not fire on a normal deploy.
