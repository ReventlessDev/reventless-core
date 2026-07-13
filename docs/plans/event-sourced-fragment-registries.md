# Event-sourced fragment registries (API schema + UI)

**Status:** Plan
**Date:** 2026-07-12
**Analysis:** [docs/analysis/fragment-registry-architecture.md](../analysis/fragment-registry-architecture.md)
**Supersedes:** `schema-fragment-push-public-api.md` (extraction of the deploy-time push
into a public function — retired; the use case it served is solved more directly here,
see § Standalone services).

## Problem

The cumulative API-schema mechanism is a parallel persistence architecture living outside
the framework's own building blocks: raw `deploy-schema:*` DynamoDB rows written by the
`preResolversSchemaHook` closure (`reventless-aws/src/Platform.res:749–1091`), guarded by a
table-keyed lease, hash rows, drift repair, and a catastrophic-shrink guard. Every guard
exists because **N concurrent deploy processes write one whole-replace AppSync schema**.

Consequences:

- The mechanism is reachable only through `deployPlugin` — auxiliary services contributing
  SDL fields from standalone Pulumi programs have no entry point and would fork the flow.
- The fragment data travels twice (deploy rows + connect handshake into the Plugins RM),
  with subtly different lifecycles.
- **Retirement gap:** UI fragments are cleaned up on `UIFragmentDeregistered`; the
  name-keyed `deploy-schema:<name>` rows have no removal path — a plugin retired without a
  successor leaves its fields stitched into the API indefinitely (analysis § 7).
- The Plugin aggregate carries fragment payloads (API + UI manifests) in its events and
  read model, mixing lifecycle with contribution content.

## Proposal

Model both fragment registries as ordinary event-sourced platform components with defined
commands, events, and state; make a single platform-side automation the **only writer** of
the Domain API schema. The Plugin aggregate keeps lifecycle only.

### Component decomposition

```
ApiFragmentRegistry    StateChangeSlice  RegisterApiFragment / DeregisterApiFragment
                                         → ApiFragmentRegistered / ApiFragmentDeregistered
                                         (@@reventless.systemCallable — the deploy is the caller)
                       StateViewSlice    current fragment per plugin name (+ push status)
                       AutomationSlice   on ApiFragment* events → stitch all fragments +
                                         admin/empty base → push via
                                         Api_Adapter.Provider.updateSchema (single writer)

UiFragmentRegistry     StateChangeSlice  RegisterUiFragment / UpdateUiFragment / DeregisterUiFragment
                                         → UiFragmentRegistered / UiFragmentUpdated / UiFragmentDeregistered
                       StateViewSlice    manifest per plugin (replaces UIFragmentRegistry RM)
                       (no automation — composition stays lazy in the host-shell)

Plugin aggregate       lifecycle only: Connected, VersionSuperseded, Retired.
                       pluginDefinition stops carrying apiSchemaFragment / uiFragments;
                       PluginsReadModelSpec drops the fragment field.
```

Evaluate aggregate-vs-DCB per `docs/guides/aggregate-vs-dcb-decision-guide.md` before
implementation; DCB slices are the default here because `@@reventless.systemCallable` is
defined on slices and the registry needs no cross-entity consistency (state is per plugin
name). Component naming stays provider-neutral (no AWS terms in core).

### Two registries, two state machines

| | ApiFragmentRegistry | UiFragmentRegistry |
|---|---|---|
| Transitions driven by | **deploy / destroy** of the plugin stack | **connect / disconnect / update** at runtime |
| Commanding actor | the deploy, as SigV4 system caller | the plugin runtime, via handshake |
| Fragment lifetime matches | the resolvers (deployed infrastructure) | the connection (availability) |
| Removal trigger | final retirement / `pulumi destroy` (symmetric deregister) | disconnect / explicit deregister |

Rationale (analysis § 8): resolvers are created *during* the deploy, before the plugin's
runtime can connect (deploy⇄connect circularity); and API fields must outlive volatile
connection state or disconnects would orphan live resolvers. Version supersession must NOT
deregister — the name-keyed registry is overwritten by the successor's deploy; only final
retirement (stack destroyed, resolvers gone) triggers `DeregisterApiFragment`.

### Deploy-side flow (plugin / standalone service deploy)

1. Deploy calls the Platform API mutation `RegisterApiFragment(name, fragment)` with SigV4
   (the Platform API schema exists — pushed at platform bootstrap).
2. Platform automation stitches from the registry's **consistent** state (DCB decision
   read / event fold — NOT an eventually-consistent RM scan) and pushes via
   `updateSchema`; records push status (ok / error + message) on the StateViewSlice.
3. Deploy **waiter** polls the push status (surfacing stitch errors in the deploy output)
   and confirms the plugin's fields via Domain API introspection, then resolver creation
   proceeds. Replaces the `schemaPushed` Output gate
   (`Plugin_Builder.res:584–587`) with the same dependency semantics.
4. `pulumi destroy` of the plugin stack sends `DeregisterApiFragment` before tearing down
   resolvers' API dependencies (ordering: resolvers deleted first, then fields removed).

### What this removes

- The `deploy-schema:*` / `deploy-schema-hash:*` keyspace and paginated scans.
- `withSchemaPushLock` — single-writer automation removes the concurrent-writer root
  cause. The shrink guard is **kept** in the automation as defense-in-depth; the runtime
  drift-repair path remains the safety net.
- The `preResolversSchemaHook` closure and its functor-state capture.
- The dual travel of `apiSchemaFragment` (handshake copy dropped).

### What stays

- **Platform bootstrap exception:** the admin-base push on the Platform API
  (`preAdminResolversSchemaHook`) remains a direct deploy-time push — the irreducible seed
  (full anatomy: analysis § 10). The bootstrap SDL gains the `ApiFragmentRegistry` slice's
  `RegisterApiFragment` / `DeregisterApiFragment` mutation fields, IAM-callable for the
  SigV4 deploy caller — they are what the first domain plugin's deploy calls.
- The runtime re-stitcher (`mkUpdateApiSchema`) — retargeted to read the registry's state
  instead of `deploy-schema:*` rows, keeping cold-start self-healing.
- `GraphQL_Stitcher` math and `Api_Adapter.Provider.updateSchema` — unchanged, now the
  single push path for all providers (AppSync and graphql-yoga on the local platform alike).

### Provider separation

Generic and provider-specific parts stay explicitly separate (audit: analysis § 11):

- **Generic (core / infra):** registry slices, events, state, stitch math
  (`GraphQL_Stitcher`), the single-writer automation logic, the `Api_Adapter.Provider`
  port, and **neutral SDL + structured metadata** (subscription→mutation source mappings,
  auth group per field). No provider directives, no provider terms in names.
- **Provider adapters add their dialect additively:** AWS adds
  `@aws_subscribe`/`@aws_auth`/`@aws_iam` at push time (the pattern
  `injectAwsAuthAll`/`stampSharedIamTypes` already follow); the local platform wires its
  subscription bridge and auth context from the same metadata.
- **Fix the existing inversion:** today core hard-codes `@aws_subscribe` into the admin
  base (`AdminApi.res:44,61`) and into every plugin fragment
  (`Plugin_SubscriptionSchema.res:35`), and the local platform strips it back out
  (`GraphQL_SubscriptionBridge.res:69–72`) and hand-emulates `@aws_auth`
  (`Auth_GraphqlContext.res`). This plan touches exactly these files, so the arrow is
  corrected here: core emits neutral SDL; the AWS adapter injects `@aws_subscribe` from the
  subscription-source metadata; the stripping code is deleted.
- **AWS-only by nature (stays in reventless-aws):** the bootstrap push mechanics
  (`startSchemaCreationRetrying`, `waitForSchemaActive`), the deploy waiter's introspection
  poll, and the SigV4 call plumbing. The local platform needs none of these — it builds its
  schema in-process and its `Admin.construct` hook slot stays `None`.

### Standalone services

A standalone Pulumi program contributing SDL fields calls the same `systemCallable`
`RegisterApiFragment` mutation + waiter — no shared library, no table access, and its fields
participate in every subsequent stitch with full lifecycle handling. This subsumes the
public-API goal of the superseded plan.

## Implementation status (updated 2026-07-12)

**Phase 1 (UiFragmentRegistry) — COMPLETE:**

- **Committed `711581e77`** — the registry as admin DCB slices + command path:
  `UiFragmentRegistry` StateChangeSlice + `UiFragments` StateViewSlice under
  `reventless-core/src/admin/UiFragmentRegistry/`; wired into `Admin.construct` on both
  platforms (this stands up the **first-ever admin DcbEventLog** — the `~stateChangeSlices`/
  `~stateViewSlices` args, previously always `[]`, plus the `dcbPublishJsons →
  publishToAggregates` merge in `Platform_Admin`); a `RegisterUiFragment` command on
  `PluginExtensionPointSpec`; a **second EP mapping** (`Delegate` = the slice — a
  StateChangeSlice Spec structurally satisfies `Aggregate.Spec`) routing
  `RegisterUiFragment`→register and `DisconnectPlugin`→deregister; the connect extension emits
  `RegisterUiFragment` alongside `ConnectPlugin`.
- **Committed `7a47533ac`** — `Platform_UIFragments` retargeted to the new `UiFragments` table
  (encoder + in-memory resolvers + AWS Lambda mounts); local `connectPlugin` routes the
  manifest through the admin EP so the slice populates in-process; slice GWT tests.
- **Increment 5+6 (this commit)** — the old path removed wholesale:
  - `UIFragmentRegistered/Updated/Deregistered` dropped from the Plugin aggregate
    (`PluginSpec`/`PluginBehavior`/`PluginsProjection`/EP outgoing mapping); `uiFragments`
    dropped from `pluginDefinition` AND from `PluginsReadModelSpec` — lifecycle only now.
  - The manifest reaches the Connect extension via a new `Spec.uiFragments` field:
    deploy-time threading from `builderOutputs.uiFragments`; on AWS shipped as a new
    `uiFragments.json` asset next to `pluginDefinition.json` (eventCollectorContext gained
    `uiFragmentsJson`; `AdminEventCollectorEntryPoint.mjs` loads it, tolerating absence).
    `Plugin.make(~uiFragments)` API and generated example `Plugin.res` files unchanged.
  - Old `UIFragmentRegistryReadModelSpec`/`UIFragmentRegistryProjection` deleted; AWS
    `UIFragmentRegistryReadModel` wiring removed (`UiFragments` slice takes the Postgres
    admin exemption); local seed store (`seedUIFragmentRegistryQueryDb`) removed.
  - Local `onUIFragmentChange` re-sourced from the UiFragmentRegistry slice's events on the
    admin DcbEventLog bus topic (`AdminEventTopic`, service `AdminDcbEventLog`);
    `decodeUiFragmentRegistryEventEnvelope` is top-level + regression-tested.
  - Old GWTs deleted (coverage already ported: `UiFragmentRegistry_GWT` + `UiFragments_GWT`);
    UIFragment cases stripped from `PluginBehavior_GWT`/`PluginsProjection_GWT`/fixtures.

**Defects found by end-to-end verification (fixed in increment 5+6):**

- The prior increment's local EP dispatch was dead code: the local platform constructs **no
  admin Plugin EP component** (`Admin.construct(~extensionPoints=[])`), so `RegisterUiFragment`
  parked forever in the LocalBus pending queue and the slice never populated. Local now
  dispatches the slice command directly to the shared admin DCB command topic
  (`AdminDcbCmdTopic`, routed by command tag) — the local analogue of the EP mapping, mirroring
  how `Connect` already bypasses the EP in-process. (Local deregistration-on-disconnect is moot:
  plugins share the platform process lifetime.)
