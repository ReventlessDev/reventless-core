# Plan: `@live` annotation emitter + structure read-model descriptors

**Date:** 2026-08-09<br/>
**Status:** Proposed — not started.<br/>
**Role:** Companion to host-side live-updates work. Two small framework
additions on top of [realtime-change-descriptors.md](realtime-change-descriptors.md):
close the producer half of the `x-reventless-live` annotation (the host-ui
reader already shipped), and make the admin *structure* read model publish
change descriptors like the plugin read model already does.

## Gap 1 — `@live` has a reader but no producer

The host-ui shell reads a top-level `x-reventless-live` boolean from each
projection's JSON schema (`SchemaAnnotations.readLive`) to decide a view's
live-by-default state; annotation wins, otherwise default `true`. Nothing in
core emits the key — grep across the repo finds zero producers — so every
generated view is currently live-by-default and per-view defaults cannot be
declared where the read model is defined.

**Deliverable:** an `@live(true | false)` attribute on read-model /
state-view-slice state declarations, propagated by the PPX into the projection
JSON schema as top-level `x-reventless-live: bool`, on both platforms (the
schema is platform-neutral, so one emission point should cover local and AWS).

- Follow the existing custom-schema-extension plumbing (the same route other
  `x-reventless-*` keys travel from attribute to emitted schema).
- Absent annotation ⇒ key absent ⇒ consumer default applies. The framework
  only transports the declaration; what consumers do with it is theirs. (The
  host-ui shell is moving to strictly opt-in live — the toggle defaults to
  off — so there the annotation governs whether a Live control is *offered*:
  `@live(false)` marks investigative/historical views (catalogues,
  comparisons, audit histories) where live updates make no sense and the
  control is hidden; `@live(true)` marks operational views where it is
  offered. The user still has to switch it on.)

Phases:
1. PPX: accept the attribute where `@id`/`@compositeId`-class attributes are
   accepted; validate arity (exactly one bool).
2. Schema generation: emit the extension key; parity test local vs AWS emitted
   schema.
3. Tests: annotated fixture slice → schema contains the key; unannotated →
   key absent. Guide update in the annotations reference.

## Gap 2 — `Platform_PluginStructures` publishes no descriptors

The admin plugin read model is stream-backed
(`Platform.res:996`, `ReadModel_Builder_Single_Stream`), so `Platform_Plugins`
row changes already publish to the Events API. The *structure* read model
behind `Platform_PluginStructures` (`Platform_PluginStructuresApi` /
`Platform_Admin_Structure`) is not — an operator console rendering the
platform structure gets no signal when a deploy changes it, even though the
per-plugin sync completes inside the deploy (`_pluginDeployedSync` is a stack
output, not a runtime event).

**Deliverable:** move the structure read model's storage to the stream-backed
builder so its writes flow through the existing
`subscriptionInfraHook → StateTopic_AppSync` path, publishing standard change
descriptors on the channel rooted at its plural list field name.

- First step is verification: confirm which storage the structure read model
  actually uses and whether its writes go through a QueryDb the
  `streamRegistry` can know about. If structure rows are written outside the
  QueryDb path, the fallback is the Source-C precedent
  (`Platform_AdminApi`: write-then-mutation fan-out, as
  `onPluginStatusChange` does) — but Source B (Events descriptor) is
  preferred so consumers have one mechanism.
- Confirm in-place migration: enabling a DynamoDB stream on the existing
  admin table must be an update, not a replace. If the builder swap replaces
  the table, add a Pulumi alias so the resource identity is preserved.

Phases:
1. Verify storage path + write a stream-migration preview note (update vs
   replace) against a scratch stack.
2. Builder swap (+ alias if needed); local-platform parity via
   `LocalBus.publishStateChange` (already fired by the in-memory storage).
3. Descriptor smoke test mirroring `StateChangeDescriptorParityTest`.

## Explicitly deferred (unchanged from realtime-change-descriptors.md)

- **`BulkInvalidated` coalescer (Phase 4 there).** Deploy-time syncs write
  many admin/operational rows in a burst; clients currently absorb this with
  their refetch debounce. Trigger to revisit: observed refetch storms on
  operator dashboards during deploys.
- **DCB position exposure (Phase 3 there).**
- **Runtime `withLiveUpdates` on the DynamoDB ops branch** — rejected as the
  mechanism for this plan; stream-backed builders are the chosen path (one
  publish pipeline, no per-write Lambda cost in the projector).
