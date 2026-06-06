# Plugin Activate / Deactivate: end-to-end workflow

Scope: make the admin `Platform_Plugin_Activate` / `Platform_Plugin_Deactivate`
mutations work **and** have the correct system-wide effect (API surface
removed/restored, UI surface removed/restored, registry symmetric, host
shell updates live).

The current state is broken on multiple axes — separate workstreams below.

## Progress (2026-05-15)

| Part | Status | Notes |
|---|---|---|
| 1.1 `@noApi` on internal-protocol command variants | ✅ done | `Heartbeat`, `Connect`, `Disconnect`, `ReportIncompatibility` annotated |
| 1.2 Admin-prefix mutation-field registration helper | ✅ done | `Plugin_Helpers.registerAdminAggregateMutations`, called from `Platform_Admin.construct` |
| 1.3a Switch AWS Plugin aggregate to `Aggregate_Builder_Single` | ✅ done | Auto-flow now wires AppSync resolvers for `Platform_Plugin_Activate`/`Deactivate` |
| 1.3b Wire local `PluginAggregate` | ⚠️ partial | Aggregate constructed and threaded into `Admin.construct`; full Activate/Deactivate command routing requires also routing the Connect flow through the aggregate (currently the local adapter bypasses Connect with `seedPluginQueryDb`). Hand-written resolvers preserved for now; deferred. |
| 1.4 Drop hand-rolled `PluginBaseFragment.mutationEntries` | ✅ done | Auto-derived entries now in `PluginBaseFragment.pluginAggregateMutationEntries`; consumed by `AdminApi.mutationEntries` (so AWS push picks them up) and resolver wiring fired via `Plugin_Helpers.registerAdminAggregateMutations`. Synthetic `idArgs` retained only inside `Platform_Admin_Structure` for Auto UI metadata. |
| 1.5 Cognito `@aws_auth` on admin fragment | ⏳ verify on deploy | `injectAwsAuthAll` still wraps the admin fragment; the auto-derived `Platform_Plugin_Activate`/`Deactivate` fields land in the same fragment |
| 2.1 Symmetric `Activate` emits `UIFragmentRegistered` | ✅ done | `PluginBehavior.Inactive → Activate` mirrors the `Connected → Deactivate` block |
| 2.2 Local `Platform_UIDefinitions` status filter | ✅ done | Filters by Plugin RM status; built-in `Platform_Admin` always included |
| 2.3 Resolver-level plugin status gate (Option B) | ✅ done (both adapters) | Local: `CommandGeneratorResolvers_GraphQL.setPluginStatusGate`. AWS: `AggregateEntryPoint.mjs::checkPluginStatus` cached scan against the Plugin RM table; `AggregateRuntime_Builder_Single.setPluginReadModelTable` injects the `PLUGIN_RM_TABLE_NAME` env var + `dynamodb:Scan` IAM policy. Both emit the split codes from the three-tier model (`PluginUnavailable` / `PluginInactive`). |
| 2.4 Host-shell subscription to lifecycle | ⚠️ partial | Backend SDL (`Platform_PluginStatusChanged` mutation + `onPluginStatusChange: PluginStatusChangeEvent @aws_subscribe` field) added to `AdminApi.baseFragment`. Local `updatePluginStatus` publishes to the `"onPluginStatusChange"` PubSub topic; the platform server registers a matching subscription resolver. **Local frontend wired (F4 local done)** — host shell `RegisterFragments.res` subscribes to `onPluginStatusChange` + `onUIFragmentChange` via `graphql-ws`, re-fetches Platform_UIDefinitions/UIFragments on each event, and swaps the page/panel/route registries atomically via `setPluginPages` / `setPluginPanels` / `setPluginRoutes`. AWS-side emit (would invoke `Platform_PluginStatusChanged` from the PluginProjection Lambda) still pending. |

## Remaining follow-ups (deferred)

### F1 — Full local Connect-flow refactor (extends 1.3b)
The local adapter still seeds plugin definitions directly into the Plugin
QueryDb (`seedPluginQueryDb` in `reventless-local/src/Platform.res:839`),
bypassing the Plugin aggregate's `Connect` command path. Hand-written
`Platform_Plugin_Activate` / `Platform_Plugin_Deactivate` resolvers at
`Platform.res:1378-1399` mutate the QueryDb directly.

Replace this with:
- Subscribe to `PluginAggrEventTopic` and run `PluginProjection.PluginMapping`
  against the Plugin QueryDb (Set/Update/UpdateWithDefault/Delete).