- `StateChangeSlice_Callback.encodeEvent` serialized produced events with `JSON.stringifyAny`
  (runtime representation) instead of the event schema — `None` option fields (e.g. the
  manifest's `requiredAccess`) were dropped from the payload, and the consumer-side
  `DcbDecode` (js_nullable expects `T | null`, rejects missing) discarded the event as schema
  drift. Now encodes via `S.reverseConvertToJsonOrThrow(Spec.eventSchema)`, symmetric with the
  Aggregate path's `Message.encode`. This latent bug affected any DCB slice event carrying
  option fields.

**End-to-end validated** (hybrid example, in-memory, `CATALOG_UI_BUNDLE_URL` set):
`Platform_UIFragments` returns the Catalog fragment from the slice path; admin-DCB
publish/subscribe topic + service stamp verified; envelope decode verified. Note the entry
`pluginId` is now the bare plugin name (registry keyed by name), no longer `name@version`.

**Decisions / refinements made during implementation (deviations from the plan text):**

- **Admin hosting is DCB slices** (user-confirmed): the plan assumed slices are freely
  available as platform components, but every existing admin component was aggregate+RM and
  the DcbBuilder path was dormant. Confirmed viable; Phase 1 stands up the admin DcbEventLog
  now (so the plan's "low risk" label for Phase 1 was optimistic).
- **Deregistration rides `DisconnectPlugin`** through the second EP mapping — no automation
  slice (honours "composition stays lazy / no automation"). The disconnect schedule already
  sends `DisconnectPlugin` on heartbeat timeout, so timeout and graceful disconnect both
  deregister. (Known gap kept for now: admin `Deactivate`/`Retire` don't flow through the EP,
  so they don't deregister — acceptable per the analysis's blessed UI staleness.)
- **Timestamps ride the command `at` field** — a StateViewSlice `project` gets no event meta,
  so `registeredAt`/`updatedAt` are threaded from the incoming command's `meta.time` by the EP
  mapping.
- **`uiFragments` no longer rides `pluginDefinition`** (dropped in increment 5); the connect
  extension reads it from its own `Spec.uiFragments` field instead.
- **Validation boundary:** Jest cannot import/boot the real `Platform` (ESM), so there is no
  in-process end-to-end query proof in Jest — only slice-logic GWT tests + the full build.
  True end-to-end is booting an example platform / a deploy — increment 5+6 did exactly that
  and it caught two real defects (see below), so treat a live boot + `Platform_UIFragments`
  query as the required gate for the remaining phases too.

**Phase 2 — IN PROGRESS:**

- **Increment 2a (this commit) — dialect neutralization** (the plan's "@aws_subscribe moves
  out of core" work item, done first so the registry/automation push path is built on
  neutral SDL):
  - `GraphQL_Stitcher.fragmentParts` gains `subscriptionSources: array<{field, mutations}>`
    — the neutral subscription→mutation carrier (encode/decode round-trip it; decode
    tolerates pre-existing fragments; `collectSubscriptionSources` unions across fragments,
    first-wins per field, matching `stitch`'s dedupe). The fan-in case
    (`onUIFragmentChange` ← three mutations) that is NOT derivable from field names is
    carried explicitly.
  - Core emits neutral SDL: `Plugin_SubscriptionSchema.sourceCFields` returns
    `(fields, sources)`; `AdminApi` subscription constants are directive-free with
    exported `*SubscriptionSource` records; `GraphQL_FragmentGenerator` and the two
    `AppSync_Adapter` injectors re-encode via `GraphQL_Stitcher.encode` so the metadata
    survives decoration.
  - AWS adds its dialect at push time: new **runtime-pure** `AppSync_SdlDecorate.res`
    (`injectAwsSubscribe` on the stitched SDL's Subscription block) — kept out of
    `AppSync_Adapter` so `AdminEventCollectorEntryPoint.mjs` can import it without
    re-introducing the @pulumi runtime-graph leak. All four ReScript push sites now go
    through one `AppSync_Adapter.stitchWithAwsDirectives` (collect → stitch →
    injectAwsSubscribe → stampSharedIamTypes); the mjs runtime re-stitcher mirrors it.
  - Local stripping deleted: `GraphQL_SubscriptionBridge` registers fields as-is; the
    local admin subscription registration now reuses the (neutral) `AdminApi` field
    constants instead of hand-duplicated strings.
  - Validated: full builds zero-warning; core 517 / aws 214 / local 492 tests green
    (new: stitcher subscriptionSources suite incl. a no-provider-directives guard on the
    admin base fragment; `AppSync_SdlDecorateTest`); live boot of the hybrid example
    (in-memory) — both yoga APIs build from neutral SDL, subscription fields introspect
    on both, `Platform_UIFragments` serves the Catalog fragment with Admin gating intact.

- **Increment 2b (this commit) — the ApiFragmentRegistry as admin DCB slices**, mirroring
  Phase 1's UiFragmentRegistry pattern:
  - `ApiFragmentRegistry` StateChangeSlice + `ApiFragments` StateViewSlice under
    `reventless-core/src/admin/ApiFragmentRegistry/`; wired into all five `Admin.construct`
    sites (2 AWS, 3 local) alongside the UI slices — first time two StateChangeSlices share
    the admin DCB command topic / DcbEventLog; `QueryDbBackend.exempt(ApiFragments.name)`
    on AWS (admin store, off Postgres).
  - Commands `RegisterApiFragment` / `DeregisterApiFragment` / **`RecordApiFragmentPush`**
    (the single-writer automation's write-back of the push outcome, added here so the slice
    contract is complete before the automation lands) → events `ApiFragmentRegistered` /
    `ApiFragmentUpdated` / `ApiFragmentDeregistered` / `ApiFragmentPushRecorded`. Name-keyed
    (bare plugin name), fully idempotent incl. at-least-once redelivery of push records
    (deduped on the full (ok, message, at) payload).
  - View state: `{pluginId, encoded, protocol, registeredAt, updatedAt, pushStatus
    (pending|ok|error), pushMessage, pushedAt}` — plain strings, no option fields in
    variant payloads (avoids the js_nullable T|null wire hazard); a fragment change resets
    the row to `pending`.
  - GWT coverage: `ApiFragmentRegistry_GWT` (9 cases) + `ApiFragments_GWT` (5 cases) in
    reventless-local/tests/plugin/.
  - NOT in this increment: nothing populates the registry yet — the GraphQL mutation
    surface (2d), the local in-process dispatch, and the deploy caller (Phase 3) come
    later; the automation (2c) is the first consumer.

- **Increment 2b-fix — `apiTarget` dimension.** The Platform API is not admin-only: plugins
  can be assigned `apiTarget = Platform` (e.g. a platform inspector) and contribute fields to
  the Platform-API schema alongside the admin base, exactly as Domain-target plugins do to the
  Domain API (the current push already splits this via the `deploy-schema:` vs
  `deploy-schema-platform:` keyspaces). So the registry is **per-target**: a new
  `@schema type apiTarget = Domain | Platform` in `Reventless.Plugin` (spec, serializes as the
  bare string), threaded through `RegisterApiFragment` and the Registered/Updated events, the
  behavior's registry entry (idempotency now compares fragment AND target — a same-SDL retarget
  is a real `ApiFragmentUpdated`, moving the fields between APIs), and the `ApiFragments` view
  row. The single writer (2c) groups fragments by target and maintains **one cumulative schema
  per API** (Platform API = admin base + Platform-target fragments; Domain API = empty/admin
  base + Domain-target fragments) — replacing both deploy-schema keyspaces. Two extra GWT cases
  cover retargeting.

- **Bootstrap-push decision (recorded):** the bootstrap admin-base push STAYS and is not
  replaced by a declarative Pulumi `GraphQLSchema` resource. Reason: the Platform API is itself
  a cumulative/stitched schema (admin base is the *seed*, grown by Platform-target plugins), so
  a declaratively-owned schema would drift against those plugins' whole-replace pushes — the
  same conflict as unified mode. The bootstrap is irreducible for two reasons now: (1) the
  chicken-and-egg (the registration mutation must exist before any plugin can call it) and
  (2) the admin base is a growing schema's seed, not a static artifact.

**Decisions for 2c–2e (user, 2026-07-12):**

- **Unified mode is kept.** The single writer branches on split/unified: split → group
  fragments by `apiTarget` and push two schemas (Platform API = admin base + Platform-target
  fragments; Domain API = empty base + Domain-target fragments); unified → one API, stitch
  admin base + all fragments regardless of target.
- **The deploy waiter polls a status query**, not schema introspection. So the bootstrap seed
  SDL gains — alongside the `RegisterApiFragment`/`DeregisterApiFragment` mutations — an
  IAM-callable status query over the registry (`Platform_ApiFragments`, exposing
  `pushStatus`/`pushMessage`/`pushedAt` per plugin) that the deploy reads to confirm ACTIVE /
  surface a stitch error.
- **Single writer = the generalized runtime re-stitcher** (not an AutomationSlice — its
  `process` is sync, single-event, command-only). 2c and 2e are therefore the same code path:
  a platform-hosted subscriber on the admin DcbEventLog that, on any `ApiFragment*` event,
  re-folds the registry, stitches per target, calls `Api_Adapter.Provider.updateSchema`, and
  emits `RecordApiFragmentPush`. Generic orchestration in core; only `updateSchema` (AppSync
  push vs. local in-process rebuild) and the hosting (AdminEventCollector Lambda vs. in-process
  bus subscriber) are provider-specific.
- **Local harmonizes the registry contract, not the schema build (scope 1, revised
  2026-07-12).** Investigation of `DomainGraphQL_Server.rebuildSchema` disproved the original
  scope-1 premise: on local the Query/Mutation/Subscription **fields come from resolver
  registration** (`CommandGeneratorResolvers_GraphQL`/`QueryDbResolvers_GraphQL` register each
  field *together with its resolver function* at plugin construction — graphql-yoga couples
  `typeDefs`+`resolvers`); `rebuildSchema` only merges the fragment's *types*. So the
  `apiSchemaFragment` is not the field source on local, and making the registry drive the local
  schema *build* would require decoupling field-SDL from resolver registration — a local-internals
  refactor that belongs to scope 2. **Phase 2 local scope:** (a) `connectPlugin` dispatches
  `RegisterApiFragment(fragment, Domain)` so the registry is real in-process; (b) a local
  single-writer subscriber on the admin DcbEventLog reacts to `ApiFragment*` events and dispatches
  `RecordApiFragmentPush(ok=true)` — the "push" is a no-op locally because the fields are already
  served by resolver registration, so recording success is honest and avoids a redundant rebuild;
  (c) a shared `Platform_ApiFragments` status query resolves on local by scanning the ApiFragments
  view. Uniform in *shape* (register → subscriber → record) and in the registry/status contract;
  the actual reactive schema *build* is AWS-only in Phase 2.
- **SCOPE 2 — FOLLOW-UP (deferred, do NOT fold into Phase 2):** harmonize the local schema build
  + deploy lifecycle to mirror AWS — decouple field-SDL from resolver registration so the registry
  drives the local schema, and stage separate platform-deploy then per-plugin-deploy phases
  instead of `makePlatform(~plugins=[…])` constructing everything at once. Valuable for test
  fidelity; a substantial reventless-local refactor, tracked in
  `docs/plans/Backlog/harmonize-local-deploy-lifecycle.md`.

- **Increment 2c (this commit) — local registry population + status query (scope 1).**
  - Core: `Platform_ApiFragmentsApi.res` — shared SDL type + `Platform_ApiFragments` query
    field + status-only encoder over `ApiFragments.state` (pluginId, apiTarget, pushStatus,
    pushMessage, pushedAt, registeredAt, updatedAt — NOT the encoded SDL). The query field +
    type join `AdminApi.baseFragment`, so they're in the admin schema on both platforms (and
    the bootstrap seed). Golden encoder test pins the wire shape.
  - Local: `connectPlugin` dispatches `RegisterApiFragment(fragment, Domain)` (mirroring
    `dispatchUiFragmentCommand`); a record-ok single-writer subscriber on the admin DcbEventLog
    reacts to `ApiFragmentRegistered`/`Updated` and dispatches `RecordApiFragmentPush(ok=true)`
    (the push is a no-op locally — fields already served by resolver registration — so success
    is honest; no re-entrant loop since `PushRecorded` is ignored); the `Platform_ApiFragments`
    resolver scans the `ApiFragments` view at all three admin server sites.
  - Validated live (hybrid, in-memory): `Platform_ApiFragments` returns Catalog + Ordering with
    `apiTarget:"Domain"`, `pushStatus:"ok"`; UI query + domain plugin fields intact; zero boot
    errors. Suites green: core 517 (+7), aws 214, local 508.
  - NOT here: the AWS resolver for `Platform_ApiFragments` and the reactive push (2e); the
    Register/Deregister *mutations* + deploy caller (2d); the local schema *build* still comes
    from resolver registration (registry-as-source is scope 2).

**Design for 2d–2e (AWS side, from the seam map 2026-07-12) — NOT yet built:**

The whole AWS side is deploy-time Pulumi wiring (AppSync/Lambda/DynamoDB) and **cannot be
validated locally** the way 2a–2c were — the only real validation is an actual AWS deploy (an
alpha push auto-deploys the hybrid example + rebuilds the layer). 2d and 2e are intertwined (the
mutations are inert until 2e's reactive push consumes the registry), so they are one AWS cluster
sharing that deploy-validation path. Until a deploy, these increments are compile-validated only.

- **2d de-risk COMPLETE (2026-07-12) — approach chosen: API-expose the slice** (user-confirmed).
  The seam map answered the "hard part" (step 4): the admin DCB command-handler Lambda's ARN is
  **not** reachable from the bootstrap admin-API wiring — it lives only as `runtime.parts.lambda`
  inside the DCB builder's `connect` callback (`Dcb_Builder.res:755`), never surfaced in any
  `outputs` record. So do *not* try to bind a hand-written resolver to it. Instead reuse the
  existing plugin-DCB seam verbatim by making the `ApiFragmentRegistry` slice API-visible: the
  `if dcbFieldNames->Array.length > 0` gate then fires `dcbAppSyncResolverHook` → `makeDcb`, which
  binds a `DcbMutation` DataSource to the **admin** Lambda's ARN (from `runtime.parts.lambda`) with
  `invokeDcbMutation(tag)` resolvers; the shared `DcbCommandTopicEntryPoint.mjs` already routes the
  `{command, arguments}` payload by TAG. Zero net-new DataSource/ARN plumbing.

  Two facts the seam map surfaced that shape the implementation:
  - **Only the static `AdminApi.baseFragment` is pushed** to AppSync (`Platform.res:742-757`,
    `StartSchemaCreation` whole-replace with `pluginFragments=[]`); the constructed `adminFragment`
    is never pushed on AWS. So the mutation SDL must be declared in `AdminApi.baseFragment`, and the
    auto-bound resolver field names must **match** it exactly, or CreateResolver fails.
  - **Naming reconciliation.** DCB auto-naming is `${plugin}_${command}` with `plugin="Admin"` →
    `Admin_RegisterApiFragment`, but the admin API convention is `Platform_*`
    (`adminField(n) = "Platform_${n}"`). Fix: thread an `~apiNamePrefix` (default `name`) through
    `Dcb_Builder`'s StateChangeSlice mutation-naming sites; the admin builder passes `"Platform"`,
    so `dcbCommandMutationField(~plugin="Platform", …)` = `Platform_RegisterApiFragment`, byte-equal
    to `adminField("RegisterApiFragment")`. Plugins are unaffected (default prefix).

  **Coherence fix (found during de-risk, widens 2d):** the admin StateChangeSlices carry **no**
  `@noApi` today, so on AWS they would already generate orphaned `Admin_Register*` resolvers against
  a schema lacking those fields — the admin-DCB GraphQL surface has simply never been
  deploy-validated (Phase 1/2b were in-memory-only). 2d makes it coherent for the first time:
  - `UiFragmentRegistry` command → **whole-command `@noApi`** (connect/handshake-driven, no GraphQL
    surface by design). Fixes the shipped Phase-1 slice's latent AWS breakage.
  - `ApiFragmentRegistry.RecordApiFragmentPush` → **variant-level `@noApi`** (internal single-writer
    write-back). `RegisterApiFragment`/`DeregisterApiFragment` stay exposed → two `Platform_*`
    mutations.

  Concrete steps:
  1. `@noApi` markers as above (core slices).
  2. `Dcb_Builder`: add `~apiNamePrefix=name`; use it in the StateChangeSlice mutation-naming
     sites. `Platform_Admin.construct` passes `~apiNamePrefix="Platform"` +
     `~systemCallableComponents=["ApiFragmentRegistry"]`.
  3. `AdminApi.res`: add ApiFragmentRegistry Register/Deregister as a `mutationSchemaEntry`
     (field names via `adminField`, commandSchema-driven so args + `Platform_ApiFragmentInput` input
     type + `CommandResult!` return are generated), appended to `mutationEntries` → lands in
     `baseFragment`. Mirrors `PluginBaseFragment.pluginAggregateMutationEntries`.
  4. `reventless-aws/src/Platform.res`: thread
     `~iamFieldNames=["Platform_RegisterApiFragment","Platform_DeregisterApiFragment","Platform_ApiFragments"]`
     into the bootstrap `injectAwsAuthAll` (currently none) for SigV4 dual-auth; repoint
     `hooksApiRef → platformApi` around `Admin.construct` (split mode) so admin DCB resolvers land
     on the Platform API, not the Domain API; clone `Platform_UIFragments_Lambda.res` →
     `Platform_ApiFragments_Lambda.res` (env `API_FRAGMENT_RM_TABLE`, `dynamodb:Scan`, encode via
     `Platform_ApiFragmentsApi`), mount at both admin sites keyed on
     `stateViewSlicesOutputs["ApiFragments"]`.

  Validation net: the **local platform** exercises the core parts (SDL generation, `@noApi`, prefix
  threading, exposure coherence) via a live boot; the AWS-only parts (iamFieldNames, hooksApiRef,
  status Lambda) are compile-validated until a deploy.
- **2e — AWS reactive single writer.** Retarget `mkUpdateApiSchema`
  (`AdminEventCollectorEntryPoint.mjs`) to trigger on `ApiFragment*` events, fold the registry by
  target, stitch per target (a small generic `planPushes` in core: split → per-target push,
  unified → one API all fragments), push via `updateSchema`, and dispatch `RecordApiFragmentPush`
  with the outcome. The shrink guard stays as defense-in-depth.
- **Deploy caller is Phase 3, not 2d.** `Util_AppSync_Caller.sendMutation`/`sendQuery` already
  support nested-object args + SigV4 signing (no changes needed); the invocation site in the
  plugin deploy flow is Phase 3.

**Increment 2d — IMPLEMENTED (core + AWS-mechanical), local-validated (this session):**

- **Core (built zero-warning, live-boot validated on the hybrid example, in-memory):**
  - `@noApi` coherence fix: `UiFragmentRegistry` command carries **whole-command `@noApi`**
    (connect/handshake-driven, no GraphQL surface); `ApiFragmentRegistry.RecordApiFragmentPush`
    carries **variant-level `@noApi`** (internal single-writer write-back). This also removes the
    latent orphaned-`Admin_Register*`-resolver hazard the never-deploy-validated admin-DCB path
    carried for the shipped Phase-1 UI slice.
  - `Dcb_Builder.construct` gains `~apiNamePrefix=name`, threaded into all six StateChangeSlice
    mutation-naming sites; `Platform_Admin.construct` passes `~apiNamePrefix="Platform"` +
    `~systemCallableComponents=["ApiFragmentRegistry"]`. Plugins unaffected (default prefix).
  - `AdminApi.apiFragmentRegistryMutationEntries` (derived from the slice `commandSchema` via the
    same `sliceMutationFields` call, admin `Platform` prefix) folded into `baseFragment`'s own
    `generate` call — NOT the shared `mutationEntries` (the constructed admin fragment gets them
    from `dcbResult.mutationEntries`; the fold keeps the shared `seenTypes` from re-emitting the
    `CommandResult` family, avoiding duplicate type defs). `AdminApi.systemCallerFieldNames` +
    `Platform_ApiFragmentsApi.queryFieldName` exported for the AWS adapter.
  - **Live boot proof:** Platform API exposes `Platform_RegisterApiFragment` /
    `Platform_DeregisterApiFragment` (byte-aligned `Platform_*` naming) + `Platform_ApiFragments`,
    with **no duplicate fields/types**, no `Platform_RegisterUiFragment` (UI slice `@noApi`), admin
    auth-gating intact, and connect-time `RegisterApiFragment` dispatch still works for
    Catalog/Ordering. Local fragment GWTs 24/24 green; core `GraphQL_StitcherTest` admin-base
    "no provider directives" guard still satisfied (added mutations are neutral SDL).

- **AWS-mechanical (built zero-warning, compile-validated only — needs a deploy):**
  - `~iamFieldNames=AdminApi.systemCallerFieldNames` threaded into all four admin-base
    `injectAwsAuthAll` sites (bootstrap + Platform-target + unified-Domain + makePlatform-unified).
  - `Platform_ApiFragments_Lambda.res` cloned from the UI one (env `API_FRAGMENT_RM_TABLE`,
    `dynamodb:Scan`, status-only projection matching `Platform_ApiFragmentsApi`), mounted at both
    admin sites keyed on `stateViewSlicesOutputs["ApiFragments"]`.

- **2d `hooksApiRef → platformApi` for the admin DCB resolver — IMPLEMENTED (built zero-warning
  across core/aws/local; deploy-validated).** The seam analysis confirmed this is NOT a mechanical
  edit: `makePlatform` sets `hooks.api := domainApi` and its plugins (built after `Admin.construct`)
  read that same ref in *deferred* callbacks, while the admin DCB resolver hook reads `hooks.api`
  in a deferred callback too but needs `platformApi` in split mode — so a global flip or a
  set/reset around `Admin.construct` can't work. (The admin *aggregate* resolvers dodge this: on AWS
  `mutationResolverHook` is `None`, so they bind via the CommandGenerator auto-flow using the `~api`
  passed to `Admin.construct`.) Implemented as a **dedicated admin-api capture**: `dcbAppSyncResolverParams`
  gains `onAdminApi: bool`; `platformHooks` gains an `adminApi` ref; `Dcb_Builder.construct` gains
  `~onAdminApi=false` (admin passes `true`) threaded into the hook payload; the AWS
  `dcbAppSyncResolverHook` binds `makeDcb(~api = onAdminApi ? resolveAdminHookedApi() : resolveHookedApi())`,
  and `makePlatform`/`deployPlatform` set `hooks.adminApi := Some(platformApi)` once the Platform API
  resource exists. Plugins are unaffected (`onAdminApi=false` → `hooks.api` as before). Local carries
  an inert `adminApi: ref(None)` (single in-memory schema). Fixes the split-mode
  `CreateResolver(Platform_RegisterApiFragment)`-on-DomainApi failure. (The shipped UI slice had the
  same latent misroute; removed by its `@noApi` marker.)

- **2e core `planPushes` — IMPLEMENTED + unit-tested (`GraphQL_PushPlannerTest` 4/4 green).**
  `GraphQL_PushPlanner.planPushes(~adminBase, ~fragments, ~splitApi)` groups registered fragments by
  `apiTarget` and returns one stitched neutral-SDL push plan per API, encoding the same base-selection
  rules as the deploy-time push (split → Platform API = admin base + Platform frags, Domain API =
  empty base + Domain frags; unified → one API = admin base + all frags). Provider-neutral (the AWS
  adapter injects `@aws_subscribe` per plan and maps `PlatformApi`/`DomainApi` → the AppSync ids).

**Increment 2e — IMPLEMENTED (core + AWS-mechanical), compile-validated + unit-tested
(this session). Deploy-validation pends Phase 3** (nothing calls `RegisterApiFragment` on
AWS until the deploy caller lands, so no `ApiFragment*` events fire yet).

- **Linchpin resolved — how `ApiFragment*` events reach the AdminEventCollector.** The admin
  DcbEventLog has **no SNS topic** on AWS; its "EventTopic" is the DcbEventLog table's **DynamoDB
  stream**, and the admin EC was subscribed only to the Plugin ExtensionPoint's SNS topic (Plugin
  *aggregate* events), never to the DCB-slice stream — so the DCB-slice→admin-EC path had never
  existed on AWS (Phase 1/2b were in-memory only; the `AllStateViewSlices` projection Lambda was the
  stream's sole consumer). **Fix (user-chosen: admin EC as 2nd stream reader):** thread
  `dcbResult.dcbEventLogOutputs.eventTopic` into the admin EC's `~eventTopics`
  (`Platform_Admin.res`, copied dict so the shared aggregate outputs stay untouched) — the
  EventCollector channel already provisions the DynamoDB-stream EventSourceMapping + read IAM. Known
  constraint: DynamoDB streams allow ~2 concurrent shard readers; `AllStateViewSlices` + admin EC =
  the limit, no headroom for a third consumer (would need SNS/Kinesis fan-out).
- **Reactive single writer, ADDITIVE** (the legacy connect-driven `mkUpdateApiSchema`,
  `deploy-schema:*` → single Domain API, stays until Phase 4). On any `ApiFragmentRegistered` /
  `Updated` / `Deregistered` stream event (NOT `ApiFragmentPushRecorded` — avoids the write-back
  loop; `UiFragment*` ignored by prefix), the admin EC re-folds the registry and pushes one
  AppSync-decorated schema per target API, then dispatches `RecordApiFragmentPush` per triggering
  plugin onto the admin DCB command topic. The `handler` splits records: DcbEventLog **stream**
  records drive the reactive push; everything else (Plugin-aggregate lifecycle SNS→SQS) still goes
  to the plugin callback (which has no handler for DCB-slice events). Non-admin ECs and
  all-at-once `makePlatform` keep the config placeholders → the reactive push stays dormant.
- **Consistency:** the RM scan of `ApiFragments` races the (separate) `AllStateViewSlices`
  projection consumer, so the triggering batch's own fragment payloads (carried in the stream
  records) are **overlaid** on the scan (Register/Update set, Deregister removes) — the plan's
  "stitch from consistent state, not an eventually-consistent RM scan", scoped to the batch.
- **Push decoration = deploy-path parity.** New runtime-pure
  `AppSync_SdlDecorate.planAwsPushes(~rawAdminBase, ~iamFieldNames, ~fragments, ~splitApi)` reuses
  core `GraphQL_PushPlanner.planPushes` for base-selection + stitch, then applies the AppSync
  dialect exactly as the deploy path's `stitchWithAwsDirectives`: the admin base is auth-decorated
  (`injectAwsAuthAll` group "Admin" + dual-auth on `AdminApi.systemCallerFieldNames`) *before*
  stitch, `@aws_subscribe` from the neutral `subscriptionSources`, and shared traversal types
  stamped on the assembled SDL. Plugin fragments already carry their own per-field `@aws_auth`
  (baked at `generateFragment`), so they stitch in as-is. `injectAwsAuthAll` + `stampSharedIamTypes`
  moved into runtime-pure `AppSync_SdlDecorate`; `AppSync_Adapter` now delegates to them (no
  Pulumi in the runtime graph). **Unit-tested** (`AppSync_SdlDecorateTest`, +2 cases): split-mode
  Platform/Domain separation, dual-auth on system-caller fields, shared-type stamping, unified mode.
- **Deploy-time config (deployPlatform only — the staged path where `RegisterApiFragment` fires;
  `makePlatform` builds the full schema at deploy time and never calls it).** Four new
  `HANDLER_CONFIG` fields threaded via `registerConfig` at `Platform.res:1807` (read lazily by
  `forPluginEventCollector`, so post-`Admin.construct` values are available): `platformApiId`
  (`platformApi.id`; unified → domain id), `apiFragmentRegistryTableName`
  (`admin.stateViewSlicesOutputs["ApiFragments"].queryDb.resources[0].name`), `adminDcbCmdTopicUrl`
  (`AutomationSliceRuntime_Builder_Single.getDcbQueueUrl()`, captured by `onDcbCommandTopicCreated`
  during construct), `splitApi`. New admin-EC IAM: `dynamodb:Scan` on the ApiFragments table +
  `sqs:SendMessage` on the admin DCB command topic (URL→ARN); AppSync `StartSchemaCreation` /
  `GetIntrospectionSchema` already granted on `AllResources` (covers the Platform API).
- **Validation net:** compile zero-warning across core/aws/local; suites green (core 528, aws 216
  incl. the 2 new `planAwsPushes` cases, local 508). The whole AWS reactive path (stream ESM,
  IAM, config threading, mjs handler) is compile-validated only — real validation is a deploy, and
  it is inert until Phase 3 supplies a `RegisterApiFragment` caller. Build it deploy-validated as a
  unit with the Phase-3 deploy caller.

**Phase 3 — deploy caller + waiter — IMPLEMENTED (this session), compile-validated
(deploy-validated together with 2e on the next alpha push).**

- **Gated on `platformStackRef`, not a wholesale hook replacement.** `preResolversSchemaHook`
  fires in BOTH `makePlatform` (all-at-once, `platformStackRef=None`, reactive writer dormant) and
  `deployPlugin` (staged, `platformStackRef=Some`, 2e wired). Replacing the body outright would
  break `makePlatform` (fragments would register but never push). So: `Some(_)` → new
  `registerFragmentViaApi`; `None` → the old direct deploy-time stitch+push **unchanged** (retired
  for `makePlatform` only in Phase 4, if at all). The `registerFragmentViaApi` helper +
  `waitForApiFragmentPush` live before the hooks record in `Platform.res`.
- **The caller** (`registerFragmentViaApi`, returns the `schemaPushed` Output gate): resolves the
  Platform API endpoint (`apiConfigRef.platformApi.uris.graphQL`) + region, then
  `Util_AppSync_Caller.sendMutation("Platform_RegisterApiFragment", {id, pluginId, fragment:{encoded,
  protocol}, apiTarget: <graphqlEnum>, at})` (SigV4). Exact SDL from the generator:
  `Platform_RegisterApiFragment(id: ID!, pluginId: ID!, fragment: <input>!, apiTarget: <enum>!,
  at: String!): CommandResult!` — `id: ID!` is unconditionally prepended by
  `GraphQL_FragmentGenerator` (set to the pluginId); `apiTarget` is a generated GraphQL **enum**
  (passed via `graphqlEnum` so it renders unquoted). Registry keyed by bare plugin **name**.
- **The waiter** disambiguates the common idempotent-redeploy case from a real change without a
  false timeout: `sendMutation` now **returns its result** (safe — zero prior callers), and the
  caller reads the `CommandResult` selection — `CommandRejected` → fail the deploy;
  `CommandAccepted{eventCount:0}` → idempotent no-op (fields already live) → proceed immediately;
  `eventCount>0` → poll `Platform_ApiFragments` (no-arg query, filter client-side by pluginId)
  until a **fresh** push (`pushedAt >= our registration `at``, beating the stale-`ok` race) shows
  `ok` (proceed) or `error` (fail with `pushMessage`); ~3-min timeout. Preserves the resolver-
  creation ordering gate (`Plugin_Builder.res:585` → `all3`/`all6`).
- Validated: aws builds zero-warning; suites green (aws 216). The whole SigV4 path is
  compile-validated only — real validation is the alpha deploy that also exercises 2e (the first
  `RegisterApiFragment` call fires the first `ApiFragment*` event → the 2e reactive push).

**Phase 3 tail — destroy-path deregistration — IMPLEMENTED (this session), compile-validated
(exercised only by a real `pulumi destroy`).** New `ApiFragmentDeregistration.res` — a Pulumi
**dynamic provider** (precedent: `AppSync_Resolver_Retrying.res`) created per plugin inside
`registerFragmentViaApi` (plugin-stack mode). `create`/`update` are no-ops; `delete` sends
`Platform_DeregisterApiFragment` on stack teardown, whose event triggers the 2e reactive push to
re-stitch without the plugin's fields. Key decisions:
  - **Serialization-safe:** the provider closure is serialised into stack state, so it must not
    statically capture the AWS SDK (the CJS/ESM serialiser hazard the resolver provider documents).
    The `delete` handler `dynImport`s `Util_AppSync_Caller` at invocation — only the string
    specifier lands in state — reusing the proven SigV4 `sendMutation` instead of re-implementing it.
  - **Version supersession must NOT deregister:** `diff` always returns `changes:false, replaces:[]`,
    so a version bump updates in place (no delete); only a genuine `pulumi destroy` fires `delete`.
  - **Carrier via id:** Pulumi passes outputs (possibly undefined) to `delete`, so the resource id
    encodes `pluginId|region|endpoint`; `delete` decodes it (falls back to props).
  - **Best-effort:** `delete` swallows errors — on a full teardown the platform API may already be
    gone, and a destroy must not fail because deregistration couldn't reach it.
Validated: aws builds zero-warning; suites green (aws 216). Ordering note: not forced relative to
resolver deletion — the transient inconsistency during a dying stack's teardown is harmless (this
plugin's resolvers are being deleted anyway; other plugins unaffected).

**Deploy validation #1 (2026-07-13) — FAILED then FIXED (fix compile/test-validated, re-deploy
pending).** The first alpha push that deploys 2b–2e + Phase 3 together (the whole new path) ran the
staged `deployPlatform` job and **failed at "Deploy Platform"** — one Pulumi error:

