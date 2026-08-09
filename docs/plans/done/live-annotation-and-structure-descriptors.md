# Plan: `@live` annotation emitter + structure read-model descriptors

**Date:** 2026-08-09<br/>
**Status:** Done — Gap 1 implemented (`@live` → `x-reventless-live`); Gap 2
closed by its own Phase-1 verification: there is no structure read model to
migrate, and structure changes already publish change descriptors (details in
the Gap 2 section).<br/>
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

**Outcome (implemented 2026-08-09):**

- Placement: `@live(true | false)` sits on the `@schema type state` **type
  declaration** (not a field, not file-level) of ReadModel / StateViewSlice
  spec files — it is a per-view property, and the state declaration is the
  one thing the schema is derived from. The PPX arity-checks the payload
  (exactly one bool literal), strips the attribute, and errors on a `@live`
  state declaration in any other spec file kind (mirrors the
  `@@reventless.visibility` misplacement error).
- Carriage: new `live: option<bool>` field on
  `StateAnnotations.stateAnnotationSpec` (sury metadata), emitted by
  `make_state_annotations_binding` alongside `status`/`groupBy`/`visibility`.
  The metadata binding is emitted from `@live` alone when no field
  annotations exist.
- Emission: `SuryToJsonSchema.deriveObjectSchema` stamps top-level
  `x-reventless-live: bool` next to `x-reventless-visibility`. One emission
  point covers both platforms — `queryableDef.schema` is built in core by
  `Plugin_Structure` for local and AWS alike, so no per-platform parity test
  is needed beyond the existing `PluginStructureTest` end-to-end assertion.
- Tests: PPX fixtures + arity/misplacement compile-error cases in
  `packages/reventless-ppx/test/run.sh`; present/absent/combined emission
  cases in `SuryToJsonSchemaTest`; `@live(false)` on the `PsAnnotatedView`
  fixture asserted through `queryableDef.schema` in `PluginStructureTest`.
- Docs: `packages/doc/docs-app/reventless-ppx.md` (annotations reference),
  `packages/doc/docs-app/components/readmodel.md`, `.claude/rules/app-developer.md`.
- **Release gate:** CI compiles with the published `reventless-ppx`, so this
  lands only with a ppx republish in lockstep (same choreography as
  `@offload`): republish the per-platform ppx packages first, then push —
  otherwise the `PsAnnotatedView` assertion fails and the `stateAnnotationSpec`
  record literal (now including `live`) does not typecheck against old ppx
  output.

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

**Outcome (verified 2026-08-09) — closed at Phase 1; the deliverable does not
apply.** The premise ("the structure read model is not stream-backed") does
not match the code:

- There is **no structure read model**. `Platform_PluginStructures` is a
  GraphQL query field served by the ComponentDefinitions resolver Lambda
  (`Platform_ComponentDefinitions_Lambda.res`), which scans the **`Plugins`
  read-model table** (`PLUGIN_RM_TABLE`) and resolves `$offload` sentinels
  from S3. `Platform_Admin_Structure.res` is the hand-rolled synthetic
  structure for the built-in admin plugin, not a storage owner.
- The structure itself is a field on the `Plugins` read-model row
  (`PluginsReadModelSpec.state.structure`), folded in by `PluginsProjection`
  from `VersionConnected` — i.e. writes go through the QueryDb path of the
  `Plugins` read model, which is **already** built with
  `ReadModel_Builder_Single_Stream` (`reventless/aws/src/Platform.res:996`;
  the swap happened in `done/admin-readmodels-live-and-shared-statetopic-lambda.md`).
  The table already carries a `NEW_AND_OLD_IMAGES` stream — no migration, no
  alias, nothing to provision.
- Consequently a deploy that changes a plugin's structure **already publishes
  a Source-B change descriptor** on `/default/Platform-Plugins/{pluginName}`
  (channel root = the plural `listFieldName` from `queryFieldNamesRegistry`).
  The descriptor's `state` carries the `$offload` sentinel (or is dropped
  above the 60 KB cap), so a structure consumer must refetch
  `Platform_PluginStructures` on signal — exactly the advisory-descriptor
  protocol. An operator console therefore subscribes to
  `Platform-Plugins/*` and refetches; no new channel is warranted.
- Local parity: the `Plugins` read model is a real in-memory QueryDb locally,
  so `QueryDbStorage_InMemory` fires `LocalBus.publishStateChange` for the
  same row writes. (The local `pluginStructuresStore` ref-dict that backs the
  `Platform_PluginStructures` resolver is seeded outside the bus, but every
  structure change is accompanied by the descriptor-publishing `Plugins` row
  write, so the signal exists locally too.)
- No new smoke test: descriptor construction parity is already covered by
  `StateChangeDescriptorParityTest`, and the `Plugins` publish path is the
  one that carries structure changes today — there is no new mechanism to
  test.

## Explicitly deferred (unchanged from realtime-change-descriptors.md)

- **`BulkInvalidated` coalescer (Phase 4 there).** Deploy-time syncs write
  many admin/operational rows in a burst; clients currently absorb this with
  their refetch debounce. Trigger to revisit: observed refetch storms on
  operator dashboards during deploys.
- **DCB position exposure (Phase 3 there).**
- **Runtime `withLiveUpdates` on the DynamoDB ops branch** — rejected as the
  mechanism for this plan; stream-backed builders are the chosen path (one
  publish pipeline, no per-write Lambda cost in the projector).
