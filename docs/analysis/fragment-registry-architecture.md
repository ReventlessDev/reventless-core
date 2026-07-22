# Fragment Registries: API Schema vs UI — Architecture Analysis

**Status:** Analysis
**Date:** 2026-07-12
**Origin:** Session started from `docs/plans/schema-fragment-push-public-api.md` (expose the
cumulative schema-fragment push as a public API). The discussion escalated from "extract the
hook body" to a target architecture that models both fragment registries as event-sourced
platform components. This document records all findings; a follow-up plan should be derived
from § 9.

---

## 1. Current implementation of the cumulative schema push

The mechanism lives exclusively inside `reventless-aws` `Platform.res` `MakeWithConfig` as
the `preResolversSchemaHook` closure (`Platform.res:749–1091`). It is reachable only through
`makePlatform`/`deployPlugin` because it captures functor state:

- `currentDeployTarget` (`Domain | Platform`) — selects key prefix
  (`deploy-schema:` vs `deploy-schema-platform:`) and target API (`domainApi` vs
  `apiConfigRef.platformApi`).
- `platformStackRef` — resolves the persistence table via stack-ref reads with a
  `default`-object fallback (ESM single-export layout): prefer
  `pluginSchemaPersistenceTableName`, fall back to `pluginRmTableName` (legacy; new writes to
  the RM table leak rows through the `Platform_Plugins` AppSync Connection resolver).
- `Config.splitApi` / `Config.cloner` — base-fragment selection: Platform target → admin base
  (`AdminApi.baseFragment` + `injectAwsAuthAll`); Domain target → empty base in split mode,
  admin base in unified mode.

The hook body owns, in order, all under `AppSync_Adapter.withSchemaPushLock` (a
DynamoDB-keyed lease):

1. **Write row** `deploy-schema:<name>` with the plugin's encoded fragment.
2. **Paginated scan** of all rows with the prefix (1 MB `Scan` page limit → loop on
   `LastEvaluatedKey`; a partial scan would stitch a partial schema).
3. **Stitch** via `ReventlessCore.GraphQL_Stitcher.stitch` + `stampSharedIamTypes`.
4. **Hash skip** — `deploy-schema-hash:<apiId>` row records what the deploy last pushed.
5. **Drift detect/repair** — a runtime re-stitch can clobber the live schema without
   updating the hash, so a hash match alone never skips: introspect live SDL and require it
   to be a *superset* of expected root fields (`missingRootFields`, identity-aware, not a
   bare count — heals equal-cardinality field swaps).
6. **Catastrophic-shrink guard** — refuse a push whose SDL has fewer than
   `threshold × live` root fields (`DEPLOY_SCHEMA_SHRINK_THRESHOLD`, default 0.5): a
   concurrent peer's stale scan must not orphan live resolvers.
7. **`StartSchemaCreation` + wait ACTIVE**, then write the new hash.

Resolver creation is gated on this hook's returned Output
(`Plugin_Builder.res:584–587` — `schemaPushed` chains into the resource dependency tuple),
because AppSync `CreateResolver` on a field not in the schema fails with
`NotFoundException: No field named X`.

A separate, simpler push exists for the admin base schema:
`preAdminResolversSchemaHook` (`Platform.res:691–742`) — split mode pushes ONLY when the
PlatformApi is known (never falls back to domainApi; an admin-base push to the DomainApi
would wipe every plugin field — the alpha 2026-07-08 clobber).

## 2. What is generic vs AWS-specific in that mechanism

Already provider-agnostic (in `reventless-core` / `reventless-infra`):

| Concern | Building block |
|---|---|
| Stitch + drift + shrink math | `GraphQL_Stitcher` (`stitch`, `missingRootFields`, `isCatastrophicSchemaShrink`, `countRootTypeFields`) |
| Schema publication port | `ReventlessInfra.Api_Adapter.Provider.updateSchema(~api, ~baseFragment, ~pluginFragments)` — implemented by AppSync **and** graphql-yoga (local platform) |
| Admin base fragment | `ReventlessCore.AdminApi.baseFragment` |

AWS-specific: DynamoDB DocumentClient I/O (put/scan/get), `withSchemaPushLock`,
AppSync client calls (`startSchemaCreationRetrying`, `waitForSchemaActive`,
`getIntrospectionSdl`, `stampSharedIamTypes`), and the Pulumi stack-ref target resolution.

