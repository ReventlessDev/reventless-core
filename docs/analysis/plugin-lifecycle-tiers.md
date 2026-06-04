# Plugin Lifecycle Tiers

## Summary

Reventless plugins move through three lifecycle tiers, each with a distinct
trigger, recoverability, and effect on the platform's API and UI surface.
Treating them as a single "is the plugin up?" axis leads to over-reactive
behaviour — for example, tearing down the GraphQL schema on a transient
heartbeat miss, or conflating an admin-driven suspension with a permanent
removal. Naming the tiers explicitly and assigning each its own surface
contract keeps the system predictable and gives each future feature a
precise slot.

This document captures the conceptual model. The implementation lives in
`PluginSpec` / `PluginBehavior`; the AWS workstream that operationalises
the admin tier is [docs/plans/aws-plugin-activate-deactivate-resolver.md](../plans/aws-plugin-activate-deactivate-resolver.md).

## The three tiers

### Tier 1 — Transient outage (`Disconnected`)

- **Trigger**: liveness timeout — the platform stops receiving the
  plugin's `Heartbeat`.
- **Aggregate state**: `Disconnected(pluginDefinition)`
  ([PluginBehavior.res:10](../../reventless/reventless-core/src/admin/PluginBehavior.res#L10)).
- **Recovery**: automatic. The next `Heartbeat` from the plugin moves it
  back through `Reconnected` to `Connected`. No human action.
- **Cardinality**: expected, frequent. Network blips, Lambda cold-starts,
  brief downtime windows all land here.

### Tier 2 — Admin suspend (`Inactive`)

- **Trigger**: explicit `Deactivate` admin command (Cognito Admin group;
  see `Platform_Plugin_Deactivate` in
  [PluginBaseFragment.res:33-50](../../reventless/reventless-core/src/admin/PluginBaseFragment.res#L33-L50)).
- **Aggregate state**: `Inactive(pluginDefinition)`
  ([PluginBehavior.res:11](../../reventless/reventless-core/src/admin/PluginBehavior.res#L11)).
- **Recovery**: explicit `Activate` admin command (also admin-gated).
  Heartbeats arriving while `Inactive` do not auto-restore; the plugin
  stays suspended until an admin acts.
- **Cardinality**: rare, deliberate, reversible. Used to take a plugin
  offline for maintenance, isolate a misbehaving plugin, or stage a
  controlled rollout.

### Tier 3 — Decommission (currently unmodeled)

- **Trigger**: a future `Decommission` admin command (or equivalent —
  named here informally) emitting a `PluginDeregistered` /
  `PluginDeprecated` event.
- **Aggregate state**: would be a terminal state (`Decommissioned`?) or
  the row would be tombstoned outright.
- **Recovery**: not auto-reversible. A subsequent `Connect` would be
  treated as a *new* install of the plugin.
- **Cardinality**: very rare. Driven by a deliberate decision to retire
  the plugin from the platform.
- **Status**: this tier is not yet modeled. The gap is acknowledged in
  [event-graph-linking.md:237](event-graph-linking.md#L237): "requires a
  `PluginDeregistered` (or `PluginDeprecated`) event to tombstone the
  fragment. This event is not currently modelled in the platform spec
  and would need to be added if formal deregistration is required."

## Cross-cutting: version supersession (`Retired`)

`Retire` is a fourth lifecycle move that does **not** sit on the up/down
axis above. It is emitted by the deploy hook
(`publishRetireForOlderPluginVersions`) when a **newer version of the same
plugin** connects, targeting the *old* version's aggregate
(`name@version`). The plugin name stays in the catalog — only the
superseded version row is affected — so it is neither an admin action
(tier 2) nor a catalog/membership change (tier 3).

- **Aggregate state**: `Retired(pluginDefinition)`
  ([PluginBehavior.res](../../reventless/reventless-core/src/admin/PluginBehavior.res)).
- **Trigger**: deploy-time `Retire`, one per superseded `name@version`.
- **Recovery**: the version's **own** `Heartbeat` (a rollback / redeploy of
  that exact version) revives it through `Reconnected → Connected`. An admin
  `Activate` is rejected (`IsRetired`) — there is nothing for an admin to turn
  back on; only a real redeploy of that version should bring it back.

This makes `Inactive` and `Retired` mirror images on the two recovery axes:

| State | Heartbeat revives? | Admin `Activate` revives? |
|---|---|---|
| `Disconnected` (tier 1) | yes | n/a (not suspended) |
| `Inactive` (tier 2, admin suspend) | no | yes |
| `Retired` (version superseded) | yes | no (`IsRetired`) |

Before this split, both `Deactivate` and `Retire` collapsed onto `Inactive`,
so a superseded version was admin-reactivatable and a straggler heartbeat
could not be distinguished from a deliberate rollback. See
[docs/plans/plugin-retired-state-version-supersession.md](../plans/plugin-retired-state-version-supersession.md).

## The membership-vs-availability principle

Two orthogonal questions about any plugin:

- **Membership** — "is this plugin part of the platform's known
  surface?" Affects: GraphQL SDL types, UI route registrations, MCP tool
  listings, event-graph nodes, documentation generators.
- **Availability** — "can this plugin serve a request *right now*?"
  Affects: GraphQL resolver gating, UI greyed-out state, client retry
  policies.

Membership is structural — it changes only when the platform's catalog
of known plugins changes. Availability is operational — it flickers as
plugins go down and come back up.

The tiers map cleanly onto this distinction:

| Tier | Membership change? | Availability change? |
|---|---|---|
| Tier 1 (`Disconnected` ↔ `Connected`) | no | yes |
| Tier 2 (`Deactivate` / `Activate`) | no | yes |
| Tier 3 (`Decommission`) | **yes** | yes (terminal) |

This is why the SDL re-stitch — an expensive, slow operation on AWS
(~30s redeploy) — is the wrong response to tiers 1 and 2 but the right
response to tier 3. Conversely, the resolver-level status gate is the
right response to tiers 1 and 2 but unnecessary for tier 3 (the type
isn't in the schema in the first place).

## Tier × surface matrix

The full matrix of what each tier changes:

| Surface | `Connected` | `Disconnected` (tier 1) | `Inactive` (tier 2) | `Retired` (supersession) | Decommissioned (tier 3) |
|---|---|---|---|---|---|
| Plugin RM `status` | `Connected` | `Disconnected` | `Inactive` | `Retired` | row deleted |
| `apiSchemaFragment` / `uiFragments` (raw) | preserved | preserved | preserved | preserved | removed |
| GraphQL SDL membership | included | **included** | **included** | **included** | excluded (re-stitch) |
| GraphQL resolver gate | passes | rejects: `PluginUnavailable` | rejects: `PluginInactive` | rejects: `PluginRetired` | n/a (404 at parse) |
| `UIFragmentRegistry` row | present | absent (dereg on Disconnect) | absent (dereg on Deactivate) | absent (dereg on Retire) | absent |
| `Platform_UIDefinitions` listing | included | filtered out | filtered out | filtered out | filtered out |
| Host-shell page / panel registry | mounted | unmounted | unmounted | unmounted | unmounted |
| Event-graph node | present | present | present | present | tombstoned |
| MCP tool listing | included | included | included | included | excluded |

Like tiers 1 and 2, `Retired` changes availability only — SDL membership is
untouched (no re-stitch). It differs from `Inactive` solely in its recovery
rule (own-heartbeat vs admin `Activate`), per the table above.

The two key rows are **GraphQL SDL membership** and **GraphQL resolver
gate** — they encode the membership-vs-availability split. Tiers 1 and 2
both leave membership untouched; only the gate flips.

## Error-code semantics

The resolver gate must distinguish tier 1 from tier 2 because client
behaviour differs:

- **`PluginUnavailable`** (Disconnected) — auto-recoverable. Clients
  should retry with backoff. The plugin is expected to come back on its
  own.
- **`PluginInactive`** (Inactive) — admin-controlled. Clients should
  surface the failure to the user (or fail their workflow) and **not**
  retry — only an admin can lift the suspension.

A single `InactivePlugin` error code conflating both states forces
clients to pick one wrong policy: aggressive retries against an
admin-suspended plugin (wasteful, never succeeds) or no retries against
a transiently-disconnected plugin (poor UX). The gate already reads the
status field; differentiation is essentially free.

A future tier 3 would not need an error code at all — its types are
absent from the SDL, so requests fail at parse time with a standard
GraphQL "unknown field" error.

## Why this principle matters

1. **Schema stability for typed clients.** Codegen-driven clients
   (e.g. `@graphql-codegen`, `apollo-codegen`) consume the SDL as a
   compile-time contract. If the SDL flickers on every heartbeat miss,
   client builds break. Stable membership across tiers 1 and 2 means
   client codegen runs against a stable surface.

2. **Cheap admin actions.** Deactivating and reactivating a plugin
   should be a fast, low-risk operation an admin can do dozens of times.
   If each toggle triggers a 30-second AppSync schema redeploy, the
   feature becomes unusable in practice.

3. **Auto-recovery stays autonomous.** Heartbeat-driven recovery should
   not require any platform-wide action (no redeploy, no restitch). The
   gate flipping back to "passes" when the next `Heartbeat` lands is the
   entire recovery path.

4. **A precise slot for decommissioning.** The unmodeled tier 3 gets a
   sharp definition: it is the *only* lifecycle event that changes
   membership. That makes it semantically distinct from `Deactivate`
   ("the same thing but more so") and gives the future plan a clear
   contract: emit `PluginDeregistered`, tombstone the row, re-stitch the
   schema, drop the event-graph node.

## Implementation pointers

- **Behaviour**:
  [PluginBehavior.res](../../reventless/reventless-core/src/admin/PluginBehavior.res)
  — defines the `Detected` / `Connected` / `Disconnected` / `Inactive`
  states and the transitions between them.
- **Spec**: [PluginSpec.res](../../reventless/reventless-core/src/admin/PluginSpec.res)
  — six commands: four `@noApi` internal-protocol (`Heartbeat`,
  `Connect`, `Disconnect`, `ReportIncompatibility`) plus two admin
  (`Activate`, `Deactivate`).
- **Projection**:
  [PluginProjection.res](../../reventless/reventless-core/src/admin/PluginProjection.res)
  — preserves `apiSchemaFragment` / `uiFragments` across status
  transitions via `UpdateWithDefault`.
- **Admin tier workstream**:
  [docs/plans/aws-plugin-activate-deactivate-resolver.md](../plans/aws-plugin-activate-deactivate-resolver.md)
  — implements the tier 2 surface contract end-to-end.
- **UI fragment lifecycle**:
  [docs/plans/ui-fragment-registry.md](../plans/ui-fragment-registry.md)
  — implements the `UIFragmentRegistered` / `_Deregistered` events that
  drive the `UIFragmentRegistry` and `Platform_UIDefinitions` rows in
  the matrix.
- **Tier 3 gap**:
  [docs/analysis/event-graph-linking.md:237](event-graph-linking.md#L237)
  — flags the missing `PluginDeregistered` / `PluginDeprecated` event
  for the event-graph context.

## Open: decommission tier (sketch)

A future plan to add tier 3 would need:

1. **Command**: `Decommission` on `PluginSpec.command` (admin-gated
   identical to `Deactivate`). Likely valid only from `Inactive` to
   force a deliberate two-step flow (Deactivate → observe → Decommission).
2. **Event**: `PluginDeregistered` (or `PluginDeprecated`) carrying the
   final `pluginDefinition` for the event log.
3. **Aggregate state**: terminal `Decommissioned` state, or row
   tombstoning. Reject all further commands except a fresh `Connect`
   (which is treated as a re-install).
4. **Schema re-stitch**: subscribe to `PluginDeregistered` and trigger
   the SDL rebuild — this is the legitimate use of "Option A" from the
   admin tier plan.
5. **Read-model cleanup**: delete the Plugin RM row, drop the
   `Platform_UIDefinitions` entry, tombstone the event-graph node.
6. **Safeguard**: confirmation step in the admin UI — `Decommission` is
   not auto-reversible and the operation is a real catalog change, not
   a toggle.

Until that plan exists, the platform has a 2-tier lifecycle model. This
is documented behaviour, not a bug — most platforms operate happily
without ever needing tier 3.
