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