Stripped to a contract, the deploy-time store needs only five operations
(`saveFragment`, `listFragments(prefix)`, `readHash`, `writeHash`, `withLock`) — a
KV-with-lease port. The orchestration algorithm (write → list → stitch → hash-skip →
drift-repair → shrink-guard → push-under-lease) contains no AWS logic once store and sink
ops are injected, and can be promise-based (Pulumi-free): the AWS wrapper already resolves
`api.id` before the body runs.

`QueryDb.operations` was evaluated as the store port and rejected: no prefix-listing
operation, and the registry deliberately bypasses the event pipeline for deploy-time
read-your-own-write consistency.

## 3. How UI fragments actually flow (already event-sourced)

There is **no separate database** on the UI side. The flow is the standard component stack:

- Events on the Plugin aggregate: `UIFragmentRegistered`, `UIFragmentUpdated`,
  `UIFragmentDeregistered` — carried by the runtime connect handshake.
- Projection: `reventless-core/src/admin/UIFragmentRegistryProjection.res`
  (`Set`/`Update`/`Delete`).
- ReadModel: `UIFragmentRegistry` (`UIFragmentRegistryReadModelSpec.res`) — a normal QueryDb.
- Client query: `Platform_UIFragments`, with a shared SDL/encoder module
  (`Platform_UIFragmentsApi.res`) used byte-identically by the local-platform adapter and the
  AWS Lambda adapter (`Platform_UIFragments_Lambda.res`).

Composition is **lazy**: the host-shell queries the registry at render time and
module-federation-loads `remoteEntryUrl` on demand. The composite is never materialized;
adding one plugin's row cannot clobber another's UI.

## 4. How API fragments flow — the dual path

The `apiSchemaFragment` travels **twice**:

1. **Deploy time** — `preResolversSchemaHook` writes the `deploy-schema:<name>` row and
   pushes the stitched schema (§ 1). This is the path resolver creation depends on.
2. **Runtime** — the fragment also rides `pluginDefinition` in the connect handshake
   (`Plugin_Builder.res:751`) into the Plugin aggregate and the Plugins RM
   (`PluginsReadModelSpec.res:27`).

The runtime re-stitcher `mkUpdateApiSchema`
(`reventless-aws/src/adapter/Runtime/EventCollectorEntryPoint.mjs:504`) fires on
Connected/Disconnected events, stitches from the **deploy-scoped rows** (preferred) and
falls back to Connected Plugin RM fragments only when the persistence table is unavailable.
Comment at `:490` is explicit: the deploy rows are the durable source, NOT the
"lifecycle-volatile" Plugin RM. It applies its own shrink guard
(`RUNTIME_SCHEMA_SHRINK_THRESHOLD`).

## 5. API vs UI stitching — same pattern, opposite sink semantics

Both are instances of "per-plugin contribution → platform-wide registry → composed whole",
and both fragments ride the same `pluginDefinition` handshake (as do `pluginStructure`,
extension protocols, `dcbEventLog` — the Plugin lifecycle subsystem is the framework's
contribution registry).

The decisive difference is **where and when composition happens**:

| | API schema | UI |
|---|---|---|
| Composite | single materialized artifact (SDL) | never materialized — rows are the product |
| Sink | `StartSchemaCreation` **replaces the whole schema** | additive rows, queried lazily |
| Timing | deploy time, before resolvers | request/render time |
| Consistency need | read-your-own-write + mutual exclusion | eventual consistency fine |
| Failure mode | clobber peers' fields, orphan resolvers | stale menu entry |

Every hard part of the schema mechanism (lease, hash, drift repair, shrink guard,
deploy-time store) is a direct consequence of *replace-the-whole-artifact under concurrent
writers*. None of these concepts apply to the UI side. Conclusion: a unified
"FragmentRegistry" building block spanning both would share a name, not machinery. The UI
side already IS the desired abstraction (built from standard components).

## 6. Why the deploy-schema keyspace can't simply be an Aggregate/DCB slice (today)

Evaluated and answered precisely:

1. **Ordering inside the deploy transaction.** Resolvers are Pulumi resources created
   during the deploy and require their fields ACTIVE first; the push must complete
   synchronously within the run, with failures propagating into the deploy.
2. **Eventual consistency × destructive sink.** Commands are async/at-least-once and
   projections lag; stitching from a read model that doesn't yet contain the just-written
   fragment wipes the writer's own fields (or a racing peer's).
3. **Lifecycle mismatch.** Plugin RM rows are lifecycle-volatile; the live schema must be
   stable across version transitions and disconnects (§ 8).
4. **Platform bootstrap.** The admin schema push precedes any runtime existing at all.

General principle: event sourcing requires a running event-processing runtime; deploy time
is before/outside the runtime — mirrored by the framework's own `adapter/` (deploy-time) vs
`adapter/Runtime/` split.

