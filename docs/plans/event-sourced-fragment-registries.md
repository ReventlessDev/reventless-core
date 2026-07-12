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

**Remaining work:** Phase 2 increments 2c–2e (single-writer subscriber + bootstrap SDL
mutations + status query + runtime re-stitcher retarget), Phases 3–4.

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