```
aws-native:appsync:Resolver PlatformApiFragmentsResolver creating failed
  error: operation CREATE failed with "NotFound":
  No field named Platform_ApiFragments found on type Query
```

Everything else came up (the `ApiFragmentRegistry`/`ApiFragments` + `UiFragmentRegistry`/`UiFragments`
slices, `AdminDcb` command topic, `Admin` DcbEventLog + EventTopic + 2nd-reader EventCollector,
tables, the `Platform_ApiFragments` Lambda + DataSource). **Root cause:** the two Lambda-backed admin
status-query resolvers (`Platform_UIFragments`, `Platform_ApiFragments`) are mounted from
`Platform.res` *outside* `Platform_Admin.construct`, so — unlike the admin DCB resolvers, which chain
behind `adminSchemaPushed` — their `CreateResolver` was **not gated on the bootstrap schema push**
(`preAdminResolversSchemaHook`). Because `Platform_ApiFragments` is a first-ever-deployed field, the
ungated `CreateResolver` raced `StartSchemaCreation` and ran before the field was ACTIVE →
`NotFound`. `Platform_UIFragments` had the identical latent bug but survived only because its field
predated this deploy (already ACTIVE from a prior push). The DCB mutation resolvers
(`Platform_RegisterApiFragment`/`Deregister`) were correctly gated and never reached (Pulumi aborted
first) — so this was the sole seam, exactly the "resolver field names must match the pushed
`baseFragment` or CreateResolver fails" hazard the 2d seam map flagged, but the missing piece was
*timing* (gating), not the field being absent from `baseFragment` (it is present, [AdminApi.res:147]).