**Correction discovered during the session:** the "bootstrap circularity" argument was
overstated for domain plugins. The true circularity is **deploy⇄connect** (a plugin's
handshake Lambdas are among the resources being created), not platform⇄plugin. A plugin
deploy CAN send a registration command to the **Platform API** (whose schema already
exists) — the `@@reventless.systemCallable` mechanism (deploy-time SigV4/IAM caller on
StateChangeSlice mutations) was built for exactly this actor. Only the platform's own admin
schema push is irreducibly deploy-time.

## 7. Finding: retirement-cleanup asymmetry (candidate bug/backlog)

UI fragments have full lifecycle handling (`UIFragmentDeregistered` → `Delete(id)`).
The `deploy-schema:<name>` rows have **no retirement cleanup path found**: rows are
name-keyed (version upgrades overwrite), but a plugin retired *without a successor* leaves
its fragment stitched into the API indefinitely. `manageSubscriptions` handles
disconnect/retire for SNS/SQS wiring but never deletes deploy-schema rows. Needs
confirmation + its own backlog entry regardless of any refactor.

## 8. Target architecture (user-proposed, refined in-session)

Model both registries as event-sourced platform components, split out of the Plugin
aggregate; the Plugin aggregate keeps lifecycle only (Connected, VersionSuperseded,
Retired) and stops carrying fragment payloads.

```
ApiFragmentRegistry   StateChangeSlice: RegisterApiFragment / DeregisterApiFragment
                      → ApiFragmentRegistered / ApiFragmentDeregistered
                      (@@reventless.systemCallable — the DEPLOY is the caller)
                      StateViewSlice: current fragment per plugin name
                      AutomationSlice: on ApiFragment* events → stitch + push via
                      Api_Adapter.Provider.updateSchema (single writer)

UiFragmentRegistry    same shape; commands/events driven by the runtime connect
                      handshake (essentially today's flow, moved off Plugin aggregate)
```

**Key refinement — the two registries have different state machines:**

| | API fragment registry | UI fragment registry |
|---|---|---|
| Transitions driven by | **deploy / destroy** of the plugin stack | **connect / disconnect / update** at runtime |
| Commanding actor | the deploy, as SigV4 system caller | the plugin runtime, via handshake |
| Fragment lifetime matches | the resolvers (deployed infrastructure) | the connection (availability) |
| Removal trigger | final retirement / `pulumi destroy` (symmetric deregister) | disconnect / deregister |

Rationale for the API side being deploy-scoped (not connection-scoped):
(a) ordering — resolvers are created during the deploy, before the runtime can connect;
(b) lifetime — connection state is volatile; dropping fields on disconnect would orphan
live resolvers. The codebase already encodes this (§ 4).

Version supersession nuance: name-keyed registry → version N+1's deploy overwrites N's
fragment; `VersionSuperseded`/`Retired` of an old version must NOT deregister (the name has
a live owner); only final retirement (stack destroyed, resolvers gone) triggers it.

**Structural payoffs:**

1. **Single-writer automation replaces the guard machinery's root cause** — the lease
   becomes unnecessary; keep the shrink guard as defense-in-depth.
2. **Retirement cleanup (§ 7) falls out naturally.**
3. **`deploy-schema:*` keyspace dissolves** into normal read-model state; the runtime
   re-stitcher becomes THE stitch path instead of a parallel implementation.
4. **Provider-genericity for free** — everything flows through `Api_Adapter.updateSchema`
   and QueryDb storage, both already ported per provider (AppSync / graphql-yoga; QueryDb backends DynamoDB/in-memory/
   SQLite/Postgres). No new KV port needed.
5. The original plan's standalone-services use case gets a nicer answer: a standalone
   service calls the same `systemCallable` registration mutation — no shared library.

**Remaining engineering constraints (where the work lives):**

1. **Deploy waiter** — the plugin deploy must await schema-ACTIVE before creating
   resolvers: poll Domain API introspection for its fields, or a push-status field on the
   registry (better failure DX; stitch errors surface in the deploy output, not a timeout).
2. **Consistent automation read** — the stitch must not read an eventually-consistent RM
   scan (re-imports the race in miniature); fold from the registry's own event stream / DCB
   decision read. Runtime drift-repair remains the safety net, not the mechanism.
3. **Platform bootstrap exception** — the admin-base push on the Platform API stays a
   direct deploy-time push (the irreducible seed, ~40 lines).
4. **Migration** — resolved by decision (2026-07-12): none needed. No external users yet;
   existing stacks are wiped and example projects redeployed from scratch on the new
   architecture. The `deploy-schema:*` keyspace, lease, and hash rows are deleted outright,
   which also disposes of the retirement gap (§ 7) without a standalone fix.