- In `seedPluginQueryDb`, instead of writing to the QueryDb directly, dispatch
  a synthetic `Connect(pluginDefinition)` command per plugin via
  `Bus.dispatchCommand(<aggregate-cmd-topic>, …)`. The aggregate behaviour
  emits `Connected` events that the projection subscriber consumes.
- Once the seed is event-driven, delete the hand-written Activate/Deactivate
  resolvers — `Plugin_Helpers.registerAdminAggregateMutations` (already firing
  via `Admin.construct`) has registered the auto-flow stubs, and the
  `mutationBindHook` will bind the local generateCommand.

Verify that the existing `seedPluginQueryDb` second call site (deployPlugin
hot-path at `Platform.res:1961`) also routes via the aggregate.

### F2 — AWS Lambda plugin-status gate (extends 2.3) ✅ done
The gate now lives in `reventless-aws/src/adapter/Runtime/AggregateEntryPoint.mjs::checkPluginStatus`,
called before per-aggregate handler dispatch in Route 1 (AppSync direct
invocation). It:
- Extracts the field name from `event.meta.info` (`${parentType}.${fieldName}`).
- Skips the check for `Platform_*` fields.
- Scans the Plugin RM DynamoDB table (TTL-cached at the module level — see
  `PLUGIN_RM_CACHE_TTL_MS`, default 5s) and maps the `status` field to a
  `CommandRejected` outcome:
  - `Disconnected` → `errorCode: "PluginUnavailable"` (retryable; tier 1)
  - `Inactive`     → `errorCode: "PluginInactive"`    (admin-controlled; tier 2)
  - `Connected` / unknown → pass through to the handler

See [docs/analysis/plugin-lifecycle-tiers.md](../analysis/plugin-lifecycle-tiers.md)
for the rationale behind splitting the codes.

Wiring (in `AggregateRuntime_Builder_Single.finish()`):
- `PLUGIN_RM_TABLE_NAME` env var on the AllAggregates Lambda — set by
  `AggregateRuntime_Builder_Single.setPluginReadModelTable(~name)`, called
  from `reventless-aws/src/Platform.res` in both `makePlatform` and
  `deployPlatform` after `Admin.construct` returns.
- IAM: an `AllAggregatesPluginRmScan` inline role policy granting
  `dynamodb:Scan` on `arn:aws:dynamodb:*:*:table/<name>` (mirrors the pattern
  used by `Platform_UIDefinitions_Lambda`).
- Gate is silently disabled if the env var is not set (legacy stacks /
  test paths).

Bundled cleanup: ✅ the local gate
(`CommandGeneratorResolvers_GraphQL.setPluginStatusGate`) emits matching
split codes.

### F3 — Backend `onPluginStatusChange` subscription emit (Part 2.4 backend)
**Local: ✅ done.** `AdminApi.baseFragment` declares
`PluginStatusChangeEvent`, `Platform_PluginStatusChanged(pluginId, status)`,
and the matching `onPluginStatusChange` subscription field with
`@aws_subscribe`. `updatePluginStatus` (in
`reventless-local/src/Platform.res`) publishes to the
`"onPluginStatusChange"` PubSub topic after saving the new status. The
platform server registers a matching subscription resolver alongside the
existing `onUIFragmentChange` one.

**AWS: ❌ not yet done.** The AWS path needs to invoke
`Platform_PluginStatusChanged` from a place that observes Plugin aggregate
`Activated` / `Deactivated` events — most naturally the PluginProjection
Lambda (the same one that updates the Plugin RM table). The Lambda would
need IAM `appsync:GraphQL` on the Platform API and would call
`Platform_PluginStatusChanged(pluginId, status)` for each transition;
AppSync's `@aws_subscribe` directive then fans out to live subscribers.

The same gap exists for the older `onUIFragmentChange` subscription — both
declarations are present in the SDL but only the local adapter actively
publishes to them. Fixing both AWS emits at once would be consistent.

### F4 — Host shell subscription wiring (Part 2.4 frontend, cross-repo)

Status: **local frontend done.** AWS path still gated by F3-AWS emit.

What landed:

1. **Yoga graphql-ws transport** (backend prerequisite — scope expanded
   beyond the original plan because yoga's default subscription transport
   is SSE-over-POST, which `graphql-ws` clients can't speak):
   `reventless-local/package.json` now depends on `graphql-ws@^5.16`
   and `ws@^8.18`. `GraphQL_ServerInstance.start()` wraps the HTTP server
   with `new WebSocketServer({server, path: "/graphql"})` and hands it
   to `graphql-ws/lib/use/ws::useServer({schema}, wss)` whenever any
   subscription resolvers are registered. Auth on the WS channel is
   deferred — connections are unauthenticated for local dev (localhost
   only); the HTTP query/mutation path keeps its `Authorization` header
   check.
2. **Registry teardown surface** (`reventless-ui/src/registry/*.res`):
   `PageRegistry`, `PanelRegistry`, and `RouteRegistry` each now keep
   two buckets — `static` (the existing `register` API used by
   `RegisterShellPages` for the host home page) and `plugin` (swapped
   atomically by the new `setPluginPages` / `setPluginPanels` /
   `setPluginRoutes` APIs). Reads merge both. This preserves host pages
   across plugin-list replacements without needing per-entry pluginId
   tagging.
3. **`Config.t` subscription endpoint**
   (`reventless-host-shell/src/api/Config.res`): added
   `platformApiSubscriptionEndpoint: string`, derived from
   `platformApiEndpoint` via `deriveSubscriptionEndpoint` (http→ws,
   https→wss) when not explicitly set in `config.json`. AppSync
   deployments must override with the dedicated
   `wss://<api>.appsync-realtime-api.<region>.amazonaws.com/graphql`
   host at deploy time.
4. **`GraphqlWsClient.res`** (new file under
   `reventless-host-shell/src/api/`): thin externals for
   `createClient({url, connectionParams, lazy, retryAttempts})`,
   `client.subscribe(payload, sink)`, and `client.dispose()`. Bearer
   token (when present) is plumbed via `connectionParams.Authorization`
   so AppSync's Cognito flow plugs in at the same seam.
5. **`RegisterFragments.res` rework**: `registerAll` now accumulates
   pages / panels / routes / publicLinks across every plugin in one
   pass and calls `setPluginPages` / `setPluginPanels` /
   `setPluginRoutes` once per registry, so re-runs replace cleanly
   rather than re-appending. A second `React.useEffect` keyed on
   `[token]` opens a `graphql-ws` client and subscribes to both
   `onPluginStatusChange { pluginId status }` and
   `onUIFragmentChange { pluginId fragmentId changeType }`. Either
   event re-runs `fetchAndRegister`, so deactivated plugins drop out of
   the next `Platform_UIDefinitions` result (status filter from 2.2)
   and activated plugins reappear. Cleanup disposes the client.

Manual verification (still pending): with the local adapter running
locally, click Deactivate on a plugin in the admin UI; confirm the
sidebar entry disappears within ~1s without a page reload; Activate
restores it. Existing automated tests pass
(`tests/adapter/GraphQL_SubscriptionResolversTest.res.mjs`,
`tests/adapter/LocalAuthHttpTest.res.mjs`).

Dependencies on parallel work: the AWS path also needs an emit (the AWS
half of F3) and the deploy-time `config.json` writer needs to set
`platformApiSubscriptionEndpoint` to the appsync-realtime-api host
before this works end-to-end against a deployed AppSync API.

## Status snapshot (original — current state before this work)

| Layer | Deactivate removes | Activate restores |
|---|---|---|
| AppSync resolver wiring (AWS) | ❌ no resolver — mutation errors | ❌ |
| Plugin read model status | ✅ → Inactive | ✅ → Disconnected |
| Plugin read model `apiSchemaFragment` / `uiFragments` (raw fields) | ✅ preserved | ✅ preserved |
| `UIFragmentRegistry` row | ✅ deleted (UIFragmentDeregistered → Delete) | ❌ never restored — Activate does not emit UIFragmentRegistered |
| `Platform_UIDefinitions` AWS | ✅ DynamoDB scan filters `status contains "Connected"` | ❌ (moot until registry restore wired) |
| `Platform_UIDefinitions` local | ❌ no status filter; store seeded once at boot | n/a |
| Live AppSync / local GraphQL SDL | ✅ stays in SDL by design (membership preserved); ❌ resolver gate missing — calls succeed instead of being rejected | ❌ resolver gate restoration missing |
| Host shell page / panel registry | ❌ static at boot; no subscription | ❌ |

# Part 1 — Resolver wiring on AWS

Make the buttons actually reach `PluginBehavior` via the standard
auto-resolver path.

## Problem

`Platform_Plugin_Activate` / `Platform_Plugin_Deactivate` mutations are
declared in the AppSync SDL (via `PluginBaseFragment.mutationEntries`) and
Cognito-gated to the `Admin` group, but **no AppSync resolvers are wired**
on AWS — every invocation errors.

The root cause is `Aggregate_Builder_NoResolver`
([reventless-aws/src/components/Aggregate_Builder_NoResolver.res:6](reventless-aws/src/components/Aggregate_Builder_NoResolver.res)):
it swaps the standard `CommandGeneratorResolvers_AppSync` for a no-op,
which creates zero AppSync resolvers for the Plugin aggregate.

But the backend is already in place: the shared "AllAggregates" Lambda has
a CommandGenerator handler for **every** registered aggregate including
Plugin (see [AggregateEntryPoint.mjs:97-138](reventless-aws/src/adapter/Runtime/AggregateEntryPoint.mjs#L97-L138)),
because `forCommandTopic` / `forCommandGenerator` run unconditionally
inside `Aggregate_Builder.Make`. The Lambda is already wired with SQS
publish permissions for the Plugin queue, and route 1 (`event.command !=
null`) dispatches AppSync invocations to it. Only the SDL→Lambda resolver
wiring is missing.

Two reasons NoResolver exists today:

1. **Mix of internal-protocol and admin-facing commands.** `PluginSpec.command`
   has 6 variants — `Heartbeat`, `Connect(pluginDef)`, `Disconnect`,
   `ReportIncompatibility(pluginDef)`, `Activate`, `Deactivate`. A plain
   `Aggregate_Builder_Single` would auto-expose all six as GraphQL
   mutations, which breaks integrity (anyone could forge a `Connect`).
2. **Admin field naming.** Admin mutations use the `Platform_*` prefix
   (`Api_Naming.adminField` → `"Platform_Plugin_Activate"`). The standard
   flow in [Plugin_Builder.res:163-176](reventless-core/src/components/Plugin/Plugin_Builder.res#L163-L176)
   generates `<Plugin>_<Aggregate>_<Command>` and registers those into
   `aggregateMutationFieldsRegistry`. `Admin.construct` runs a different
   aggregate loop ([Builder_Helpers.res:18-44](reventless-core/src/components/Builder_Helpers.res#L18-L44))
   that never populates the registry, so even if NoResolver were dropped,
   the auto-flow has no field names to wire.

The framework already has the building blocks to fix both — they're just
not connected to the admin path yet.

## Goal

Delete `Aggregate_Builder_NoResolver` (or stop using it for the Plugin
aggregate) and let the standard aggregate auto-resolver flow wire
`Platform_Plugin_Activate` / `Platform_Plugin_Deactivate` end to end. No
new Lambda, no new IAM, no new resolver template.

## Refactor steps

### 1.1 `@noApi` the internal-protocol commands in `PluginSpec.res`

File: `reventless-core/src/admin/PluginSpec.res`

Annotate the four internal variants:

```rescript
@schema
type command =
  | @noApi Heartbeat
  | @noApi Connect(pluginDefinition)
  | @noApi Disconnect
  | Activate
  | Deactivate
  | @noApi ReportIncompatibility(pluginDefinition)
```

`@noApi` is a per-variant sury-ppx attribute already used in the codebase
(see [examples/online-shop-hybrid/ordering/.../CancelOrder.res:16](examples/online-shop-hybrid/ordering/src/Order/StateChangeSlice/CancelOrder.res#L16):
`@noApi ReopenOrder(...)`). It writes to `noApiVariantsId` metadata, which
`ApiNoApiHelpers.filterNoApiVariants` reads to drop those variants from
the auto-generated mutation field list. Internal callers
(PluginConnectExtension publishing to the CommandTopic SQS directly) are
unaffected — the filter only applies to the GraphQL exposure path.

### 1.2 Register admin-prefix mutation field names in `Builder_Helpers`

File: `reventless-core/src/components/Builder_Helpers.res`

Currently `createAggregatesWithoutEventMappers` doesn't touch
`aggregateMutationFieldsRegistry`. The plugin flow does this in
[Plugin_Builder.res:163-189](reventless-core/src/components/Plugin/Plugin_Builder.res#L163-L189);
mirror that block in `Builder_Helpers` (or a new admin-specific helper
called from `Platform_Admin.construct`) using `Api_Naming.adminField`
instead of `Api_Naming.aggregateMutationField`:

```rescript
let constructorNames = Reventless.DcbTag.extractAllVariantNames(M.Spec.commandSchema)
let filteredConstructorNames =
  ApiNoApiHelpers.filterNoApiVariants(constructorNames, commandSchema)
let fieldNames =
  filteredConstructorNames->Array.map(cname =>
    Api_Naming.adminField(~name=M.Spec.name ++ "_" ++ cname)
  )
// → ["Platform_Plugin_Activate", "Platform_Plugin_Deactivate"]
Plugin_Helpers.aggregateMutationFieldsRegistry->Dict.set(M.Spec.name, fieldNames)
```

This is what `CommandGenerator_Builder` reads at
[reventless-core/src/components/CommandGenerator/CommandGenerator_Builder.res:35](reventless-core/src/components/CommandGenerator/CommandGenerator_Builder.res#L35)
to know which AppSync resolvers to create. Same path for local
(`mutationBindHook` at [Aggregate_Builder.res:111-115](reventless-core/src/components/Aggregate/Aggregate_Builder.res#L111-L115))
and AWS (`forCommandGenerator` Lambda dispatch).

The new helper should also fire `Spec.hooks.mutationResolverHook` with
the filtered fields so admin SDL registration stays in sync (cf.
[Plugin_Builder.res:182-188](reventless-core/src/components/Plugin/Plugin_Builder.res#L182-L188)).

### 1.3 Switch Plugin aggregate to `Aggregate_Builder_Single`

File: `reventless-aws/src/Platform.res:882-888`

Replace:
```rescript
module PluginAggregate: (...) = Aggregate_Builder_NoResolver.Make(
  ReventlessCore.PluginSpec,
  ReventlessCore.PluginBehavior,
  ReventlessInfra.NoEventMappings.Make(ReventlessCore.PluginSpec),
)
```

with:
```rescript
module PluginAggregate: (...) = Aggregate_Builder_Single.Make(
  ReventlessCore.PluginSpec,
  ReventlessCore.PluginBehavior,
  ReventlessInfra.NoEventMappings.Make(ReventlessCore.PluginSpec),
)
```

Mirror the same change in `reventless-local/src/Platform.res` if it
uses an analogous NoResolver-style builder for the Plugin aggregate.

If no AWS callsite of `Aggregate_Builder_NoResolver` remains after this,
delete the file. Search:

```bash
grep -rn "Aggregate_Builder_NoResolver" reventless/reventless-aws/src/
```

### 1.4 Reconcile `PluginBaseFragment.mutationEntries` with the auto-flow

File: `reventless-core/src/admin/PluginBaseFragment.res:33-50`

Currently `mutationEntries` hand-declares two entries with synthetic
`activateArgs` / `deactivateArgs` schemas (`{id: @s.matches(DcbTag.string)
string}`). They exist because `Activate` and `Deactivate` are payload-less
variants — the auto-flow needs an `id` arg for GraphQL but the command
type carries no fields.

Decide based on what the standard aggregate flow does for payload-less
variants (open question — verify before implementing):

- **If the standard flow auto-injects `id` for payload-less aggregate
  commands**: delete `activateArgsSchema` / `deactivateArgsSchema` and the
  hand-written `mutationEntries`; let the auto-flow generate the SDL via
  the same path user-plugin aggregates use, with admin-aware prefixing.
  Update `AdminApi.mutationEntries` to derive from the registry instead
  of hand-listing.
- **If it doesn't** (i.e. the framework assumes commands always have a
  payload field that doubles as the aggregate id): either keep the
  hand-written args and just remove the manual `mutationEntries`
  registration in favour of letting `mutationResolverHook` fire from the
  new admin helper in 1.2, OR teach `GraphQL_FragmentGenerator` to
  synthesize the `id` arg for payload-less variants on aggregates.

Verify by reading the existing flow with a payload-less variant on a
user-plugin aggregate (if any exists in `examples/online-shop-aggregates/`)
or by tracing `GraphQL_FragmentGenerator.generate` against a synthetic
command schema with one payload-less variant.

### 1.5 Cognito auth — verify untouched

`AppSync_Adapter.injectAwsAuthAll` ([reventless-aws/src/Platform.res:1062-1064](reventless-aws/src/Platform.res#L1062-L1064)
and [:1287-1288](reventless-aws/src/Platform.res#L1287-L1288)) wraps the
entire admin fragment with `@aws_auth(cognito_groups: ["Admin"])`. After
the refactor the admin fragment still contains `Platform_Plugin_Activate`
and `Platform_Plugin_Deactivate` (whether hand-written or auto-derived)
so the directive still applies. Confirm by grepping the produced SDL
during a stack deploy.

# Part 2 — Workflow correctness

Even once Part 1 lands, a clicked Deactivate / Activate produces only
**partial** effects. This part closes the gaps so the lifecycle is fully
correct.

## 2.1 PluginBehavior — symmetrise `Activate`

File: [reventless-core/src/admin/PluginBehavior.res:96](reventless-core/src/admin/PluginBehavior.res#L96)

Currently:
```rescript
| Inactive(pluginDefinition) =>
  switch command {
  | Activate => Ok([Activated(pluginDefinition)])  // ← asymmetric
```

`Deactivate` from `Connected` ([line 65-71](reventless-core/src/admin/PluginBehavior.res#L65-L71))
correctly emits `Deactivated` **plus** `UIFragmentDeregistered`. Same
pattern exists for `Heartbeat` from `Disconnected` ([line 80-86](reventless-core/src/admin/PluginBehavior.res#L80-L86))
which emits `Reconnected` + `UIFragmentRegistered`. Fix Activate to match:

```rescript
| Activate =>
  Ok(
    Array.concat(
      [(Activated(pluginDefinition): event)],
      uiRegisterEvents(pluginDefinition.id, pluginDefinition.uiFragments),
    ),
  )
```

Without this, [UIFragmentRegistryProjection.res:33](reventless-core/src/admin/UIFragmentRegistryProjection.res#L33)
(which handles `UIFragmentDeregistered → Delete(id)`) wipes the row on
Deactivate and the only paths that re-insert it are `Connected` and
`Reconnected` — neither fires on Activate. So Activate from `Inactive`
silently leaves the UI fragment registry empty for that plugin.

## 2.2 Local `Platform_UIDefinitions` — match AWS status filter

File: [reventless-local/src/Platform.res:1276-1284](reventless-local/src/Platform.res#L1276-L1284)

```rescript
queryResolvers->Dict.set(
  "Platform_UIDefinitions",
  async (_root, _args, _ctx): JSON.t =>
    pluginStructuresStore.contents
    ->Dict.toArray
    ->Array.map(...)
    ->JSON.Encode.array,
)
```

AWS already filters by plugin status via the DynamoDB scan
([Platform_UIDefinitions_Lambda.res:31-44](reventless-aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res#L31-L44)):
`FilterExpression: "contains(#status, :connected)"`. The local
resolver returns everything in `pluginStructuresStore`, which is seeded
once at boot ([Platform.res:1177](reventless-local/src/Platform.res#L1177))
and never reflects lifecycle changes.

Match the AWS behavior: cross-reference `pluginStructuresStore` against
the Plugin QueryDb status (via `Bus.getQueryDbScan(pluginQueryDbName)` —
same store the `Platform_Plugins` resolver scans) and drop entries whose
status is not `Connected`. Note: the built-in `Platform_Admin` entry
seeded at [Platform.res:1182-1185](reventless-local/src/Platform.res#L1182-L1185)
has no Plugin QueryDb row — always include it (it can't be deactivated).

## 2.3 Live API schema — runtime gate (membership stays, availability gates)

This is the **biggest functional gap**. After Deactivate the deactivated
plugin's GraphQL queries and mutations remain fully callable on both
adapters because `GraphQL_Stitcher.stitch` runs only at platform start
([AppSync_Adapter.res:337](reventless-aws/src/components/Api/AppSync_Adapter.res#L337);
local `Platform.res` startServers path). Nothing subscribes to
`Activated` / `Deactivated` events to re-stitch.

### Design principle

The plugin's GraphQL surface has two orthogonal axes — **membership**
(types in the SDL) and **availability** (whether the resolver currently
serves requests). Tiers 1 (`Disconnected`) and 2 (`Inactive`) change
availability only; SDL membership stays untouched and is restored
automatically on `Reconnected` / `Activated`. Only a future tier 3
(decommission) crosses the membership line and triggers a real schema
re-stitch. See [docs/analysis/plugin-lifecycle-tiers.md](../analysis/plugin-lifecycle-tiers.md)
for the full tier × surface matrix and the rationale.

Two consequences:

- **No SDL re-stitch on Deactivate or Activate.** A 30-second AppSync
  redeploy on every admin toggle is not viable. Schema stability is also
  the right contract for typed clients (codegen builds don't break on
  routine status flips).
- **Resolver-level status gate is the intended design**, not a
  workaround for the cost of re-stitching. It encodes "availability" as
  a runtime check that reads the Plugin RM `status` and rejects requests
  to off-tier plugins, while leaving the SDL alone.

### Implementation

Add a `pluginStatusCheck` interceptor in the mutation / query resolver
path that resolves the plugin name from the field's plugin prefix
(e.g. `Catalog_Product_Add` → `Catalog`) and inspects the Plugin RM
`status`. This rides alongside the existing `commandAuthorization` /
`permission` machinery
([Authorization.res](reventless-core/src/types/Authorization.res)).

**Error codes** — return distinct codes for the two off-tiers so clients
can choose the right policy:

| Plugin RM status | Error code | Client policy |
|---|---|---|
| `Connected` | (passes) | n/a |
| `Disconnected` (tier 1) | `PluginUnavailable` | retry with backoff — auto-recovery expected |
| `Inactive` (tier 2) | `PluginInactive` | surface to user, do **not** retry — admin only |

A single conflated error code forces clients to pick one wrong policy
(aggressive retries against an admin-suspended plugin, or no retries
against a transiently-disconnected plugin). The gate already has the
status string, so differentiation is essentially free.

**Status note**: the local implementation
(`CommandGeneratorResolvers_GraphQL.setPluginStatusGate`) currently
returns a single `InactivePlugin` errorCode for both off-tiers.
Splitting it into `PluginUnavailable` / `PluginInactive` is a small
follow-up bundled into F2 below. F2 (the AWS Lambda gate) should ship
with the split codes from day one.

## 2.4 Host shell — subscribe to lifecycle changes

Two queries currently run at boot and never refetch:

- `Platform_UIFragments` ([RegisterFragments.res:221](../reventless-ui/reventless/reventless-host-shell/src/fragments/RegisterFragments.res#L221))
- `Platform_UIDefinitions` ([RegisterFragments.res:220](../reventless-ui/reventless/reventless-host-shell/src/fragments/RegisterFragments.res#L220))

The framework declares an `onUIFragmentChange` subscription
([PluginBaseFragment.res:37](reventless-core/src/admin/PluginBaseFragment.res#L37))
but the host shell never subscribes to it. Backend correctly fires the
matching mutations from local
[Platform.res:1396-1417](reventless-local/src/Platform.res#L1396-L1417)
(`Platform_UIFragmentRegistered` / `_Updated` / `_Deregistered`).

Wire the host shell to:

1. Subscribe to `onUIFragmentChange` and, on each event, update the
   page / panel / route registries (tear down or re-mount fragments by
   `pluginId`).
2. Either re-fetch `Platform_UIDefinitions` on the same trigger (since
   Auto UI definitions are tied to plugin lifecycle), or add a second
   subscription `onPluginStatusChange` carrying `(pluginId, newStatus)`
   so the shell can selectively unmount Auto-derived routes.

The second piece needs a backend event source — likely emitting from the
`Activated` / `Deactivated` projection at the same time the existing
UIFragment mutations fire.

## 2.5 Verification matrix — desired final state

| Layer | Deactivate removes | Activate restores |
|---|---|---|
| AppSync resolver wiring (AWS) | ✅ resolver routes to shared Lambda | ✅ same |
| Plugin read model status | ✅ → Inactive | ✅ → Disconnected |
| Plugin RM `apiSchemaFragment` / `uiFragments` (raw) | ✅ preserved | ✅ preserved |
| GraphQL SDL membership | ✅ **preserved** (no re-stitch — membership is structural) | ✅ preserved |
| `UIFragmentRegistry` row | ✅ deleted | ✅ restored by symmetric `UIFragmentRegistered` emit |
| `Platform_UIDefinitions` AWS | ✅ filtered by status | ✅ |
| `Platform_UIDefinitions` local | ✅ filtered by status | ✅ |
| Live GraphQL resolver gate | ✅ rejects: `PluginInactive` (Inactive) / `PluginUnavailable` (Disconnected) | ✅ passes again |
| Host shell page / panel registry | ✅ unmounts on subscription | ✅ re-mounts on subscription |

The "GraphQL SDL membership preserved" row is the key invariant from the
membership-vs-availability design — see
[docs/analysis/plugin-lifecycle-tiers.md](../analysis/plugin-lifecycle-tiers.md).
Tearing down the SDL on a routine admin toggle would be the wrong contract.

## Verification

1. `pnpm exec rescript build` clean — zero warnings across both adapters.
2. Existing local and AWS tests still pass.
3. Deploy AWS alpha. Confirm in the synthesized SDL via AppSync console:
   - `Platform_Plugin_Activate(id: ID!): ...` and `Platform_Plugin_Deactivate(id: ID!): ...` exist
   - Both have `@aws_auth(cognito_groups: ["Admin"])`
   - `Platform_Plugin_Heartbeat` / `_Connect` / `_Disconnect` /
     `_ReportIncompatibility` are **NOT** in the schema (filtered by
     `@noApi`)
4. End-to-end smoke test: log in as Admin Cognito user via host shell.
   For each of `Deactivate` and `Activate`:
   - Mutation returns success (Part 1).
   - Plugin row in Auto UI shows updated status (Part 1).
   - Plugin row's read-model `apiSchemaFragment` and `uiFragments`
     remain preserved across the toggle (PluginProjection already does
     this).
   - `Platform_UIDefinitions` response no longer / again contains the
     plugin's structure (Part 2.2 on local; 2.1 + correct on AWS).
   - `Platform_UIFragments` response no longer / again contains the
     plugin's UI manifest (Part 2.1).
   - Calling a deactivated plugin's mutation directly returns the
     `Inactive plugin` error from the resolver gate (Part 2.3).
   - Host shell sidebar updates within the live session — no reload
     needed (Part 2.4).
5. Verify user plugins still register: deploy / connect a user plugin
   and confirm `Plugin_Connect`-style internal commands still reach the
   Plugin aggregate via the ExtensionPoint.

## Out of scope

- Renaming `PluginSpec` or its event / state types.
- Touching `MCP_Lambda.res` — its `Plugin_Activate` / `Plugin_Deactivate`
  references at line 106 are MCP tool descriptions, independent of the
  AppSync resolver wiring.
- Auto-discovery for new admin-only command variants — once Part 1
  lands, future `@noApi`-free variants in `PluginSpec.command` are
  automatically exposed.
- Full schema re-stitch on Deactivate — explicitly out of scope; SDL
  membership is preserved across tier 1 and tier 2 transitions by
  design (see 2.3 and the analysis doc).
- **Decommission tier (tier 3 — `PluginDeregistered`)** — the lifecycle
  step that *would* legitimately re-stitch the SDL is a separate future
  workstream. It is the only tier that changes plugin membership rather
  than availability. See
  [docs/analysis/plugin-lifecycle-tiers.md](../analysis/plugin-lifecycle-tiers.md)
  ("Open: decommission tier") and
  [docs/analysis/event-graph-linking.md:237](../analysis/event-graph-linking.md#L237).

## Why this instead of a one-off Lambda for resolver wiring

An earlier draft of Part 1 proposed a dedicated
`Platform_PluginCommand_Lambda.res` (≈200 lines: new Lambda, IAM, two
resolvers). That works but duplicates infrastructure the shared
"AllAggregates" Lambda already provides, and leaves the `_NoResolver`
special case in the codebase indefinitely. The refactor above touches ~5
small spots, removes a builder variant, and lets admin-internal
aggregates participate in the standard auto-resolver flow just like
user-plugin aggregates.

## References

- [docs/analysis/plugin-lifecycle-tiers.md](../analysis/plugin-lifecycle-tiers.md)
  — three-tier lifecycle model (transient outage / admin suspend /
  decommission), membership-vs-availability principle, error-code
  rationale, and the decommission-tier sketch.
- `reventless-core/src/admin/PluginSpec.res` — command type (6 variants).
- `reventless-core/src/admin/PluginBehavior.res` — decision logic; `Activate` asymmetry on line 96.
- `reventless-core/src/admin/PluginProjection.res` — projection; `apiSchemaFragment` / `uiFragments` preserved across status updates via `UpdateWithDefault` updater.
- `reventless-core/src/admin/UIFragmentRegistryProjection.res:33` — `UIFragmentDeregistered → Delete(id)`.
- `reventless-core/src/admin/PluginBaseFragment.res:33-50` — hand-written admin mutation entries.
- `reventless-core/src/admin/Platform_Admin_Structure.res` — synthetic plugin structure for the host shell (already shipped).
- `reventless-core/src/components/Api/ApiNoApiHelpers.res` — `@noApi` filter implementation.
- `reventless-core/src/components/Plugin/Plugin_Builder.res:163-189` — reference flow for field-name registration.
- `reventless-core/src/components/Builder_Helpers.res:18-44` — admin aggregate loop that needs analogous field registration.
- `reventless-core/src/components/Api/Api_Naming.res:37, 86` — `aggregateMutationField` vs `adminField`.
- `reventless-aws/src/components/Aggregate_Builder_NoResolver.res` — file to be removed.
- `reventless-aws/src/components/Aggregate_Builder_Single.res` — replacement.
- `reventless-aws/src/adapter/Runtime/AggregateRuntime_Builder_Single.res` — shared `AllAggregates` Lambda; no changes needed.
- `reventless-aws/src/adapter/Runtime/AggregateEntryPoint.mjs:97-138` — proves the Lambda already dispatches AppSync events to Plugin commands.
- `reventless-aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res:31-44` — AWS status filter that the local adapter should mirror.
- `reventless-local/src/Platform.res:1276-1284` — local `Platform_UIDefinitions` resolver missing the status filter.
- `reventless-local/src/Platform.res:1396-1417` — backend already publishes `onUIFragmentChange` events the host shell doesn't subscribe to.
- `examples/online-shop-hybrid/ordering/src/Order/StateChangeSlice/CancelOrder.res:16` — `@noApi` usage example.