**Fix:** `Platform_Admin.construct` now returns `adminSchemaPushed: Pulumi.Output.t<unit>` (the push
Output; an already-resolved unit in-memory). Both `Platform_UIFragments_Lambda.make` and
`Platform_ApiFragments_Lambda.make` gain a `~schemaReady` param and create their resolver inside
`schemaReady->Pulumi.Output.apply(...)` (mirroring the admin DCB resolvers' gate); `Platform.res`
passes `~schemaReady=admin.adminSchemaPushed` at all four mount sites. Validated: core builds
zero-warning, aws 216 / local 508 green. Like the rest of the AWS deploy path this is
compile/test-validated only — **re-validation is the next alpha push** (should get past this resolver;
watch for the first real `RegisterApiFragment` → `ApiFragment*` event → 2e reactive push).

**Deploy validation #2 (2026-07-13) — got past #1's resolver, hit two DEEPER bugs, both
FIXED (fix compile/test/local-boot-validated, re-deploy pending).** With the schema-push gate
in place, `PlatformApiFragmentsResolver` + `Platform_RegisterApiFragment` created successfully —
but the admin-DCB-on-AWS GraphQL surface (never deploy-validated before) failed with **9 errored**:

- **Bug A (fatal `TypeError: tableOutput.apply is not a function`)** in the 2e reactive-push config
  threading (`PluginRuntime_Builder.forPluginEventCollector`). Root cause (runtime-traced): the
  config field `apiFragmentRegistryTableName: option<Pulumi.Output.t<string>>` is the forbidden
  `option<Output>` pattern (CLAUDE.md code smells). The producer at `Platform.res` built it with
  `->Option.map(r => r.name)`; the generic `Option.map` body runs `Primitive_option.some(r.name)`,
  and because a Pulumi Output lifts arbitrary property access, `some` inspects
  `.BS_PRIVATE_NESTED_SOME_NONE`, mis-classifies the Output as a nested option, and stores the
  sentinel `{BS_PRIVATE_NESTED_SOME_NONE: 0}` instead of the Output — so the consumer's `.apply`
  crashes. (`pluginReadModelTableName`, same type, dodges it via a plain ternary producer.)
  **Fix:** replace the `Option.map` producer with a `switch … { Some(r) => Some(r.name) | None => None }`
  — the `Some(r.name)` LITERAL compiles unboxed (bare `r.name`), preserving the Output. **Verified at
  the compiled level:** the `.mjs` now emits `r$1 !== undefined ? r$1.name : undefined` (the safe
  form). The other two `option<Output>` fields (`platformApiId`, `adminDcbCmdTopicUrl`) come from
  bare/literal `Some` and are not corrupted (left as-is; the pattern remains a latent trap, noted).

- **Bug B (8 orphan resolvers)** — the admin DCB slices auto-generate resolvers absent from the
  pushed **static** `AdminApi.baseFragment`: StateView query resolvers (`Admin_{Ui,Api}Fragment(s)` /
  `…ByIds`, on type Query) and DCB command-subscription resolvers (`onPlatform_{Register,Deregister}ApiFragment`,
  on type Subscription). Normal plugins never hit this (they push a fragment *generated from the same
  entries* as their resolvers); the admin path pushes a hand-curated static base while creating
  resolvers for everything. The intended admin surface is ONLY the two `Platform_*` mutations (the
  views are served by the dedicated `Platform_{UI,Api}Fragments` Lambda resolvers). **Fix — suppress,
  platform-appropriately:**
  - Queries: skip merging the admin DCB StateView slices into `allQueryDbs` (→ `createResolvers`) in
    `Platform_Admin` **only when `preAdminResolversSchemaHook` is `Some`** (static-push platform = AWS).
    On the local platform (hook = `None`) the schema is built FROM those registrations, so they stay
    coupled and must be merged — gating on the hook keeps local self-consistent. (An earlier attempt to
    gate this in the shared `Dcb_Builder` on `onAdminApi` broke local schema assembly with a dangling
    `StringConnection` type — caught by the local live boot — and was reverted.)
  - Subscriptions: gate `CommandSubscriptionResolvers_AppSync.make` on `!onAdminApi` in `makeDcb`
    (AWS-only path; `onAdminApi` is already threaded through the DCB resolver hook). Plugins keep their
    subscriptions (their generated fragment declares the matching fields).

  **Audit (resolver/schema symmetry):** after the fix, every admin resolver created on AWS has a
  matching field in the pushed `baseFragment` — the two `Platform_*` mutations, the two `Platform_*`
  Lambda queries, the Plugins RM queries + Plugin-aggregate mutations; `Admin_*` queries and
  `onPlatform_*` subscriptions are suppressed; `RecordApiFragmentPush` stays `@noApi`;
  `dcbEventLogEntries` only feed the unpushed constructed fragment (no orphan). Symmetry holds.

  **Validation:** core 528 / aws 216 / local 508 green, zero-warning; **local live boot** (in-memory
  hybrid) boots clean, serves `Platform_ApiFragments` + `Platform_UIFragments` (auth-gated → resolvers
  live), no `onPlatform_*` subscriptions. The AWS-only suppression (queries) + Bug A are compile-validated
  only — **re-validation is the next alpha push** (should clear all 9 errors and let the first real
  `RegisterApiFragment` → `ApiFragment*` event → 2e reactive push fire).

**Deploy validation #3 (2026-07-13) — Deploy Platform GREEN (all 9 of #2 cleared); failure
moved forward to the plugin waiter, root-caused to a one-line core bug, FIXED.** With #2's fixes,
**Deploy Platform succeeded** — the admin DCB slices deployed cleanly, `Platform_RegisterApiFragment`
+ the `Platform_ApiFragments` resolver created, no orphan resolvers. The plugin deploys (catalog +
ordering) then failed at the **Phase-3 waiter**: each plugin's SigV4 `RegisterApiFragment` mutation
succeeded (`CommandAccepted`), but the waiter's SigV4 poll of `Platform_ApiFragments` returned
`Unauthorized: Not Authorized to access Platform_ApiFragments on type Query` on every attempt →
~3-min timeout → deploy fail.

**Root cause (one line, in core `GraphQL_Stitcher.extractLeadingName`):** the IAM caller could invoke
the register *mutation* but not the status *query*, because the query field never received the
`@aws_iam` dual-auth directive. `injectAwsAuthAll` decides IAM-eligibility via
`isIam(field) = iamFieldNames->includes(extractLeadingName(field))`. `extractLeadingName` split on
`(`, ` `, and `{` but **not `:`** — so a field WITH args (`Platform_RegisterApiFragment(…): …`)
extracted cleanly (the `(` cleaves the name), while an **arg-less** field
(`Platform_ApiFragments: […]`) came back as `Platform_ApiFragments:` (trailing colon) and failed the
exact-match against `systemCallerFieldNames`. So the arg-less status query stayed Cognito-only and
401'd the SigV4 waiter — in EVERY push path (bootstrap + the 2e reactive push both call
`injectAwsAuthAll`). The existing tests only covered an IAM field *with args*, so the bug shipped.
**Fix:** add a `->String.split(":")` step to `extractLeadingName` (a no-op for arg-full fields, which
already lost their type at `split("(")`; and for type defs, which lose it at `split("{")`). Regression
test added (`AppSync_SdlDecorateTest`): an arg-less query named in `iamFieldNames` gets `@aws_iam`,
an arg-full IAM mutation still does, and a non-IAM query stays Cognito-only. Validated: core 528 /
aws 216(+1) green, zero-warning; `extractLeadingName` unit-checked on query/mutation/type/input forms.
Compile-validated for the SigV4 auth path — **re-validation is the next alpha push** (should let the
waiter authorize, confirm ACTIVE, and complete the plugin deploys — the first true end-to-end run of
register → 2e reactive push → waiter).