## 9. Consequences for existing artifacts (decisions recorded 2026-07-12)

- `docs/plans/schema-fragment-push-public-api.md` — **deleted** (was untracked). The
  extraction it proposed is superseded by § 8: its store half is replaced by registry
  slices; its sink half already exists as `Api_Adapter.updateSchema` / the runtime
  re-stitcher.
- `reventless/aws/src/plugin/SchemaFragmentPush.res` (uncommitted 1:1 extraction
  draft incl. a `resolveTarget` helper) — **deleted**; throwaway under § 8.
- New plan **written**: `docs/plans/event-sourced-fragment-registries.md` — two registries,
  two state machines, deploy-as-system-caller for API, runtime handshake for UI,
  single-writer stitch automation, deploy waiter, bootstrap exception, Plugin-aggregate
  slimming. Command/event names carry the registry context (`RegisterApiFragment` /
  `ApiFragmentRegistered`, `RegisterUiFragment` / `UiFragmentRegistered`, …).
- Retirement cleanup gap (§ 7): **no standalone fix** — subsumed by the plan's
  wipe-and-redeploy cutover (§ 8, constraint 4), which deletes the affected mechanism
  wholesale.
- Provider-dialect leak (§ 11): **added to the plan** as an explicit work item — core emits
  neutral SDL + structured metadata; providers add their dialect additively.

## 10. Platform bootstrap push — anatomy

The one direct schema push the target architecture keeps (§ 8, "bootstrap exception").
It is the first Pulumi deploy of the platform stack — the moment nothing exists (no APIs,
no event log, no Lambdas), so this run cannot use commands/events for anything.

**Trigger and gating** (`Platform_Admin.res:295–315`, generic): `Admin.construct` builds
`adminBarrier` = `Output.all` over every admin read-model DDB resource name **and** every
read model's DataSource name (waits for tables + DataSources; prevents the push racing
`CreateDataSource` → 409), then invokes the optional hook
`preAdminResolversSchemaHook(~adminBarrier)`; all admin `createResolvers` chain behind the
returned Output (AppSync holds an API-level lock during schema creation and rejects
concurrent `CreateResolver` with `ConcurrentModificationException`). The **local platform
supplies no hook** — the switch degrades to an already-resolved Output.

**Target selection** (`Platform.res:701–712`, AWS): split mode → PlatformApi from
`splitApiOutputsRef`; unified → domainApi; split-but-PlatformApi-unknown → **SKIP with
error** (the SDL stitches with an empty plugin list; pushing it to the DomainApi would wipe
every plugin field — the alpha 2026-07-08 clobber).

**SDL content** (`AdminApi.res:63–88`, core): generated Plugin-aggregate mutations
(`Platform_*`) + Plugins RM queries + optional `Platform_Clone`; hand-written SDL for
UIFragment/PluginStatus change types, mutations, and subscriptions;
`Platform_ComponentDefinitions` / `Platform_UIFragments` query fields; per-mutation
Source C subscription fields (`Plugin_SubscriptionSchema.sourceCFields`).

**Decoration + push** (AWS): `injectAwsAuthAll(~group="Admin")` (adds
`@aws_auth(cognito_groups: ["Admin"])` per field) → `GraphQL_Stitcher.stitch(~baseFragment,
~pluginFragments=[])` (prepends Relay base types, dedupes by leading name) →
`stampSharedIamTypes` (`@aws_iam`) → `startSchemaCreationRetrying` (jittered exponential
backoff on 409 `ConcurrentModificationException` only; invalid SDL fails immediately via
`AppSync_Error.classify`) → `waitForSchemaActive` (polls `GetSchemaCreationStatus` every
500 ms, ≤ 30 attempts, throws on FAILED with details).

**Deliberately absent**: fragment persistence, lease, hash, drift/shrink guards — the SDL
stitches from a constant (`pluginFragments=[]`) and in split mode targets an API carrying
only admin/platform schema, so concurrent-writer hazards don't apply. ~40 lines of seed.

**Plan hook-in**: the `ApiFragmentRegistry` slice's `RegisterApiFragment` /
`DeregisterApiFragment` mutation fields (IAM-callable for the SigV4 deploy caller) must
join this bootstrap SDL — they are what the first domain plugin's deploy calls.

## 11. Provider-specific parts of the bootstrap push — audit

**Mechanics: correctly provider-split.**

