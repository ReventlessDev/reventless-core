# Backlog: Event Schema Versioning via Sury Decoder Chains

**Status:** Backlog — depends on `docs/plans/sury-11-migration.md` Phase 4
**Analysis:** `docs/analysis/sury-11-migration.md` (opportunity C);
related: `docs/plans/done/effect-library-integration.md` §10,
`docs/analysis/event-format-and-meta-review.md` #9 and "schemaVersion"
discussion.

## Context and motivation

Today, renaming or restructuring a field on an `@schema type event` is a
foot-gun: every event already persisted in the EventLog was written with the
old shape, but replay decodes against the *current* schema. Sury silently
produces `undefined` for missing fields, or throws on shape mismatch, with no
recovery path. There is no `schemaVersion` on stored events and no migration
hook in `EventLog.replay`.

`docs/plans/done/effect-library-integration.md` §10 listed this gap as
"Tier 3 — Future Architectural Evolution" and proposed adopting
`Effect.Schema` for its `transform` / `transformOrFail` bidirectional
versioning. The blocker at the time was that Effect Schema has no ReScript
bindings and no PPX — the migration would cost more than the gap.

Sury 11.0.0-alpha.5 ships `S.decoder(from, target)` and `S.to(schema,
~decode, ~encode)`, which give the same bidirectional-transform pattern
natively. The migration to alpha.5 (separate plan) makes this opportunity
materially cheaper.

## Goal

Make Reventless events forward-compatible: a spec author can rename a field,
add a field with a default, split a variant, etc., and historical events
continue to replay correctly through declared migrations.

## What's already in place after the alpha.5 migration

- `S.decoder(from, target)` for typed decode through a schema chain.
- `S.to(schema, ~decode, ~encode)` for bidirectional transforms.
- `Util_Sury` shim (from the alpha.5 migration plan Phase 1) — the natural
  place to host higher-level helpers.
- `Message.meta.schemaVersion?: string` already exists in the meta envelope
  (per `event-format-and-meta-review.md`) — currently unused; this plan
  starts populating and reading it.

## Out of scope

- Cross-version state migration in read models (different concern — a read
  model rebuild handles state shape changes).
- Variant rename across event TAGs (handled by a separate "event alias"
  story — flag for follow-up if it becomes a need).

## Phases

### Phase 1 — Spec-level migration declarations

**Goal:** allow a spec author to declare an old event schema alongside the
current one and a migration function between them.

Steps:
1. Add a convention on `@@reventless.spec`-annotated spec files for declaring
   prior versions:
   ```rescript
   @@reventless.spec("Catalog")

   @schema type eventV1 = | ProductAdded({productId: string, name: string})
   @schema type event   = | ProductAdded({productId: string, name: string, sku: string})

   let migrations: array<Reventless.EventMigration.t<event>> = [
     Reventless.EventMigration.from(eventV1Schema, v1 => switch v1 {
       | ProductAdded({productId, name}) => ProductAdded({productId, name, sku: "unknown"})
     }),
   ]
   ```
2. Define `Reventless.EventMigration` in `reventless-core`:
   ```rescript
   type t<'event> = {
     fromSchema: S.t<unknown>,
     migrate: unknown => 'event,
     fromVersion: option<string>,  // matches Message.meta.schemaVersion
   }
   let from = (fromSchema, migrate) => { fromSchema, migrate: Obj.magic(migrate), fromVersion: None }
   let fromVersion = (~version, fromSchema, migrate) =>
     { fromSchema, migrate: Obj.magic(migrate), fromVersion: Some(version) }
   ```
3. `let migrations` defaults to `[]` if not declared (back-compat for existing
   specs).

### Phase 2 — Replay-time migration in EventLog

**Goal:** when replaying, attempt to decode each stored event against the
current schema first; on failure, try each declared migration in order; if
none match, fail loudly with a structured error pointing at the offending
event id.

Steps:
1. Extend `EventLog_Operations.replay` (and the DCB counterpart) to accept
   `migrations: array<EventMigration.t<event>>` from the calling spec.
2. Decoding pseudocode:
   ```rescript
   let tryDecode = (json) => {
     switch Util_Sury.fromJson(json, Spec.eventSchema) {
     | event => Ok(event)
     | exception _ =>
       migrations->Array.findMap(m =>
         switch Util_Sury.fromJson(json, m.fromSchema) {
         | old => Some(m.migrate(old))
         | exception _ => None
         }
       )->Option.map(Ok)->Option.getOr(Error(StaleEventShape(json)))
     }
   }
   ```