**Deploy validation #4 (2026-07-13) — FULL DEPLOY GREEN; but the 2e reactive push is
erroring underneath, and the fix is an architecture change (ApiFragmentRegistry: DCB slice →
singleton aggregate).** With #3's `extractLeadingName` fix, the whole deploy went green —
**Deploy Platform ✅ + Deploy Plugin (catalog) ✅ + Deploy Plugin (ordering) ✅** — the first
end-to-end run: platform + admin-DCB surface + both plugins registering their fragments via SigV4.

**But green was partly masking.** Scanning the `ApiFragments` registry table on AWS shows
`pushStatus: error` for both plugins:
- Ordering: `Schema is currently being altered` (AppSync API-lock: concurrent pushes racing)
- Catalog: `shrink guard aborted push for DomainApi` (assembled 21 root fields vs 57 live)

The deploy still passed because (a) the fragments were already registered by #3's *successful
mutations* (only #3's status *query* had failed), so this run hit the waiter's idempotent
`CommandAccepted{eventCount:0}` → `fragment unchanged, no push` shortcut and never polled
`pushStatus`; and (b) the Domain API schema is correct (57 fields) because the **legacy
`mkUpdateApiSchema` push** (kept until Phase 4) is still doing the real work. So a real fragment
*change* would fail the waiter (`pushStatus:error`).

**Root cause (investigated, decisive):** the registry *content* is complete and correct — a full
fold = 44 root fields = exactly the live 45 minus the stitcher's auto-injected relay `node`
(field-name diff: only `node` in live-not-registry, nothing registry-not-live). The failure is:
- **partial assembly:** the reactive push folds the registry by scanning the `ApiFragments`
  **view**, which a *separate, lagging* consumer (`AllStateViewSlices` projection) maintains. On
  near-simultaneous multi-plugin deploys, a peer's freshly-registered row isn't in the view yet →
  the fold drops it → whole-schema-replace would shrink → guard aborts (correctly).
- **concurrency:** each plugin's event triggers its own push; two `StartSchemaCreation` calls race
  the AppSync API lock.

Neither is a registry-content problem. The plan already prescribed the answer — *"stitch from
consistent state (event fold), NOT an eventually-consistent RM scan"* — but the implementation does
the RM scan it warned against.

**Rejected fix — retry + timeout (symptom-fighting).** A first attempt added a re-fold/re-push
retry loop with backoff and bumped the admin EC Lambda timeout to fit it. This fights the lagging
read with time and has no principled ceiling (projection lag is unbounded). Reverted.

**Rejected fix — Option A: fold the DcbEventLog via a cross-partition scan.** Reading the *log*
(written synchronously by the command) instead of the *view* (written by the lagging projection)
removes the projection dependency and shrinks staleness to DynamoDB's own sub-second scan window.
But: (1) a strongly-consistent read exists only **per single partition** (DynamoDB constraint —
`DcbEventLogStorage`'s `buildQueryByPartitionKeyInput ~strongConsistency`; GSIs/scans cannot),
and the registry is one partition *per plugin*, so a global read stays bounded-eventual; and (2)
**performance** — it's a **full-table `Scan` on every push**, and the log is append-only and
grows forever (`RecordApiFragmentPush` writes one event *per push* — exactly the events the fold
discards — and `Scan` pays RCU to read every item before filtering). Cost/latency grow unbounded.
Rejected on the scan-scaling ground alone.

**CHOSEN FIX — model `ApiFragmentRegistry` as a SINGLETON AGGREGATE (not per-plugin DCB slice).**
An aggregate is a single consistency boundary with a single event stream. Keyed by a **fixed
constant id** (e.g. `"registry"`) — `pluginId` becomes a payload field, NOT the id — the *whole*
registry lives in **one partition**, so reading it is a single **strongly-consistent `id=:pk`
read** (exactly the slice's own decision-read pattern, now covering everything) **+ snapshot →
O(recent), bounded**. This fixes consistency *and* performance instead of trading them:

| | DCB slice + fold log (Option A) | Singleton aggregate (chosen) |
|---|---|---|
| Global read consistency | bounded-eventual (cross-partition) | **strong** (one partition) |
| Read cost per push | full scan, grows forever | snapshot + tail, **bounded** |
| Write model | independent per plugin | serialized on one aggregate (fine at deploy freq) |
| `systemCallable` | native (slice attr) | via `systemCallerFieldNames` → `injectAwsAuthAll` |

Why DCB was originally chosen (independent per-plugin *writes*) optimized the wrong side: the
**stitch is a whole-registry read**, and an aggregate serves that directly; deploy-frequency writes
don't need per-plugin write independence.

**Component layout — mirrors the existing admin `Plugin` aggregate + `Plugins` RM:**
- **`ApiFragmentRegistry` aggregate** (replaces `.../StateChangeSlice/`): singleton, fixed id;
  `state = Dict<pluginId, {encoded, protocol, apiTarget, pushStatus, pushMessage, pushedAt,
  registeredAt, updatedAt}>`; commands `RegisterApiFragment` / `DeregisterApiFragment` (API-exposed,
  IAM) / `@noApi RecordApiFragmentPush`; events `ApiFragment{Registered,Updated,Deregistered,
  PushRecorded}`. Behavior folds the whole map, idempotency by comparing `state[pluginId]`, retarget
  is one in-state move. `@noApi` on a variant is proven on aggregates (`Plugin` uses `@noApi
  Heartbeat`).
- **`ApiFragments` read model** (replaces `.../StateViewSlice/`): projection off the aggregate;
  per-plugin status rows for the `Platform_ApiFragments` query.
- **Reactive push** — **SUPERSEDED** by the chosen "behavior-computed schema + bespoke SideEffect
  push" design (see § Reactive writer design below). The originally-planned mjs approach (on any
  `ApiFragment*` event, single-partition `id="registry"` `ConsistentRead` fold → stitch per target →
  push) is *not* built; the behavior computes the schema and a `SideEffect` performs the push
  instead. Everything else in this component layout stands.

**Three things this SIMPLIFIES (removes more than it adds):**
1. **GraphQL exposure** — the aggregate's mutations go through the existing admin-aggregate path
   (`registerAdminAggregateMutations` → `pluginAggregateMutationEntries` → `baseFragment`), resolved
   by the standard CommandGenerator flow (`mutationResolverHook=None`). So **all of 2d's
   DCB-resolver-hook machinery disappears**: no `~apiNamePrefix`, no `~onAdminApi` routing, no
   `DcbMutation` datasource. IAM = add the two field names to `systemCallerFieldNames`.
2. **Trigger path** — aggregate events reach the admin EC via the normal aggregate event topic
   (SNS→SQS), so the **2e "admin EC as 2nd DynamoDB-stream reader"** (with its ~2-concurrent-shard
   limit) goes away.
3. **No retry/skip machinery** — the consistent read makes it unnecessary.

**Status query & deploy caller:** `Platform_ApiFragments` reads the `ApiFragments` RM (eventual is
fine — the waiter polls). Deploy caller (`registerFragmentViaApi`): the mutation `id: ID!` arg
becomes the constant `"registry"` (was the pluginId); `pluginId` stays a payload field.

**Open points to verify while building:**
1. Singleton routing — how the mutation→command sets `id` to the constant (generator takes `id`
   from an arg we fix to `"registry"`, vs derived). Load-bearing detail.
2. ~~Reading aggregate state from the mjs~~ — **MOOT**: the chosen writer design computes the schema
   in the behavior and pushes via a `SideEffect`, so there is no mjs aggregate read (see § Reactive
   writer design).
3. Mutation naming — **RESOLVED (2026-07-13, found while implementing).** The aggregate resolver path
   (`Plugin_Helpers.registerAdminAggregateMutations`) names admin-aggregate mutation fields
   `adminField(Spec.name ++ "_" ++ cname)` → **`Platform_ApiFragmentRegistry_RegisterApiFragment`**,
   NOT the slice path's `Platform_RegisterApiFragment` (`sliceMutationFields(~plugin="Platform")`,
   no aggregate-name segment). So the aggregate path does **not** preserve the byte-identical name.
   The SDL entry (`AdminApi.apiFragmentRegistryMutationEntries`) and the resolver must agree, or
   AWS `CreateResolver` fails — DECISION (2026-07-13, user): **(A) accept the rename.**
   - **(A) [CHOSEN] Accept the aggregate-convention name** `Platform_ApiFragmentRegistry_{Register,Deregister}ApiFragment`
     — regenerate `apiFragmentRegistryMutationEntries` from that convention (SDL follows), update the
     Phase-3 deploy caller (`registerFragmentViaApi` mutation name) + `systemCallerFieldNames` follow
     automatically. Simplest; changes a deploy-facing mutation name (no external callers but ours).
   - **(B) Preserve byte-identical `Platform_RegisterApiFragment`** — add a per-aggregate name-prefix
     override to `registerAdminAggregateMutations`/`aggregateMutationFieldsRegistry` (mirrors the DCB
     path's `~apiNamePrefix`) so this aggregate's commands render without the aggregate-name segment.
     More core surgery; deploy caller unchanged.

**Implementation note (2026-07-13):** the slice→aggregate rewire + the **local** SideEffect writer are
**inseparable for a working local boot** — the current local single-writer decodes slice events off the
admin DcbEventLog; once ApiFragmentRegistry is an aggregate, `RecordApiFragmentPush` only fires if the
writer is re-sourced onto the aggregate's events (the SideEffect). So the rewire + local SideEffect must
land as ONE unit (a first attempt was reverted to keep the tree green after the foundation commit).

**Build order:** (1) aggregate spec+behavior, (2) RM, (3) rewire `Admin.construct`
(slices→`~aggregates`/`~readModels`), (4) **reactive writer per § Reactive writer design** (behavior
emits `ApiSchemaComputed` + bespoke `SideEffect` push — replaces "reactive push reads aggregate"),
(5) deploy caller + IAM, (6) tests — building + live-booting locally at each step. Deploy-validate on
alpha at the end.

**What gets deleted in this rework:** `ApiFragmentRegistry/StateChangeSlice/*` +
`ApiFragments/StateViewSlice/*`; the 2d slice-resolver hook threading (`~apiNamePrefix`,
`~onAdminApi`, `DcbMutation` binding) *for the ApiFragment path*; the reactive push's view-scan +
retry attempt. (The `UiFragmentRegistry` slice is out of scope here — it's connect-driven, has no
whole-registry stitch read, and stays a slice. So the admin DcbEventLog + DCB-resolver path remains
for it; this rework removes only the ApiFragment usage of it. Reassess whether the admin DcbEventLog
is still worth it once only UiFragment uses it.)

**Aggregate rework — IN PROGRESS (2026-07-13, this session). Core + local DONE + LOCAL-BOOT
VALIDATED; AWS mechanical DONE (compile-only); AWS SideEffect writer PARTIALLY built (compile-only),
wiring blocked on unverifiable gaps (below).**

- **Core (built zero-warning):** `AdminApi.apiFragmentRegistryMutationEntries` now derives from the
  `ApiFragmentRegistrySpec` *aggregate* command schema (`Platform_ApiFragmentRegistry_{Register,
  Deregister}ApiFragment`, decision A) and folds into the SHARED `AdminApi.mutationEntries` (like the
  Plugin aggregate) — feeding both the constructed admin fragment and the pushed `baseFragment`;
  removed the slice-only `baseFragment`-concat + the `~systemCallableComponents=["ApiFragmentRegistry"]`
  DCB arg (aggregate mutations get IAM via the unchanged `systemCallerFieldNames` → `injectAwsAuthAll`).
  `Platform_ApiFragmentsApi.encodeApiFragmentEntry` retargeted to `ApiFragmentsReadModelSpec.state`.
- **Local (built zero-warning + LIVE-BOOT VALIDATED, hybrid in-memory):** slice defs → aggregate
  (`LocalApiFragmentRegistryAggregate` via `AggregateMaker.Make`) + read model (`ApiFragmentsReadModel`
  via `ReadModelMaker.MakeNoResolver`) at all three `Admin.construct` sites (moved out of
  `~stateChangeSlices`/`~stateViewSlices` into `~aggregates`/`~readModels`); `dispatchApiFragmentCommand`
  targets the aggregate command topic with the **singleton id `"registry"`** (pluginId is payload);
  the in-process single-writer re-sourced onto the **aggregate event topic** (`ApiFragmentRegistry`),
  recording ok on `ApiFragmentRegistered`/`Updated` (the local no-op-push analogue — `LocalSideEffectHandler`
  is a stub, so a local SideEffectHandler is not viable; the subscriber IS the local writer); status
  resolver scans `ApiFragmentsReadModelSpec`. **Boot proof:** `Platform_ApiFragments` returns Catalog +
  Ordering `pushStatus:"ok"`; `Platform_ApiFragmentRegistry_RegisterApiFragment`/`_DeregisterApiFragment`
  exposed on the platform Mutation (byte-aligned, decision A); `Aggregate(ApiFragmentRegistry)` appends
  `id=registry`.
- **AWS mechanical (built zero-warning, compile-only):** slice defs → `ApiFragmentRegistryAggregate`
  (`Aggregate_Builder_Single.Make`) + `ApiFragmentsReadModel` (`ReadModel_Builder_Single_Stream.Make`)
  at both construct sites; `QueryDbBackend.exempt(ApiFragmentsReadModelSpec.name)`; the two
  `Platform_ApiFragments_Lambda` status-Lambda mounts + the (now-dead) config-threading lookup re-keyed
  `stateViewSlicesOutputs["ApiFragments"]` → `readModelsOutputs["ApiFragments"]`; deploy caller
  (`registerFragmentViaApi`) + `ApiFragmentDeregistration` provider use the aggregate mutation names +
  singleton `id="registry"`.
- **AWS SideEffect writer — SCAFFOLDED (compile-only, additive/unwired):**
  - `ApiSchemaPush.res` (`reventless-aws/src/adapter/Api/`) — `SideEffect.T`, `Source =
    ApiFragmentRegistrySpec`; `execute` on `ApiSchemaComputed({snapshot})` dyn-imports and calls
    `ApiSchemaPush_Runtime.mjs`.
  - `ApiSchemaPush_Runtime.mjs` (`.../Runtime/`) — runtime-pure `pushApiSchema(snapshot)`: folds
    fragments straight from the consistent snapshot (NO scan), `planAwsPushes` per target, shrink guard,
    `updateAppSyncSchema`, then `RecordApiFragmentPush` per plugin onto the aggregate command topic
    (FIFO, id `"registry"`); reads config from env.
  - Env-injection plumbing: `SideEffectHandler.T.make` gains `~extraEnvVars`; core builder +
    `LocalSideEffectHandler` ignore it; AWS `SideEffectHandler_Single` + `SideEffectHandlerRuntime_Builder_Single`
    add a `registerExtraEnv` side-registry merged onto the shared Lambda env in `finish()` (backward-compatible
    for Tasks).
  - **WIRED (compile-only, this session).** The admin `SideEffectHandler_Single`
    (`AdminApiSchemaPushHandler`) is instantiated in `deployPlatform` after `Admin.construct`, subscribed
    to the ApiFragmentRegistry aggregate's event topic (its DynamoDB stream — single-shard for a singleton
    → naturally serialized, no self-race), with `~targets=[ApiFragmentRegistry]` (grants SQS send to the
    aggregate command topic for the `RecordApiFragmentPush` write-back) and `~extraEnvVars` = domain/platform
    API ids + splitApi + cloner + the aggregate command-topic URL. The four gaps found this session are
    closed: (1) queryEngine → `QueryEngine.DynamoDb.make(Dict.make())` (ApiSchemaPush ignores it);
    (2) `finish()` → an explicit `SideEffectHandlerRuntime_Builder_Single.finish()` registered on
    `apiSchemaPushCmdTopics` immediately after `make()` (same-Output apply FIFO ⇒ runs after the handler's
    deferred `forEventCollector`); (3) AppSync IAM → a `RolePolicy` (`StartSchemaCreation`/
    `GetSchemaCreationStatus`/`GetIntrospectionSchema`) attached to the shared side-effect-handler Lambda
    role in `finish()`, gated on `extraEnvVarsAll` being non-empty so Task-only deploys keep the narrow
    perimeter; (4) cmd-topic URL from `admin.aggregatesOutputs["ApiFragmentRegistry"].commandTopic`.
    `ApiSchemaPush_Runtime.mjs` also gained a bounded retry on the AppSync API-lock (`Schema is currently
    being altered`) as the plan-specified cross-writer backstop.
  - **The legacy mjs `mkReactiveApiSchemaPush` is now INERT and LEFT IN PLACE** (verified: the admin EC
    subscribes to the plugin-EP SNS topic + the admin-DcbEventLog stream, NOT the ApiFragmentRegistry
    aggregate's stream — which isn't EP-referenced — so `detectApiFragmentTriggers` never sees these events;
    no double-push). Deleting it is surgery on the deploy-critical connect callback, so it's deferred to a
    deploy-validated Phase-4 cleanup rather than risked blind. The Platform_Admin admin-EC-2nd-stream-reader
    augmentation + the 2e `registerConfig` fields are likewise now dead but benign; left for the same pass.

**Deploy validation #5 (2026-07-13) — Deploy Platform FAILED with orphan resolvers (the
aggregate-path analogue of #2's Bug B); root-caused + FIXED (compile/local-boot-validated,
re-deploy pending).** The first deploy of the aggregate rework got as far as creating the
`ApiFragmentRegistryAggrEventLog` table, then `Pulumi up` failed on the admin GraphQL surface with
two classes of orphan resolvers — fields the auto-flow creates but the pushed static
`AdminApi.baseFragment` doesn't declare:
- **Query:** `apiFragments` / `ApiFragmentss` / `ApiFragmentssByIds` — the AWS `ApiFragmentsReadModel`
  used the resolver-generating `ReadModel_Builder_Single_Stream`, auto-naming Connection query fields
  (no `queryFieldNamesRegistry` entry → the `name`/`name++"s"` fallback) that aren't in `baseFragment`
  (its real surface is the dedicated `Platform_ApiFragments` Lambda). Local dodged it via `MakeNoResolver`.
  **Fix:** AWS uses `ReadModel_Builder_NoResolver_Stream` (purpose-built for admin RMs served by a custom
  Lambda — stream-projects the table, creates NO AppSync resolvers), mirroring local.