| Layer | Where | Provider status |
|---|---|---|
| Hook seam (`preAdminResolversSchemaHook` optional in `platformHooks`) | core | generic — local platform passes `None` |
| Barrier + resolver gating (Output orchestration) | core (`Platform_Admin.res`) | generic |
| SDL math (`GraphQL_FragmentGenerator`, `GraphQL_Stitcher`) | core | generic (pure GraphQL) |
| `Platform_ComponentDefinitionsApi` / `Platform_UIFragmentsApi` SDL + encoders | core | generic; shared byte-identically by both providers |
| Target selection, `startSchemaCreationRetrying`, `waitForSchemaActive`, `getClient` | reventless-aws | AWS — correct placement |
| `injectAwsAuthAll` (`@aws_auth`), `stampSharedIamTypes` (`@aws_iam`) | reventless-aws (`AppSync_Adapter`) | AWS — correct placement, **additive** decoration of neutral SDL |
| The push concept itself | — | exists only because AppSync is an external whole-replace service; the local platform builds its schema in-process |

**Content: one genuine leak — core emits the AWS SDL dialect.**

- `AdminApi.res:44,61` (core) hard-code `@aws_subscribe(mutations: [...])` on
  `onUIFragmentChange` / `onPluginStatusChange`.
- `Plugin_SubscriptionSchema.res:35` (core) generates `@aws_subscribe` for every mutation's
  Source C subscription field — so **every plugin fragment** carries the AWS dialect, not
  just the admin base.
- Confirmation by subtraction: the local platform must strip it —
  `reventless-graphql-server/src/GraphQL_SubscriptionBridge.res:69–72` filters
  `@aws_subscribe` lines out (yoga rejects the directive), and
  `reventless-local/src/adapter/Auth/Auth_GraphqlContext.res` re-implements
  `@aws_auth(cognito_groups: ["Admin"])` semantics by hand to match production.

The dependency arrow is inverted in exactly this one place: core emits AWS dialect and the
non-AWS provider subtracts/emulates it — the opposite of the correct additive pattern that
`injectAwsAuthAll`/`stampSharedIamTypes` already follow. Clean shape: core emits **neutral
SDL + structured metadata** (subscription→mutation source mappings, auth group per field);
each provider adds its dialect (AWS adds `@aws_subscribe`/`@aws_auth`/`@aws_iam` at push
time; the local platform wires its subscription bridge and auth context from the same
metadata instead of parsing-and-stripping). Picked up as an explicit work item in the plan
(the plan touches exactly these files).

## 12. Key file references

| What | Where |
|---|---|
| Deploy-time push closure | `reventless/aws/src/Platform.res:749–1091` |
| Admin schema push | `reventless/aws/src/Platform.res:691–742` |
| Hash helpers / prefixes | `reventless/aws/src/Platform.res:603–629` |
| Shrink threshold | `reventless/aws/src/Platform.res:21–26` |
| Resolver gating on push | `reventless/core/src/plugin/component/Plugin_Builder.res:584–587` |
| Fragment on handshake | `reventless/core/src/plugin/component/Plugin_Builder.res:751` |
| Hook type | `reventless/core/src/plugin/component/Plugin_Helpers.res:919` |
| `apiSchemaFragment` type | `reventless/spec/src/components/Plugin.res:93` |
| `uiFragmentManifest` type | `reventless/spec/src/components/Plugin.res:134` |
| Api provider port | `reventless/infra/src/components/Api_Adapter.res` |
| Runtime re-stitcher | `reventless/aws/src/adapter/Runtime/EventCollectorEntryPoint.mjs:504` |
| UI projection | `reventless/core/src/admin/UIFragmentRegistryProjection.res` |
| UI query API (shared encoder) | `reventless/core/src/admin/Platform_UIFragmentsApi.res` |
| Stitcher (generic math) | `reventless/core/src/components/Api/GraphQL_Stitcher.res` |
| Bootstrap barrier + hook invocation | `reventless/core/src/admin/Platform_Admin.res:295–315` |
| Admin base fragment (incl. `@aws_subscribe` leak) | `reventless/core/src/admin/AdminApi.res:44,61,63–88` |
| Source C subscriptions (`@aws_subscribe` leak) | `reventless/core/src/plugin/component/Plugin_SubscriptionSchema.res:35` |
| AppSync push helpers (retry, wait, auth stamping) | `reventless/aws/src/components/Api/AppSync_Adapter.res` |
| Local platform `@aws_subscribe` stripping | `reventless/graphql-server/src/GraphQL_SubscriptionBridge.res:69–72` |
| Local platform `@aws_auth` emulation | `reventless/local/src/adapter/Auth/Auth_GraphqlContext.res` |