3. When `Message.meta.schemaVersion` is set on the stored event, route
   directly to the matching migration by `fromVersion` instead of trial-
   and-error decode. Trial-and-error stays as a fallback for events written
   before this plan landed (which have no `schemaVersion`).
4. Failure path: surface `StaleEventShape` with the event id, stored shape,
   and the list of migrations that were tried — via the structured `S.Exn`
   path introduced by alpha.5 opportunity D.

### Phase 3 — Write-time schemaVersion stamping

**Goal:** new events carry `meta.schemaVersion` so future migrations don't
need trial-and-error.

Steps:
1. Generate a stable per-spec version string at build time — content hash of
   the schema's `S.toExpression(eventSchema)` output (deterministic across
   builds). Inject via `@@reventless.spec` PPX as `let schemaVersion =
   "<hash>"`.
2. `Aggregate_Callback`, `StateChangeSlice_Callback`, and the DCB callback
   stamp `meta.schemaVersion = Spec.schemaVersion` when producing the
   commandJson → event envelope.
3. EventLog storage writes the field through unchanged.
4. Phase 2's `findMap` fallback applies only to events with
   `schemaVersion == None`; events with a known version go through the
   matching migration directly.

### Phase 4 — Forward-compat read paths for projections

**Goal:** ReadModel projections benefit from the same machinery — a
projection consuming an old event variant continues to work after the
producer adds a new field.

Steps:
1. Extend `Projection_Builder` to accept `eventMigrations` from the consumed
   spec.
2. The `EventCollector` → projection path runs the same decode-or-migrate
   pipeline as Phase 2 before calling the projection's `apply`.
3. Cross-plugin consumed-event types (declared via `@schema type
   consumedEvent`) accept migrations from the producer's spec.

## Open questions

1. **What is the "old schema" identity for trial-and-error?** Variant shape
   matching is fragile if two old versions have similar shapes. The
   `schemaVersion` field makes this deterministic going forward, but the
   first-pass fallback needs heuristics. Proposed: try migrations in
   declaration order, log every fallback at WARN.
2. **Storage cost of `schemaVersion` on every event.** A 16-character hash
   per event adds up at scale. Acceptable in v1; consider truncation
   (8 chars = 32-bit collision space) if it becomes a problem.
3. **Coupling between produced and consumed spec versions.** A consumer
   declaring `eventV1` for `CatalogPlugin.ProductAdded` must know what V1
   looked like. Either (a) cross-plugin shared `consumedEvent` types
   continue to mirror the producer's history exactly, or (b) consumers
   declare only the fields they read (this is more aligned with the
   "subscriber-defined contracts" story from
   `docs/analysis/done/dcb-event-type-coupling.md`). Lean toward (b).

## Validation

- Round-trip test: write an event with V1 schema (simulated), read it back
  via the V2 spec with a declared migration; the result equals the migrated
  shape.
- Failure test: write a malformed event with no matching migration; replay
  surfaces `StaleEventShape` with the event id and stored JSON.
- Performance test: replay 100k events of mixed versions; per-event
  overhead vs. baseline (no migrations) stays under 10%.
- Integration: add a `CategoryAdded` rename scenario to
  `examples/online-shop-aggregates/catalog` and verify the existing
  AggregateGwt tests pass against both V1-shaped and V2-shaped historical
  events.

## Risks

| Risk                                                                     | Likelihood | Impact | Mitigation                                                                  |
| ------------------------------------------------------------------------ | ---------- | ------ | --------------------------------------------------------------------------- |
| Trial-and-error decode misclassifies an old V1 event as V2 (or vice-versa) | medium     | high   | Stamp `schemaVersion` (Phase 3); trial-and-error is fallback only; WARN log |
| Per-event migration overhead noticeable on EventLog replay               | low        | medium | Phase 3's direct-by-version dispatch makes the hot path schema-version O(1) |
| Migration function diverges from the inverse on round-trip               | medium     | medium | `S.to(~decode, ~encode)` is bidirectional — require both directions on declaration |
| Forgotten migration on a producer rename — silent data loss              | medium     | high   | Build-time check: if `schemaVersion` hash changes and `migrations` is empty, emit warning at CI |

## References

- Sury 11 migration: `docs/plans/sury-11-migration.md`
- Schema versioning gap in Effect tier 3: `docs/plans/done/effect-library-integration.md` §10
- `schemaVersion` and `dataschema` discussion: `docs/analysis/event-format-and-meta-review.md`
- Cross-plugin subscriber contracts: `docs/analysis/done/dcb-event-type-coupling.md`