- **Subscription:** `onPlatform_ApiFragmentRegistry_{Register,Deregister}ApiFragment` — the aggregate
  mutations go through the CommandGenerator auto-flow, which creates an `on<field>` subscription resolver
  per mutation; `baseFragment` declared these only for the Plugin aggregate. **Fix:** run
  `Plugin_SubscriptionSchema.sourceCFields` over `apiFragmentRegistryMutationEntries` too and fold the
  fields/sources into `baseFragment`, symmetric with the Plugin aggregate.

Audit: after the fix every admin resolver created on AWS has a matching `baseFragment` field — the two
`Platform_ApiFragmentRegistry_*` mutations + their `on*` subscriptions, the `Platform_ApiFragments`
Lambda query, the Plugins RM queries + Plugin-aggregate mutations/subscriptions; `RecordApiFragmentPush`
stays `@noApi`; the ApiFragments RM emits no auto resolvers. Validated: core/aws/local build zero-warning;
local live boot clean (`Platform_ApiFragments` ok, mutations exposed, no duplicate-field error).
Re-validation is the next alpha push.

**Remaining work:**
- **Deploy-validate the whole AWS path on an alpha push** — the SideEffect writer, IAM, env injection,
  `finish()` sequencing, stream subscription, and the deploy caller/waiter are all compile-only. Watch:
  the first `RegisterApiFragment` → aggregate `ApiSchemaComputed` → the ApiSchemaPush SideEffect Lambda
  pushes per-target + records → the waiter sees `pushStatus:ok`; and no concurrent-push `Schema is
  currently being altered` under a 2-plugin deploy (bounded retry as backstop).
- **Cleanup (Phase-4, deploy-validated):** DELETE the inert mjs `mkReactiveApiSchemaPush` +
  `detectApiFragmentTriggers` + the 2e `registerConfig` threading + the Platform_Admin 2nd-stream-reader
  augmentation.
- **GWT tests — DONE.** `ApiFragmentRegistryBehavior_GWT` (11 cases: two-event `ApiSchemaComputed` emit
  incl. the multi-plugin whole-registry snapshot, idempotent re-register/deregister/redelivery, retarget,
  and RecordApiFragmentPush emitting NO snapshot) + `ApiFragmentsProjection_GWT` (7 cases incl.
  `ApiSchemaComputed` is ignored, push-status ok/error, retarget, deregister-removes). 18/18 green; the
  superseded slice GWTs (`ApiFragmentRegistry_GWT`/`ApiFragments_GWT`) were removed. The old slice `.res`
  files themselves (now fully unreferenced, still compiling) are deleted in the same deploy-validated
  cleanup as the inert mjs.
- Phase 4 — cutover + cleanup (retire `deploy-schema:*` keyspace, lease, hash rows, legacy
  `mkUpdateApiSchema`; decide whether `makePlatform`'s direct-push path is retired or kept; dedup
  the `injectAwsAuthAll`/`stampSharedIamTypes` copies if any linger).

## Reactive writer design — behavior-computed schema + bespoke SideEffect push (CHOSEN 2026-07-13)

**Status: CHOSEN — adopted over the CHOSEN-FIX's mjs-read reactive push** (decision 2026-07-13,
after the recommendation to finish this plan the framework-native way rather than pivot to merged
APIs — see [docs/analysis/merged-api-push-free-approach.md](../analysis/merged-api-push-free-approach.md)).
This **keeps** everything else from the singleton-aggregate CHOSEN FIX (the aggregate, the
`ApiFragments` RM, the standard-aggregate GraphQL exposure, the `Platform_ApiFragments` status
query, the deploy caller + waiter) and **replaces only the reactive-push mechanism**: the mjs
"read aggregate state + fold + stitch + push" (CHOSEN-FIX open point #2) is superseded by
"behavior computes the schema → bespoke `SideEffect` pushes it." It attacks the two things that
remained hand-rolled after the aggregate rework: the mjs reads aggregate state by hand, and the
writer is a bespoke AWS `.mjs` subscriber rather than a framework building block — the same
parallel-mechanism smell this whole plan set out to remove for `deploy-schema:*`.

**The shape:**

1. **The aggregate behavior emits the consistent fragment snapshot.** On `RegisterApiFragment` /
   `DeregisterApiFragment`, the behavior emits a second event `ApiSchemaComputed{ snapshot }`
   alongside the `ApiFragment{Registered,Updated,Deregistered}` fact, where `snapshot` is the
   **whole registry after this change** — the per-plugin `{pluginId, encoded, protocol, apiTarget}`
   set folded from the aggregate's own consistent single-partition state at command-handling time.
   This is what carries "stitch from consistent state, not an eventually-consistent read" to the
   push handler **without a hand-rolled `ConsistentRead` in the mjs** — open point #2 disappears,
   and deploy-#4's false `shrink guard aborted` (a lagging-read artifact) cannot recur.
   *Refinement (2026-07-13, found while implementing):* the behavior does **not** run the stitch
   (`GraphQL_PushPlanner.planPushes` needs `~splitApi` + `~adminBase`, which are deploy/platform
   concerns an aggregate behavior can't cleanly obtain), so it emits the fragment **snapshot**, not
   final SDL. The stitch (`planPushes`), AWS decoration, the catastrophic-shrink guard (compared
   against live introspection — provider-specific), and the push all live in the SideEffect, which
   has `splitApi`/`adminBase`/`apiId`/`region` from its deploy config. The behavior stays free of
   deploy config; the event stays neutral (a fragment set, no provider dialect).
2. **A bespoke SideEffect performs the push.** A `SideEffect.T` (`Source = ApiFragmentRegistry`)
   reacts to `ApiSchemaComputed` and calls the push. Hosted by a `SideEffectHandler` (existing
   component; `reventless-core/src/components/SideEffectHandler/`) wired into the admin platform —
   giving standard event-topic subscription (SNS→SQS on AWS, in-process on local) and
   provider-agnostic hosting for free. This **replaces both the bespoke mjs writer and the
   CHOSEN-FIX "admin EC as 2nd DynamoDB-stream reader" hack** (aggregate events flow through the
   normal aggregate event topic, so the ~2-concurrent-shard stream-reader limit goes away too).

**Provider-specificity stays localized — no generic framework injection.** The push is
provider-specific, but the framework's generic `SideEffect.T` context (`(id, meta, event,
queryEngine)`) is **left untouched** — we do NOT add a schema-push capability to it. Because this
is one bespoke side effect written for exactly this job, it **self-acquires** what it needs:

- **Provider selection is by module, not injection.** An **AWS** side-effect module (in
  `reventless-aws`) whose `execute` runs `GraphQL_PushPlanner.planPushes(~adminBase, ~fragments=snapshot,
  ~splitApi)` (base+splitApi from its deploy config), applies the `@aws_*` dialect + shrink guard via
  `AppSync_SdlDecorate.planAwsPushes`, and calls the runtime-pure `updateSchema`; a **local** module
  that **no-ops** the push (fields already served by resolver registration). The admin wiring selects
  the provider-appropriate module — the same pattern the existing provider adapters already use.
  Neutral-SDL discipline (increment 2a) holds: the event carries a neutral fragment snapshot; the AWS
  module does all provider-specific stitch/decoration at push time.
- **Outcome write-back needs no `execute` generalization either.** `SideEffectHandler.make`
  already provisions `~allCommandTopics`, so the bespoke module publishes `RecordApiFragmentPush`
  to the admin command topic itself (URL from runtime env). So neither of the two framework
  extensions previously floated (inject a provider port; let `execute` return `taskAction`s) is
  required — both collapse into "this one module wires its own two capabilities."

**The one discipline: runtime-purity (else the `@pulumi`-in-Lambda-runtime leak returns).** Every
capability the module self-acquires must be **runtime-pure** — API id, region, and command-topic
URL read from **env/config at runtime** (exactly as the mjs's `HANDLER_CONFIG` does today), and the
AWS push is the runtime-pure `AppSync` path. The module must **not** close over a deploy-time
Pulumi `Output` — that is precisely why `AppSync_SdlDecorate.res` was carved out runtime-pure so
the mjs could import it (`reference_pulumi_leaks_into_lambda_runtime_graph`). No serializer hazard
here: unlike the `ApiFragmentDeregistration.res` dynamic provider (closure serialized into stack
state), a `SideEffectHandler` Lambda loads compiled modules normally, so an env read inside
`execute` is the clean mechanism.

**Component layout (delta from the CHOSEN FIX):**
- `ApiFragmentRegistry` aggregate (unchanged from CHOSEN FIX) — plus behavior emits
  `ApiSchemaComputed{snapshot}` (the consistent per-plugin fragment set after the change); no
  in-behavior stitch or shrink guard (those live in the SideEffect, which has `splitApi`/`adminBase`).
- `ApiFragments` read model (unchanged) — status rows for `Platform_ApiFragments`.
- **New:** an admin `SideEffectHandler` hosting the provider-specific push module
  (`ApiSchemaPush` AWS vs local), wired in `Platform_Admin.construct` and subscribed to the
  `ApiFragmentRegistry` event topic.
- **Deleted vs CHOSEN FIX:** the mjs reactive writer (`mkUpdateApiSchema` retarget), its
  single-partition `ConsistentRead` fold + EventLog-table-name config threading, and the admin-EC
  2nd-stream-reader wiring.

**AppSync concurrent-push API-lock race — solvable (deploy-#4 Ordering `Schema is currently
being altered`).** The pushes don't conflict semantically — each is a whole-registry stitch
monotone toward the same target, so the last correct push wins; it's a serialization/coalescing
problem, not a content one. The singleton aggregate makes the clean fix available: **all registry
events come from one aggregate id (`"registry"`)**, so a **single-concurrency writer** (reserved
concurrency = 1 on the push handler — note `SideEffectHandler.make` doesn't expose that knob today,
small addition) makes two in-flight `StartSchemaCreation` calls structurally impossible. Add
**per-batch coalescing** (fold once, push the highest-sequence event, not per-record). Keep
**bounded retry on `Schema is currently being altered`** as a backstop for residual races (the
legacy `mkUpdateApiSchema` still pushing during the transition; a standalone-service push) — this
is *not* the plan's rejected lagging-read retry (that had no ceiling; the API lock clears in
seconds). One guardrail: **a retry/reorder must push latest-folded state, never re-push a stale
payload** (else push A [catalog-only] landing after push B [catalog+ordering] shrinks the schema).

*Race/ordering — DECISION (2026-07-13).* Because `ApiSchemaComputed` carries a point-in-time
snapshot, a stale snapshot pushed after a fresh one would shrink the schema, so the push handler is
made **serialized + in-order + coalescing**:
- **Serialized in-order:** all registry events share one aggregate id, so the push handler's queue
  uses a single **FIFO `MessageGroupId` = the registry id**, with **reserved concurrency = 1** as
  belt-and-suspenders → at most one `StartSchemaCreation` in flight, processed in emit order, so the
  last snapshot pushed is always the latest.
- **Per-batch coalescing:** within one invocation, fold once and push the highest-sequence
  `ApiSchemaComputed`, skipping superseded ones.
- **Bounded retry** on `Schema is currently being altered` stays as a backstop for residual races
  (the legacy `mkUpdateApiSchema` during the transition; a standalone-service push).
- **Fallback** if making the admin push path FIFO proves too invasive: treat `ApiSchemaComputed` as
  a bare trigger and **re-fold the latest strongly-consistent single-partition state at push time**
  (cheap — one aggregate partition). This reintroduces a read but is unconditionally reorder-safe;
  choose it only if FIFO wiring is impractical.

*Push-free option (out of scope, named for completeness):* AppSync **Merged APIs** (each plugin
owns a source API; AppSync merges) eliminates whole-replace and the shared lock entirely, making
the race impossible rather than serialized away — but replaces `GraphQL_Stitcher` + `updateSchema`
wholesale (a much larger re-architecture, not this plan).

**Accepted trade-off:** `ApiSchemaComputed` carries the whole cumulative neutral SDL (O(all
plugins)) and is written per change — storing a *derived* artifact in the event log (mild ES smell;
contrast the mjs approach, where the full schema stays transient and only the small per-plugin
fragment is stored). Accepted at deploy-frequency write volume and bounded schema size (well under
the event-payload budget); the payoff is that consistency + the shrink guard become framework-native
and the bespoke mjs + 2nd-stream-reader hack both disappear. Local pays a written-then-ignored blob
(push is a no-op there).

**Open points to verify while building:**
1. Emitting two events from one command handler (the `ApiFragment*` fact + `ApiSchemaComputed`) —
   confirm the aggregate path serializes both under one decision, and that `ApiSchemaComputed`
   does not itself re-trigger a recompute loop (it is not a fragment-changing event; the behavior
   ignores it).
2. Admin hosting precedent: `Task`/`SideEffectHandler` are today plugin components wired by the
   generator into `Plugin.res`; standing one up inside `Platform_Admin.construct` is net-new
   (though `SideEffectHandler.make` is directly callable). Confirm the admin `SideEffectHandler`
   subscribes to the `ApiFragmentRegistry` aggregate event topic and that its queue can carry a FIFO
   `MessageGroupId` + reserved-concurrency=1 (the race/ordering decision above).
3. The bespoke module ignores the injected `queryEngine` and self-wires push + publish from env —
   acceptable for a platform component, but be explicit that `SideEffectHandler` is used here for
   event-subscription + provider-agnostic hosting, not for its generic injected context.
4. Shrink-guard state: the behavior holds the prior computed field-count (or a hash) in aggregate
   state to make the guard a pure in-behavior invariant; confirm this survives snapshot/replay.

**Build order (chosen writer design):**
1. **Aggregate behavior** — emit `ApiSchemaComputed{neutralSdl}` as a second event on
   `RegisterApiFragment`/`DeregisterApiFragment`; fold the whole map via `GraphQL_PushPlanner.planPushes`
   (already unit-tested), stamp the shrink-guard field-count into state; behavior ignores
   `ApiSchemaComputed`/`ApiFragmentPushRecorded` (no recompute loop). GWT-cover the two-event emit +
   the shrink-guard invariant.
2. **Bespoke push module** — `ApiSchemaPush` `SideEffect.T` (`Source = ApiFragmentRegistry`), two
   provider builds: AWS (`reventless-aws`, `execute` decorates via `AppSync_SdlDecorate` + runtime-pure
   `updateSchema`, reads `platformApiId`/region/cmd-topic-URL from env) and local (`reventless-local`,
   no-op push, still publishes `RecordApiFragmentPush(ok=true)`).
3. **Wire the admin `SideEffectHandler`** in `Platform_Admin.construct`, subscribed to the aggregate
   event topic; select the provider module per platform; queue = FIFO group `"registry"` + reserved
   concurrency 1; per-batch coalesce.
4. **Delete** the mjs reactive writer (`mkUpdateApiSchema` retarget), its `ConsistentRead` fold +
   EventLog-table-name config threading, and the admin-EC 2nd-stream-reader wiring.
5. **Local live-boot** at each step (hybrid example, in-memory): register → `ApiSchemaComputed` →
   SideEffect no-op push → `RecordApiFragmentPush` → `Platform_ApiFragments` shows `ok`.
6. **Deploy-validate on alpha** together with the deploy caller + waiter (Phase 3), watching the
   first real `RegisterApiFragment` → `ApiSchemaComputed` → SideEffect push → ACTIVE → waiter pass,
   and confirming no concurrent-push `Schema is currently being altered` under a 2-plugin deploy.

## Phasing

1. **UiFragmentRegistry extraction** (low risk, no deploy waiter): introduce the slices,
   move `UIFragment*` events off the Plugin aggregate, replace the projection/RM, keep the
   `Platform_UIFragments` query shape byte-identical for the host-shell.
2. **ApiFragmentRegistry runtime side:** slices + single-writer automation + push status;
   runtime re-stitcher retargeted; `updateSchema` path exercised on the local platform.
   Includes: `RegisterApiFragment`/`DeregisterApiFragment` fields join the bootstrap SDL
   (IAM-callable); **dialect neutralization** — `@aws_subscribe` moves out of core
   (`AdminApi.res`, `Plugin_SubscriptionSchema.res`) into the AWS adapter's push-time
   decoration, driven by subscription-source metadata; the local platform's stripping code
   (`GraphQL_SubscriptionBridge`) is deleted.
3. **Deploy-side switch:** `deployPlugin` sends `RegisterApiFragment` + waiter; retire the
   `preResolversSchemaHook` body; destroy-path deregistration.
4. **Cutover + cleanup:** no data migration and no compatibility window — the framework has
   no external users yet. Wipe existing stacks and redeploy the example projects from
   scratch on the new architecture; delete the `deploy-schema:*` keyspace code, the lease,
   and the hash-row handling outright. (This also disposes of the retirement gap without a
   standalone fix — the mechanism that has it is removed wholesale.)

## Non-goals

- Changing the stitcher, SDL shapes, or GraphQL surface of `Platform_UIFragments`.
- A unified "FragmentRegistry" abstraction spanning API and UI — analysis § 5: the sink
  semantics are disjoint; both sides simply use standard components.
- Removing the platform-bootstrap direct push.

## Acceptance

- A plugin deploy against a running platform registers its fragment via the Platform API
  (SigV4), and its resolvers are created only after its fields are ACTIVE; a stitch error
  fails the deploy with the error message, not a timeout.
- Two concurrent plugin deploys cannot clobber each other's fields (single-writer
  automation; no lease needed).
- A standalone Pulumi program (no `deployPlugin`) contributes SDL fields that survive
  subsequent plugin deploys' stitches.
- Final retirement of a plugin removes its fields from the stitched schema; version
  supersession and transient disconnects do not.
- Host-shell UI behaviour unchanged (same `Platform_UIFragments` response shape).
- The Plugin aggregate's events and RM no longer carry fragment payloads.
- reventless-local exercises both registries fully in-process (no AWS needed for tests).
- Core-emitted SDL and fragments contain no provider directives (`@aws_*`); the AWS adapter
  adds its dialect at push time, and the local platform performs no stripping or emulation
  of provider directives.
